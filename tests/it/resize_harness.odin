package it

// ─────────────────────────────────────────────────────────────────────────────
// resize_harness.odin — T13's shared plumbing. NO counted assertions live here.
//
// Every `support.check` fires from a scenario file, so every ledger group is a
// scenario and this file can never inflate a total. What lives here is:
//
//   • the per-scenario+rep LOG and the per-scenario+rep TRACE path
//   • the spawn/stop lifecycle that hands the app HS_TUI_TRACE and reads it back
//   • the trace PARSER (no regex: core:regex is absent from this project)
//   • the screen MEASURERS (spine rules, line widths, notice lines)
//
// ── ONE LOG PER SCENARIO+REP, NEVER CONCATENATED ─────────────────────────────
// `rh_spawn` derives both the trace path and the log path from (scenario, rep)
// and opens them with TRUNC. Nothing ever appends to a previous rep's file, so a
// later scenario cannot inherit an earlier one's PASSes — the failure mode the
// no-concatenation rule exists to prevent. Each log line is written the moment it
// is produced, so a crash mid-scenario still leaves the evidence behind.
//
// ── THE TRACE CONTRACT (verified, frozen) ─────────────────────────────────────
// The app writes its own record at exit, gated on HS_TUI_TRACE=<path>
// (src/main.odin:1186 `tui_dump_trace`). Two lines matter:
//
//   total=<n>ms frames=<n> polls=<n> hits=<n> idles=<n> errs=<n> remote_fans=<n> local_ms=<n> first_paint_ms=<n>
//   resize resizes=%d passes=%d max_run=%d ratio=%.1f too_small_paints=%d eintr=%d
//
// The `resize ` PREFIX comes from tui_dump_trace, NOT from summary()
// (src/terminal/resize.odin:175). The all-`%` format is deliberate — Odin
// cannot mix `{}` and `%` in one format string — and is frozen.
//
// Parsing follows the python exactly: pick the line that starts with the prefix,
// split on whitespace, read `key=<int>`. No regex.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

import pty "../pty"

// REPS is the scenario repeat count: 4 scenarios × 3 reps = 12 runs.
REPS :: 3

// ── FROZEN THRESHOLDS ───────────────────────────────────────────────────────
// Widening one of these is a change to the contract, not a fix for a flake.
// A flake is a bug. See the tests/parity.tsv header.
BOOT_PAINT_TIMEOUT_MS   :: 8000.0
FIRST_FRAME_BUDGET_MS   :: 500.0 // ISC-13: resize → first repaint
RESIZE_LATENCY_TIMEOUT_MS :: 2000.0

// BOOT_NEEDLE is the title the app paints; same handle pty_test.odin uses.
BOOT_NEEDLE :: "herdr-session"

// NOTICE is the too-small banner text — mirrors too_small_message() in
// src/terminal/resize.odin:68.
NOTICE :: "terminal too small"

// MIN_COLS / MIN_ROWS mirror src/terminal/resize.odin:56-57. Mirrored rather
// than imported so a scenario file never needs the product's package alias to
// state a bound; drift shows up red, not silent.
MIN_COLS :: 40
MIN_ROWS :: 10

// SPINE_UTF8 is the '─' glyph the app draws its dividers with, as bytes. Byte
// comparison rather than rune literals keeps the scanner a pure byte loop, which
// keeps the "half-drawn" question decidable.
SPINE_UTF8 :: "─"

// HEADER_STATE_ROW is the row the CURRENT STATE is painted on, and since RCH-9
// that is the SECOND header row, not the footer: FRAME_PAD is 0 and frame_open
// paints the title first and the state second, so the state lives on row 1.
// Every scenario that asks "what state does the user think they are in" reads
// this row, and reading it is now the only honest way to ask.
HEADER_STATE_ROW :: 1

// rh_header_state renders the state line, stripped. Compare it to the exact
// phrase rather than substring-testing the whole screen: "Attach session" as a
// substring could come from a session named "Attach sessionX"; the header line
// equal to "Attach session" cannot.
rh_header_state :: proc(s: ^pty.Screen) -> string {
	if HEADER_STATE_ROW >= s.rows { return "" }
	return rh_strip(rh_row_text(s, HEADER_STATE_ROW))
}

// ─────────────────────────────────────────────────────────────────────────────
// Log — one file per scenario+rep
// ─────────────────────────────────────────────────────────────────────────────

Rh_Log :: struct {
	path : string,
	f    : ^os.File,
	open : bool,
}

rh_artifact_path :: proc(scenario: string, rep: int, ext: string) -> string {
	return fmt.tprintf("/tmp/hs-it-resize-{}-rep{}.{}", scenario, rep, ext)
}

rh_log_open :: proc(scenario: string, rep: int) -> ^Rh_Log {
	l := new(Rh_Log)
	l.path = rh_artifact_path(scenario, rep, "log")
	f, err := os.open(l.path, os.File_Flags{.Write, .Create, .Trunc})
	if err != nil {
		l.open = false
		return l
	}
	l.f = f
	l.open = true
	return l
}

// rh_log writes immediately. A buffered logger is a logger that loses the
// evidence exactly when the evidence is needed most: at the crash.
rh_log :: proc(l: ^Rh_Log, line: string) {
	if l == nil || !l.open { return }
	os.write_string(l.f, line)
	os.write_string(l.f, "\n")
}

rh_log_close :: proc(l: ^Rh_Log) {
	if l == nil { return }
	if l.open { os.close(l.f) }
	free(l)
}

// ─────────────────────────────────────────────────────────────────────────────
// Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

Rh_App :: struct {
	d          : ^pty.Pty_Driver,
	trace_path : string,
	log        : ^Rh_Log,
	trace      : string,
	stopped    : bool,
}

// rh_spawn boots `herdr-session tui` on a pty with HS_TUI_TRACE aimed at a
// file owned by THIS scenario+rep and nothing else.
//
// The env var is set in the parent immediately before the spawn because the
// driver builds the child's environment from the parent's at fork time
// (`pty_build_env` → `terminal.build_scrubbed_env`, which copies os.environ
// minus HERDR_*). Setting it earlier would leak into other scenarios' spawns;
// setting it later means the app never sees it.
//
// Returns (nil, reason) rather than asserting, so the CALLER files the check
// under its own ledger group.
rh_spawn :: proc(scenario: string, rep: int, rows, cols: i32) -> (a: ^Rh_App, err: string) {
	trace := rh_artifact_path(scenario, rep, "trace")
	_ = os.remove(trace) // stale file from an earlier run is not evidence
	if e := os.set_env("HS_TUI_TRACE", trace); e != nil {
		return nil, fmt.tprintf("os.set_env(HS_TUI_TRACE) failed: {}", e)
	}
	d, serr := pty.pty_spawn([]string{"tui"}, rows, cols)
	if serr != "" {
		return nil, serr
	}
	a = new(Rh_App)
	a.d = d
	a.trace_path = trace
	a.log = rh_log_open(scenario, rep)
	rh_log(a.log, fmt.tprintf("scenario rep{} rows={} cols={} bin={} trace={}",
		rep, rows, cols, pty.pty_resolve_bin(), trace))
	return a, ""
}

// rh_stop asks the app to leave the way a user would end it and then reads the
// trace it wrote. Ctrl+C (\x03 written to the master → SIGINT to the foreground
// group), NOT SIGTERM: SIGINT is the app's "the user asked to quit" path, which
// walks out through tui_dump_trace; SIGTERM was observed dying before the dump
// (exit=143, trace file never created). The trace only ever exists AFTER the
// exit, which is why every scenario ends here rather than sampling mid-run.
rh_stop :: proc(a: ^Rh_App) -> bool {
	if a == nil || a.stopped { return len(a.trace) > 0 }
	a.stopped = true
	pty.pty_send(a.d, "\x03")
	for _ in 0 ..< 50 {
		a.trace = rh_slurp(a.trace_path)
		if len(a.trace) > 0 { break }
		time.sleep(100 * time.Millisecond)
	}
	rh_read_pipe(a)
	rh_log(a.log, fmt.tprintf("exit: {} trace_bytes={}", pty.pty_exit_info(a.d), len(a.trace)))
	for ln in rh_split_lines(a.trace) { rh_log(a.log, fmt.tprintf("  {}", ln)) }
	return len(a.trace) > 0
}

// rh_finish stops (if the scenario forgot), tears the pty down and closes the
// log. Idempotent, so a scenario can `defer rh_finish(a)` safely.
rh_finish :: proc(a: ^Rh_App) {
	if a == nil { return }
	rh_stop(a)
	pty.pty_kill(a.d, posix_sigkill())
	pty.pty_close(a.d)
	rh_log_close(a.log)
	a.log = nil
}

// rh_read_pipe drains whatever the child last wrote so the modelled screen and
// the burst list are current before we look at either.
rh_read_pipe :: proc(a: ^Rh_App) {
	pty.pty_read(a.d, 150)
}

// ─────────────────────────────────────────────────────────────────────────────
// Trace parsing — no regex (core:regex is absent), and deliberately the same
// shape the python driver uses: prefix → whitespace fields → key=<int>.
// ─────────────────────────────────────────────────────────────────────────────

rh_split_lines :: proc(text: string) -> [dynamic]string {
	out := make([dynamic]string, 0, 16)
	start := 0
	for i := 0; i <= len(text); i += 1 {
		if i == len(text) || text[i] == '\n' {
			if i > start { append(&out, text[start:i]) }
			start = i + 1
		}
	}
	return out
}

// rh_line_with_prefix returns the first line whose bytes start with `prefix`.
rh_line_with_prefix :: proc(text: string, prefix: string) -> string {
	start := 0
	for start <= len(text) {
		end := len(text)
		if i := strings.index(text[start:], "\n"); i >= 0 { end = start + i }
		line := text[start:end]
		if strings.has_prefix(line, prefix) { return line }
		if end == len(text) { break }
		start = end + 1
	}
	return ""
}

// rh_field reads `key=<int>` out of one whitespace-separated line. A missing
// key, a non-numeric value, or a key that only appears as a substring of some
// other token all come back as (0, false) so the caller's assertion says so.
rh_is_ws :: proc(b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\r'
}

rh_field :: proc(line: string, key: string) -> (int, bool) {
	tok := fmt.tprintf("{}=", key)
	i := 0
	for i < len(line) {
		for i < len(line) && rh_is_ws(line[i]) { i += 1 }
		start := i
		for i < len(line) && !rh_is_ws(line[i]) { i += 1 }
		if start == i { continue }
		f := line[start:i]
		if !strings.has_prefix(f, tok) { continue }
		v := f[len(tok):]
		neg := false
		if len(v) > 0 && v[0] == '-' {
			neg = true
			v = v[1:]
		}
		if len(v) == 0 { continue }
		n := 0
		digits := 0
		for j := 0; j < len(v); j += 1 {
			if v[j] < '0' || v[j] > '9' { break }
			n = n * 10 + int(v[j] - '0')
			digits += 1
		}
		if digits != len(v) { continue } // trailing junk is not a number
		if neg { n = -n }
		return n, true
	}
	return 0, false
}

// rh_resize_field reads a counter off the app's own `resize ` line.
rh_resize_field :: proc(trace: string, key: string) -> (int, bool) {
	return rh_field(rh_line_with_prefix(trace, "resize "), key)
}

// rh_total_field reads a counter off the `total=` line. The 'ms' suffix on
// total=...ms is dropped by the caller asking for the bare key inside that one
// line, so we look the key up on the line that starts with "total=".
rh_total_field :: proc(trace: string, key_with_unit: string) -> (int, bool) {
	line := rh_line_with_prefix(trace, "total=")
	return rh_field(line, key_with_unit)
}

// rh_has_resize_line is the "the app reported resize accounting at all" test.
rh_has_resize_line :: proc(trace: string) -> bool {
	return len(rh_line_with_prefix(trace, "resize ")) > 0
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen measurement. Everything goes through the driver's SCREEN model, never
// through raw bytes — "did the app paint" is a question about the grid.
// ─────────────────────────────────────────────────────────────────────────────

rh_row_text :: proc(s: ^pty.Screen, r: int) -> string {
	buf: [dynamic]u8
	if !pty.screen_row_text(s, r, &buf) { return "" }
	if len(buf) == 0 { delete(buf); return "" }
	// Clone out before the dynamic buffer goes away: the returned string is
	// handed to callers that outlive this frame, and the grid scanner runs
	// once per row per measurement, so an unfreed buffer here is not a leak
	// you can ignore at 40 rows a pop.
	out := strings.clone(string(buf[:]), context.allocator)
	delete(buf)
	return out
}

// rh_strip removes leading/trailing blanks. Hand-rolled because the trim
// helpers' cutset API is the kind of thing that changes under you; this cannot.
rh_strip :: proc(s: string) -> string {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') { i += 1 }
	j := len(s)
	for j > i && (s[j - 1] == ' ' || s[j - 1] == '\t') { j -= 1 }
	return s[i:j]
}

// rh_rune_len counts runes, matching python's len() on a decoded line.
rh_rune_len :: proc(s: string) -> int {
	n := 0
	for _ in s { n += 1 }
	return n
}

// rh_is_rule: the line is non-blank and made of NOTHING but the spine glyph.
// This is the same predicate the python's `set(ln.strip()) == {"─"}` uses.
rh_is_rule :: proc(s: string) -> bool {
	t := rh_strip(s)
	if len(t) == 0 { return false }
	spine := string(SPINE_UTF8[:])
	k := 0
	for k < len(t) {
		if k + len(spine) > len(t) { return false }
		for m := 0; m < len(spine); m += 1 {
			if t[k + m] != spine[m] { return false }
		}
		k += len(spine)
	}
	return true
}

// rh_rule_count: how many full-spine rows are on screen. While the app is in
// the too-small notice this MUST be zero — a non-zero count during a too-small
// frame is a half-drawn spine.
rh_rule_count :: proc(s: ^pty.Screen) -> int {
	n := 0
	for r := 0; r < s.rows; r += 1 {
		if rh_is_rule(rh_row_text(s, r)) { n += 1 }
	}
	return n
}

// rh_rule_widths returns the min and max spine width in runes (-1,-1 if none).
// "every spine is exactly W wide" ⇔ min == max == W, which is the no-partial-
// row statement without building a list.
rh_rule_widths :: proc(s: ^pty.Screen) -> (lo: int, hi: int) {
	lo, hi = -1, -1
	for r := 0; r < s.rows; r += 1 {
		txt := rh_row_text(s, r)
		if !rh_is_rule(txt) { continue }
		w := rh_rune_len(rh_strip(txt))
		if lo < 0 || w < lo { lo = w }
		if w > hi { hi = w }
	}
	return lo, hi
}

// rh_max_line_len: the widest rendered line in runes. "drawn within available
// cols" ⇔ max_line_len <= cols, which is the no-overflow statement.
rh_max_line_len :: proc(s: ^pty.Screen) -> int {
	m := 0
	for r := 0; r < s.rows; r += 1 {
		n := rh_rune_len(rh_row_text(s, r))
		if n > m { m = n }
	}
	return m
}

// rh_line_with finds the first row containing `needle` and returns its row index
// and rendered rune width (-1, 0 when absent).
rh_line_with :: proc(s: ^pty.Screen, needle: string) -> (row, width: int) {
	for r := 0; r < s.rows; r += 1 {
		txt := rh_row_text(s, r)
		if strings.contains(txt, needle) { return r, rh_rune_len(rh_strip(txt)) }
	}
	return -1, 0
}

// ─────────────────────────────────────────────────────────────────────────────
// Small io / process helpers
// ─────────────────────────────────────────────────────────────────────────────

rh_slurp :: proc(path: string) -> string {
	// os.open rather than posix.open: it takes a string, so no cstring to keep
	// alive across the read loop and no freeing hazard on the error paths.
	f, err := os.open(path, os.File_Flags{.Read})
	if err != nil || f == nil { return "" }
	defer os.close(f)
	buf := make([dynamic]u8, 0, 8192)
	tmp: [4096]u8
	for {
		n, rerr := os.read(f, tmp[:])
		if n <= 0 || rerr != nil { break }
		for i := 0; i < n; i += 1 { append(&buf, tmp[i]) }
	}
	if len(buf) == 0 { return "" }
	return string(buf[:])
}

// posix_sigterm / posix_sigkill are indirected so the scenario files never need
// to import posix themselves for a kill.
posix_sigterm :: proc() -> posix.Signal { return posix.Signal.SIGTERM }
posix_sigkill :: proc() -> posix.Signal { return posix.Signal.SIGKILL }

// posix_sigstop / posix_sigcont are here for the same reason, and they exist for
// ONE use: the falsification control in resize_eintr_test. Stopping the process
// is how you make "the app is not reading its input" a fact you can test
// against rather than a hypothesis; see that file for why it is not a stunt.
posix_sigstop :: proc() -> posix.Signal { return posix.Signal.SIGSTOP }
posix_sigcont :: proc() -> posix.Signal { return posix.Signal.SIGCONT }

// rh_freeze / rh_thaw signal the app by pid and report whether the signal was
// delivered. They deliberately do NOT wait for anything: the caller's timing is
// the measurement.
rh_freeze :: proc(a: ^Rh_App) -> bool {
	if a == nil || a.d == nil { return false }
	return posix.kill(a.d.child, posix_sigstop()) == {}
}

rh_thaw :: proc(a: ^Rh_App) -> bool {
	if a == nil || a.d == nil { return false }
	return posix.kill(a.d.child, posix_sigcont()) == {}
}

// rh_screen_snapshot renders the whole grid into one string so a scenario can
// ask "did ANY cell change?" without re-reading the screen mid-comparison.
rh_screen_snapshot :: proc(s: ^pty.Screen) -> string {
	buf : [dynamic]u8
	pty.screen_text(s, &buf)
	out := strings.clone(string(buf[:]), context.allocator)
	delete(buf)
	return out
}

// Rh_Spine is one sample of the painted spine.
Rh_Spine :: struct {
	rules: int,
	lo, hi: int,
}

rh_spine_of :: proc(s: ^pty.Screen) -> Rh_Spine {
	lo, hi := rh_rule_widths(s)
	return Rh_Spine{ rh_rule_count(s), lo, hi }
}

// rh_wait_stable_spine polls until two CONSECUTIVE samples of the spine agree
// on rule count and spine widths, or the timeout expires. It returns the last
// (settled) spine plus whether it actually stabilised.
//
// WHY THIS EXISTS. A single snapshot of the grid after a resize storm can catch
// the app between writes: termbox flushes a full-screen frame in more than one
// write() when the frame is big, and the emulator applies each burst as it
// arrives, so a mid-frame sample legitimately shows one rule painted and the
// other not yet. That is not the product's final state, and a test that asserts
// on one sample is asserting on a transient. This is a real, pre-existing race:
// `resize_flood` failed ~1 run in 10 on the committed tree with
// "spine widths lo=118 hi=118 want 118, rows=1" — correct width, one rule
// short, because the sample landed mid-flush.
//
// Requiring two identical consecutive samples is STRICTER than the old
// sleep-then-peek, not looser: it asserts the picture has STOPPED CHANGING, and
// a frame that is stuck wrong (stale size, half spine) still fails the
// assertions that read the returned spine. The timeout is reported so a slow
// settle is visible rather than silently absorbed.
rh_wait_stable_spine :: proc(d: ^pty.Pty_Driver, timeout_ms: f64) -> (sp: Rh_Spine, stabilised: bool) {
	end := pty.ms_until(d, timeout_ms)
	prev := rh_spine_of(&d.screen)
	tries := 0
	for !pty.over_due(d, end) {
		pty.pty_read(d, 150)
		cur := rh_spine_of(&d.screen)
		tries += 1
		if cur.rules == prev.rules && cur.lo == prev.lo && cur.hi == prev.hi && cur.rules > 0 {
			return cur, true
		}
		prev = cur
		if !pty.pty_alive(d) { break }
	}
	return prev, false
}

rh_wait_key_reply :: proc(d: ^pty.Pty_Driver, key: string, timeout_ms: f64) -> pty.Resize_Evidence {
	// The key-input twin of pty_resize_latency, and it needs the same care:
	// DRAIN FIRST, mark the burst list, press, then the first NEW burst is the
	// reply. Without the drain a leftover frame from before the keypress is
	// credited to the key, and "the app answered the key" becomes a lie that
	// reads exactly like the truth.
	pty.pty_read(d, 250)
	mark := len(d.bursts)
	send_ms := pty.elapsed_ms(d)
	pty.pty_send(d, key)
	end := pty.ms_until(d, timeout_ms)
	ev := pty.Resize_Evidence{ok = false, timed_out = true}
	for !pty.over_due(d, end) && !d.eof {
		pty.pty_read(d, 50)
		if len(d.bursts) > mark {
			ev.latency_ms = d.bursts[mark].t_ms - send_ms
			for i := mark; i < len(d.bursts); i += 1 { ev.bytes += d.bursts[i].len }
			ev.ok = true
			ev.timed_out = false
			return ev
		}
	}
	return ev
}

// silence_window returns the number of bytes the app emitted during a quiet
// period with no input from us. Zero means the stream settled, which is the
// baseline the "press a key, see a repaint" claim needs.
rh_silence_window :: proc(d: ^pty.Pty_Driver, ms: f64) -> int {
	before := total_burst_bytes(d)
	pty.pty_read(d, ms)
	return total_burst_bytes(d) - before
}

total_burst_bytes :: proc(d: ^pty.Pty_Driver) -> int {
	n := 0
	for b in d.bursts { n += b.len }
	return n
}
