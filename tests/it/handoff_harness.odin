package it

// ─────────────────────────────────────────────────────────────────────────────
// handoff_harness.odin — T11's shared plumbing. NO counted assertions live here.
//
// Every `support.check` fires from tests/it/handoff_test.odin so the ledger
// group is the scenario file and this harness can never inflate a total. What
// lives here:
//
//   • hh_begin / hh_finish — spawn one role of THIS binary on a real pty with
//     an evidence channel, and take the whole process tree down afterwards
//   • the env save/restore that makes HS_ROLE/BIN swaps invisible to the rest
//     of the it binary
//   • the evidence reader (poll-until-key, with the pty pumped while waiting)
//   • check_stty's replacement: a full termios comparison, field by field
//   • the raw-stream index helpers the alt-screen ordering claims need
//
// WHY THE ROLES RUN AS THIS PROCESS AND NOT AS `$BIN`
//
//   `pty.pty_spawn` spawns whatever $BIN points at, and the gate runs this
//   suite with $BIN = the product binary. The handoff suite needs the app role
//   to be a TEST-owned process (T16 deletes the product's handoff CLI cases),
//   so hh_begin repoints $BIN at this binary's own executable path for the
//   duration of the fork and puts it back immediately after. Nothing else in
//   this binary can see the swap, and the child gets its role from $HS_ROLE,
//   dispatched by the @(init) hook in handoff_roles_init.odin.
//
// WHY THE PTY IS PUMPED WHILE WAITING FOR EVIDENCE
//
//   The app writes into a 64 KiB pty buffer. If the harness only read the
//   evidence file, a chatty child would fill the buffer and block in write()
//   before it ever reported the key we are waiting for — a deadlock with a
//   timeout that looks like "the role never reported". Every wait here reads
//   the pty on each iteration.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

import pty "../pty"
import evidence "./probes/evidence"

HH_ROWS :: 40
HH_COLS :: 120

// The terminal we hand the app. Fixed, so TERM-dependent rendering is
// deterministic and the env-probe's "TERM survived the scrub" has a known
// value to be compared against rather than whatever the developer's shell had.
HH_TERM :: "xterm-256color"
HH_COLORTERM :: "truecolor"

// Alt-screen sequences, as termbox2 writes them.
HH_ALT_ENTER :: "\x1b[?1049h"
HH_ALT_LEAVE :: "\x1b[?1049l"

// The leaky environment we install into the app before the handoff, and the
// count the env-probe must then come back with zero of. Seven names, six of
// them distinct from the three the product happens to READ today: the scrub is
// a namespace rule, so it has to be tested with more than the three.
HH_LEAK :: "HERDR_ENV=1;HERDR_SESSION=fake-live;HERDR_PANE_ID=fake-pane;HERDR_SOCKET_PATH=/tmp/leaky.sock;HERDR_CLIENT_SOCKET_PATH=/tmp/leaky-client.sock;HERDR_TAB_ID=fake-tab;HERDR_WORKSPACE_ID=fake-ws"
HH_LEAK_COUNT :: 7

// hh_ms turns a millisecond count into a time.Duration, the same shape the pty
// driver uses so the two clocks cannot disagree about what "500 ms" means.
hh_ms :: proc(ms: f64) -> time.Duration {
	return time.Duration(i64(ms * f64(time.Millisecond)))
}

// hh_elapsed_ms is the ms axis the waits are measured on. `Tick + Duration`
// is not a thing in Odin, so deadlines are (start tick, budget ms) and every
// loop compares elapsed-since-start against the budget — the same shape
// pty.odin's elapsed_ms/over_due pair uses.
hh_elapsed_ms :: proc(t0: time.Tick) -> f64 {
	dur := time.tick_diff(t0, time.tick_now())
	return f64(time.duration_nanoseconds(dur)) / 1e6
}

HH_KV :: struct {
	k, v : string,
}

Hh :: struct {
	name    : string,
	d       : ^pty.Pty_Driver,
	ev_path : string,
	saves   : [dynamic]Env_Record,
	live    : bool,
}

Env_Record :: struct {
	k    : string,
	had  : bool,
	prev : string,
}

// ─────────────────────────────────────────────────────────────────────────────
// Artifact paths — one per scenario name, never shared
// ─────────────────────────────────────────────────────────────────────────────

hh_artifact :: proc(name: string, ext: string) -> string {
	return fmt.tprintf("/tmp/hs-it-handoff-{}.{}", name, ext)
}

// ─────────────────────────────────────────────────────────────────────────────
// Env save/restore
//
// Every env var this harness sets is recorded with what was there before, and
// put back on finish. A harness that leaves HS_ROLE set would make the NEXT
// test in this binary spawn itself as a role instead of running tests.
// ─────────────────────────────────────────────────────────────────────────────

hh_env_set :: proc(h: ^Hh, k, v: string) {
	prev, had := os.lookup_env(k, context.allocator)
	append(&h.saves, Env_Record{k = k, had = had, prev = prev})
	if e := os.set_env(k, v); e != nil {
		fmt.eprintf("hh: set_env({}) failed: {}\n", k, e)
	}
}

hh_env_restore :: proc(h: ^Hh) {
	// Reverse order: last set is first restored, so nested overrides unwind.
	i := len(h.saves)
	for i > 0 {
		i -= 1
		r := h.saves[i]
		if r.had {
			os.set_env(r.k, r.prev)
		} else {
			os.unset_env(r.k)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Spawn / teardown
// ─────────────────────────────────────────────────────────────────────────────

// hh_begin starts one role on a pty. Returns (nil, reason) rather than
// asserting, so the scenario files the failure under its own group name.
hh_begin :: proc(name: string, role: string, extra: []HH_KV,
                rows: i32 = HH_ROWS, cols: i32 = HH_COLS) -> (h: ^Hh, err: string) {
	h = new(Hh)
	h.name = name
	h.ev_path = hh_artifact(name, "ev")
	os.remove(h.ev_path) // a stale file is not evidence

	self, e := os.get_executable_path(context.allocator)
	if e != nil || len(self) == 0 {
		return nil, fmt.tprintf("cannot resolve this test binary's own path: {}", e)
	}

	hh_env_set(h, "HS_ROLE", role)
	hh_env_set(h, "HS_EVIDENCE", h.ev_path)
	hh_env_set(h, "TERM", HH_TERM)
	hh_env_set(h, "COLORTERM", HH_COLORTERM)
	for i := 0; i < len(extra); i += 1 {
		hh_env_set(h, extra[i].k, extra[i].v)
	}
	// The swap, last set and first restored.
	hh_env_set(h, "BIN", self)
	hh_env_set(h, "HS_BIN", self)

	d, serr := pty.pty_spawn([]string{}, rows, cols)
	// The child has its environment now (pty_build_env copies ours at fork
	// time), so every swap can go back before anything else runs.
	hh_env_restore(h)
	if serr != "" {
		return nil, fmt.tprintf("spawn role '{}' failed: {}", role, serr)
	}

	h.d = d
	h.live = true
	return h, ""
}

// hh_finish takes the tree down. Group-kill FIRST: the app may be sitting in
// waitpid on a probe child, and killing only the app would orphan the probe (a
// sig-probe sleeps 8 s and would outlive the scenario). Then reap the direct
// child and release the pty.
hh_finish :: proc(h: ^Hh) {
	if h == nil || !h.live { return }
	h.live = false
	if h.d != nil {
		if pty.pty_alive(h.d) {
			pty.pty_signal_group(h.d, posix.Signal.SIGKILL)
		}
		pty.pty_kill(h.d, posix.Signal.SIGKILL)
		pty.pty_close(h.d)
		h.d = nil
	}
	hh_env_restore(h)
}

// hh_env_restore already ran after the spawn; calling it again is a no-op
// because the records are idempotent (set/unset to the same prior state).
// ─────────────────────────────────────────────────────────────────────────────
// Evidence
// ─────────────────────────────────────────────────────────────────────────────

hh_ev_load :: proc(h: ^Hh) -> map[string]string {
	return evidence.load(h.ev_path, context.allocator)
}

// hh_wait_ev blocks until `key` appears in the evidence file, pumping the pty
// on every pass so the child can never stall on a full tty buffer. Returns the
// map as it stood when it gave up, so the caller can print what WAS there.
hh_wait_ev :: proc(h: ^Hh, key: string, timeout_ms: f64) -> (map[string]string, bool) {
	t0 := time.tick_now()
	m := hh_ev_load(h)
	for {
		m = hh_ev_load(h)
		if _, ok := m[key]; ok { return m, true }
		if h.d != nil { pty.pty_read(h.d, 25) }
		if hh_elapsed_ms(t0) >= timeout_ms { return m, false }
		// A role that has already exited will never write again — but its last
		// writes DID land before it exited, so re-read the file one more time
		// before declaring the key missing. Checking liveness before that final
		// read is how a fast role gets reported as having reported nothing:
		// measured here, the `abi` and `double` roles finished inside the first
		// 25 ms pump and every one of their facts came back "<absent>".
		if h.d != nil && !pty.pty_alive(h.d) {
			m = hh_ev_load(h)
			if _, ok := m[key]; ok { return m, true }
			return m, false
		}
	}
	return m, false
}

hh_ev_str :: proc(m: map[string]string, key: string) -> string {
	v, ok := m[key]
	if !ok { return "<absent>" }
	return v
}

hh_ev_has :: proc(m: map[string]string, key: string) -> bool {
	_, ok := m[key]
	return ok
}

hh_ev_i64 :: proc(m: map[string]string, key: string) -> (i64, bool) {
	v, ok := m[key]
	if !ok { return 0, false }
	neg := false
	i := 0
	if len(v) > 0 && v[0] == '-' { neg = true; i = 1 }
	if i >= len(v) { return 0, false }
	n : i64 = 0
	digits := 0
	for ; i < len(v); i += 1 {
		if v[i] < '0' || v[i] > '9' { return 0, false }
		n = n * 10 + i64(v[i] - '0')
		digits += 1
	}
	if digits == 0 { return 0, false }
	if neg { n = -n }
	return n, true
}

hh_ev_bool :: proc(m: map[string]string, key: string) -> (bool, bool) {
	v, ok := m[key]
	if !ok { return false, false }
	if v == "true" { return true, true }
	if v == "false" { return false, true }
	return false, false
}

// hh_ev_is / hh_ev_true collapse (value, present) into one boolean for the
// call sites. Odin cannot compare a multi-value call against a tuple, and a
// helper that returns one bool keeps a missing key from reading as a zero.
hh_ev_is :: proc(m: map[string]string, key: string, want: i64) -> bool {
	v, ok := hh_ev_i64(m, key)
	return ok && v == want
}

hh_ev_true :: proc(m: map[string]string, key: string) -> bool {
	v, ok := hh_ev_bool(m, key)
	return ok && v
}

hh_ev_is_str :: proc(m: map[string]string, key, want: string) -> bool {
	v, ok := m[key]
	return ok && v == want
}

// hh_ev_missing_names lists the keys the scenario needed and did not get.
hh_ev_missing_names :: proc(m: map[string]string, keys: []string) -> string {
	parts : [dynamic]string
	for i := 0; i < len(keys); i += 1 {
		if !hh_ev_has(m, keys[i]) { append(&parts, keys[i]) }
	}
	return join_hh(parts[:], ",")
}

// join_hh — index-addressed join. `for a, b in parts` in Odin is
// (VALUE, INDEX); getting that backwards here changes how many separators get
// emitted without ever failing, so the loop is written with explicit indices.
join_hh :: proc(parts: []string, sep: string) -> string {
	total := 0
	for i := 0; i < len(parts); i += 1 { total += len(parts[i]) }
	if len(parts) > 1 { total += (len(parts) - 1) * len(sep) }
	out := make([]byte, total)
	at := 0
	for i := 0; i < len(parts); i += 1 {
		if i > 0 {
			mem.copy(rawptr(&out[at]), raw_data(sep), len(sep))
			at += len(sep)
		}
		if len(parts[i]) > 0 {
			mem.copy(rawptr(&out[at]), raw_data(parts[i]), len(parts[i]))
			at += len(parts[i])
		}
	}
	if total == 0 { return "" }
	return string(out[:])
}

// ─────────────────────────────────────────────────────────────────────────────
// check_stty's replacement — "is the user's terminal back as it was?"
//
// The old suite ran `stty -a` before and after each case inside `script` and
// diffed the two files. `stty -a` is a rendering of exactly one thing: the
// kernel's struct termios. So the faithful port compares the struct itself,
// field by field, off the slave fd the driver keeps open for precisely this
// question. Nothing is printed-but-unverified: hh_begin/hh_finish never
// short-circuit a comparison, and a termios we cannot read is a FAIL, reported
// as one.
//
// hh_termios_diff returns (identical, detail). `detail` names every field that
// moved, so a red here says WHAT the app left wrong rather than "diff exit 1".
// ─────────────────────────────────────────────────────────────────────────────

hh_cc_names := []string{
	"VEOF", "VEOL", "VERASE", "VKILL", "VMIN",
	"VEOL2", "VTIME", "VSTART", "VSTOP", "VSUSP",
	"VDSUSP", "VREPRINT", "VDISCARD", "VLNEXT", "VWERASE",
	"VINTR", "VQUIT", "VLNEXT2", "VCTQ", "VRTN",
}

hh_termios_diff :: proc(before, after: posix.termios) -> (bool, string) {
	diffs : [dynamic]string
	if before.c_iflag != after.c_iflag {
		append(&diffs, fmt.tprintf("iflag {} -> {}", hh_bits_s(before.c_iflag), hh_bits_s(after.c_iflag)))
	}
	if before.c_oflag != after.c_oflag {
		append(&diffs, fmt.tprintf("oflag {} -> {}", hh_bits_s2(before.c_oflag), hh_bits_s2(after.c_oflag)))
	}
	if before.c_cflag != after.c_cflag {
		append(&diffs, fmt.tprintf("cflag {} -> {}", hh_bits_s3(before.c_cflag), hh_bits_s3(after.c_cflag)))
	}
	if before.c_lflag != after.c_lflag {
		append(&diffs, fmt.tprintf("lflag {} -> {}", hh_bits_s4(before.c_lflag), hh_bits_s4(after.c_lflag)))
	}
	if before.c_line != after.c_line {
		append(&diffs, fmt.tprintf("line {} -> {}", before.c_line, after.c_line))
	}
	if before.c_ispeed != after.c_ispeed {
		append(&diffs, fmt.tprintf("ispeed {} -> {}", before.c_ispeed, after.c_ispeed))
	}
	if before.c_ospeed != after.c_ospeed {
		append(&diffs, fmt.tprintf("ospeed {} -> {}", before.c_ospeed, after.c_ospeed))
	}
	for i := 0; i < 20; i += 1 {
		k := posix.Control_Char(i)
		if before.c_cc[k] != after.c_cc[k] {
			nm := hh_cc_names[i]
			append(&diffs, fmt.tprintf("cc[{}]={} -> {}", nm, before.c_cc[k], after.c_cc[k]))
		}
	}
	if len(diffs) == 0 { return true, "" }
	return false, join_hh(diffs[:], ", ")
}

// The flag fields are bit sets; render them as the raw mask so a diff line is
// short and comparable. One helper per distinct bit_set type: Odin will not
// unify them behind one signature.
hh_bits_s :: proc(f: posix.CInput_Flags) -> string {
	return fmt.tprintf("0x{x}", f)
}
hh_bits_s2 :: proc(f: posix.COutput_Flags) -> string {
	return fmt.tprintf("0x{x}", f)
}
hh_bits_s3 :: proc(f: posix.CControl_Flags) -> string {
	return fmt.tprintf("0x{x}", f)
}
hh_bits_s4 :: proc(f: posix.CLocal_Flags) -> string {
	return fmt.tprintf("0x{x}", f)
}

// hh_bits_lflag renders the local flags with ECHO/ICANON decoded next to the
// mask, because "raw=false" on its own tells you nothing about which of the two
// was still on.
hh_bits_lflag :: proc(t: posix.termios) -> string {
	echo_on := (t.c_lflag & posix.CLocal_Flags{.ECHO}) != {}
	icanon_on := (t.c_lflag & posix.CLocal_Flags{.ICANON}) != {}
	return fmt.tprintf("0x{x} (ECHO={} ICANON={})", t.c_lflag, echo_on, icanon_on)
}

// hh_termios_round_trip is the counted shape: (before, after) in, a verdict and
// a one-line explanation out. A missing snapshot on either side is a FAIL and
// says so — exactly like check_stty's "termios was not captured on both sides".
hh_termios_round_trip :: proc(h: ^Hh) -> (bool, string) {
	if h.d == nil { return false, "no pty: termios was not captured on either side" }
	if !h.d.have_before { return false, "termios was not captured before the spawn" }
	after, ok := pty.pty_termios_now(h.d)
	if !ok { return false, "termios was not captured after the run (tcgetattr failed)" }
	same, detail := hh_termios_diff(h.d.termios_before, after)
	if same {
		return true, "termios before == after across every field (iflag/oflag/cflag/lflag/line/speeds/cc[0..19])"
	}
	return false, fmt.tprintf("termios DIFFERS: {}", detail)
}

// hh_termios_is_raw reports whether the terminal is currently in a
// raw-ish mode: ECHO and ICANON both off. This is the anti-vacuity check for
// the round-trip assertions. Without it, "before == after" is also true for a
// process that never touched the terminal at all — and a test that cannot tell
// "restored" from "never grabbed" is not testing restoration.
hh_termios_is_raw :: proc(t: posix.termios) -> bool {
	l := t.c_lflag
	echo_off := (l & posix.CLocal_Flags{.ECHO}) == {}
	icanon_off := (l & posix.CLocal_Flags{.ICANON}) == {}
	return echo_off && icanon_off
}

// ─────────────────────────────────────────────────────────────────────────────
// Raw stream helpers — the alt-screen ordering questions
// ─────────────────────────────────────────────────────────────────────────────

hh_raw_index :: proc(h: ^Hh, needle: string, from: int = 0) -> int {
	d := h.d
	if d == nil { return -1 }
	n := len(d.raw)
	m := len(needle)
	if m == 0 || from < 0 || from + m > n { return -1 }
	i := from
	for i + m <= n {
		match := true
		for j := 0; j < m; j += 1 {
			if d.raw[i+j] != needle[j] { match = false; break }
		}
		if match { return i }
		i += 1
	}
	return -1
}

hh_raw_count :: proc(h: ^Hh, needle: string) -> int {
	count := 0
	at := 0
	for {
		i := hh_raw_index(h, needle, at)
		if i < 0 { break }
		count += 1
		at = i + 1
	}
	return count
}

// ─────────────────────────────────────────────────────────────────────────────
// Waiting for the app to exit
// ─────────────────────────────────────────────────────────────────────────────

hh_wait_exit :: proc(h: ^Hh, timeout_ms: f64) -> bool {
	t0 := time.tick_now()
	for {
		if h.d == nil { return false }
		if !pty.pty_alive(h.d) { return true }
		pty.pty_read(h.d, 25)
		if hh_elapsed_ms(t0) >= timeout_ms { return false }
	}
	return false
}

// hh_pump drains the pty for a fixed window so every byte the app wrote is in
// d.raw before an ordering assertion looks at it.
hh_pump :: proc(h: ^Hh, ms: f64) {
	if h.d == nil { return }
	pty.pty_read(h.d, ms)
}

hh_exit_info :: proc(h: ^Hh) -> string {
	if h.d == nil { return "no pty" }
	return pty.pty_exit_info(h.d)
}

// hh_i keeps scenario files readable: it formats a number for a detail string.
hh_i :: proc(v: i64) -> string { return fmt.tprintf("{}", v) }
