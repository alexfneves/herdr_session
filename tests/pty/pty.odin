package pty

// ─────────────────────────────────────────────────────────────────────────────
// pty.odin — T5, the driver: spawn a child on a pty, observe it, measure it.
//
// A port of dev/tui_drive.py:201-427 (Pty + base_env). The shapes here are
// LOAD-BEARING, not stylistic; each one exists because its absence produced a
// wrong measurement in the python suite. Where a shape is load-bearing the
// comment says what breaks without it.
//
// ── THE SPAWN KEEPS THE SLAVE OPEN IN THE PARENT, ON PURPOSE ──────────────
//   openpty → (master, slave); the parent holds BOTH for the whole life of
//   the scenario. Losing the slave is how you lose the whole post-mortem: once
//   every slave fd is closed the line discipline goes away and `tcgetattr`
//   stops being answerable, which is exactly the question
//   "did the app put the terminal back?" asks after the child dies.
//   (T3's pty_stays_interrogable_after_the_owning_child_dies is the proof
//   this works; this is the shape that makes it usable.)
//
// ── THE CHILD ALLOCATES NOTHING ───────────────────────────────────────────
//   The child of a fork inside a test binary inherits a heap shared
//   copy-on-write with a live test harness. Allocating there surfaces as a
//   failure in the PARENT much later. So argv/envp are built in the parent
//   BEFORE the fork, and the child's path is:
//       close(master) → setsid() → TIOCSCTTY(slave) → dup2 ×3
//       → chdir? → execve → _exit(127)
//   Nothing on that path allocates, formats, or touches the ledger. It ends in
//   `_exit`, not `exit`: exit() runs atexit handlers, and a forked child
//   running harness cleanup twice means a second ledger flush and a double
//   free of memory the parent still owns.
//
// ── TIMING IS MEASURED AS ARRIVAL, NEVER AS A WINDOW ──────────────────────
//   `resize_latency` times the FIRST BYTE of the repaint. The python's prior
//   version timed the whole read window and reported its own 2000 ms timeout
//   as if the app were slow. Same class of error applies to everything in
//   this file: a measurement that includes the harness's own waiting is
//   measuring the harness.
//
// ── EVIDENCE FORMAT IS NOT INVENTED HERE ──────────────────────────────────
//   The resize evidence line is rendered by `termhandoff.Coalescer.summary`
//   from src/terminal/resize.odin — the product's OWN format procedure — so
//   "matches the frozen format" is true BY CONSTRUCTION rather than true
//   because a copied string happened to look the same. `pty_evidence_format_is_product_format`
//   asserts that binding; if the product changes the string, that test says
//   so instead of T13's parser failing mysteriously.
//
// ── SINGLE-THREAD ENFORCEMENT ─────────────────────────────────────────────
//   `pty_single_thread_required` reads the runner's thread count and fails if
//   it is > 1. The plan's timing bounds (boot <= 4 s, idle <= 2 ticks,
//   resize < 500 ms) are competitive on a core-count parallel runner, and
//   the predictable response to that flake is loosening the numbers — a
//   silent loss of the assertion. Failing loudly on the wrong runner config
//   is cheaper than quietly widening a threshold.
// ─────────────────────────────────────────────────────────────────────────────

import "core:c"
import "core:fmt"
import "core:mem"
import "core:sys/posix"
import "core:os"
import "core:time"
import "core:unicode/utf8"

import th "../../src/terminal"

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

// BIN resolution mirrors the python's BIN: an explicit override wins, so a
// scenario can point at a freshly built binary rather than whatever is on
// PATH. Checked at spawn time, not baked in.
pty_bin_default :: "result/bin/herdr-session"

PTY_SCRUB_PREFIX :: "HERDR_"
PTY_SCRUB_KEYS := []string{"HERDR_ENV", "HERDR_SESSION", "HERDR_SOCKET_PATH"}

// Burst records one read: when it landed relative to spawn, and how big.
// The burst list is what makes "the repaint arrived" a fact rather than a
// feeling — mark-and-compare on its length is how resize_latency sees a
// response without looking at content.
Burst :: struct {
	t_ms : f64,
	len  : int,
}

// Pty_Driver owns one scenario: one spawn, one screen model, one verdict.
Pty_Driver :: struct {
	master : posix.FD,
	slave  : posix.FD,
	child  : posix.pid_t,

	rows : i32,
	cols : i32,

	screen : Screen,

	// The full byte history. Kept because a failed assertion is much cheaper
	// to diagnose when the raw stream is at hand — but assertions go through
	// `screen`, never through this.
	raw : [dynamic]u8,

	bursts  : [dynamic]Burst,
	t0      : time.Time,
	written : int, // bytes WE sent: the "no key was pressed" proof (ISC-13)

	termios_before : posix.termios,
	have_before    : bool,

	exit_status : c.int,
	has_exit    : bool,

	// The product's own coalescing accounting, driven by this harness so the
	// evidence string is the product's string.
	coalescer : th.Coalescer,
}

// ─────────────────────────────────────────────────────────────────────────────
// Spawn
// ─────────────────────────────────────────────────────────────────────────────

// pty_spawn runs the python's Pty.__init__ sequence exactly.
//
// Returns nil (and leaves `why` filled in) rather than asserting, so a caller
// can distinguish "could not start" from "started and misbehaved" — those are
// different failures and conflating them turns an environment problem into a
// red product test.
pty_spawn :: proc(argv: []string, rows, cols: i32, cwd: string = "") -> (d: ^Pty_Driver, err: string) {
	bin := pty_resolve_bin()
	if !pty_bin_exists(bin) {
		return nil, fmt.tprintf("binary not found: {}", bin)
	}

	// ALL allocation happens here, in the parent, before the fork.
	d = new(Pty_Driver)
	d.rows = rows
	d.cols = cols
	screen_init(&d.screen, int(rows), int(cols))
	d.raw = make([dynamic]u8)
	d.bursts = make([dynamic]Burst)
	d.coalescer = th.Coalescer{}

	p := open_pty(rows, cols)
	if !p.valid {
		free(d)
		return nil, fmt.tprintf("openpty failed: {}", errno_name())
	}
	d.master = p.master
	d.slave = p.slave

	// Snapshot the terminal the app is ABOUT to inherit. Any handler that does
	// not put termios back shows up as a mismatch against this — this is the
	// reference for the whole SIGTERM-restores-the-tty proof.
	bts : posix.termios = {}
	if posix.tcgetattr(d.slave, &bts) != {} {
		posix.close(d.master)
		posix.close(d.slave)
		free(d)
		return nil, fmt.tprintf("tcgetattr on the fresh slave failed: {}", errno_name())
	}
	d.termios_before = bts
	d.have_before = true

	// argv and envp are built NOW. The child must not allocate.
	argv_c := pty_build_argv(bin, argv)
	env_c := pty_build_env()
	// cwd must be a cstring built HERE, in the parent. to_cstring allocates,
	// and the child must not allocate.
	cwd_c : cstring = nil
	if len(cwd) > 0 { cwd_c = th.cstr(cwd) }

	pid := posix.fork()
	if pid < 0 {
		free_cstring_array(argv_c)
		free_cstring_array(env_c)
		if cwd_c != nil { free(rawptr(cwd_c)) }
		posix.close(d.master)
		posix.close(d.slave)
		free(d)
		return nil, fmt.tprintf("fork failed: {}", errno_name())
	}
	if pid == 0 {
		// ── CHILD ── no allocation, no formatting, no ledger below this line.
		posix.close(d.master)
		posix.setsid()
		acquire_controlling_terminal(d.slave)
		posix.dup2(d.slave, posix.FD(0))
		posix.dup2(d.slave, posix.FD(1))
		posix.dup2(d.slave, posix.FD(2))
		if int(d.slave) > 2 {
			posix.close(d.slave)
		}
		if len(cwd) > 0 {
			posix.chdir(cwd_c)
		}
		posix.execve(argv_c[0], &argv_c[0], &env_c[0])
		// execv only returns on failure. Report on the tty we still own, then
		// leave by the door that does not run cleanup.
		msg := "exec failed\n"
		posix.write(posix.FD(2), raw_data(msg), c.size_t(len(msg)))
		posix._exit(127)
	}

	// ── PARENT ── the child's copies vanished with execv; free ours.
	free_cstring_array(argv_c)
	free_cstring_array(env_c)
	if cwd_c != nil { free(rawptr(cwd_c)) }

	d.child = pid
	d.t0 = time.now()
	return d, ""
}

pty_resolve_bin :: proc() -> string {
	v := os.get_env_alloc("BIN", context.allocator)
	if len(v) > 0 { return v }
	v = os.get_env_alloc("HS_BIN", context.allocator)
	if len(v) > 0 { return v }
	return pty_bin_default
}

pty_bin_exists :: proc(path: string) -> bool {
	// O_RDONLY + immediate close is the honest existence check that does not
	// care about the file's size or type, only "can we open it".
	fd := posix.open(th.cstr(path), posix.O_Flags{})
	if int(fd) < 0 { return false }
	posix.close(fd)
	return true
}

// ─────────────────────────────────────────────────────────────────────────────
// argv / envp construction — DELEGATED TO THE PRODUCT, not reimplemented.
//
// `termhandoff.build_argv` and `termhandoff.build_scrubbed_env` are the same
// procedures the app's own handoff uses to spawn a child. Using them here
// means the harness cannot diverge from the product on what "scrub the HERDR_
// namespace" means: the python had its own scrub list, and if the product's
// namespace rule changed while the harness kept its own list, the harness
// would be testing a fiction. One implementation, owned by the product.
//
// Everything is still allocated in the PARENT before the fork — the product's
// helpers allocate, which is exactly why they are called here and not in the
// child.
// ─────────────────────────────────────────────────────────────────────────────

// pty_build_argv: [bin, args...] NULL-terminated.
pty_build_argv :: proc(bin: string, args: []string) -> [^]cstring {
	all : [dynamic]string
	append(&all, bin)
	for a in args { append(&all, a) }
	out := th.build_argv(all[:])
	delete(all)
	return out
}

// pty_build_env: the scrubbed environment array. HERDR_* removal is the
// product's rule (HERDR_NAMESPACE), not this file's.
pty_build_env :: proc() -> [^]cstring {
	return th.build_scrubbed_env()
}

// free_cstring_array releases a NULL-terminated C array and its members.
// free_cstring_array releases a NULL-terminated C array and its members.
// Walked to the terminator because [^]cstring carries no length — the NULL
// entry appended at build time is the only bound that exists.
free_cstring_array :: proc(a: [^]cstring) {
	if a == nil { return }
	i := 0
	for a[i] != nil {
		free(rawptr(a[i]))
		i += 1
	}
	free(rawptr(a))
}

// ─────────────────────────────────────────────────────────────────────────────
// Observation
// ─────────────────────────────────────────────────────────────────────────────

// pty_read drains whatever is available within `wait_ms`, feeds the SCREEN
// (not a buffer), and returns the new bytes.
//
// poll(), never a spin, never a bare blocking read: a bare read can hang the
// harness forever when the app is waiting for input, and a spin is the
// idle-loop the plan forbids. The poll timeout IS the wait.
pty_read :: proc(d: ^Pty_Driver, wait_ms: f64) -> int {
	deadline_ms := ms_since(time.now(), wait_ms)
	got := 0
	for {
		left_ms := deadline_ms - ms_now()
		if left_ms <= 0 { break }
		fd := posix.pollfd{
			fd      = d.master,
			events  = {posix.Poll_Event_Bits.IN},
			revents = {},
		}
		timeout := c.int(left_ms + 1)
		if timeout < 1 { timeout = 1 }
		n := posix.poll(&fd, 1, timeout)
		if n < 0 {
			// EINTR is not a failure here — a signal (SIGWINCH among them) can
			// wake us. Re-loop rather than treat it as the end of the stream.
			if posix.errno() == posix.Errno.EINTR { continue }
			break
		}
		if n == 0 { break }
		buf : [65536]u8
		rn := posix.read(d.master, &buf[0], c.size_t(len(buf)))
		if rn <= 0 { break }
		el := elapsed_ms(d)
		append(&d.bursts, Burst{t_ms = el, len = int(rn)})
		for i := 0; i < int(rn); i += 1 {
			append(&d.raw, buf[i])
		}
		screen_feed(&d.screen, buf[:int(rn)])
		got += int(rn)
	}
	return got
}

// pty_wait_screen: when did `needle` FIRST appear on the modelled screen?
// Screen, not byte stream — see the header of screen.odin for why the byte
// stream cannot answer this.
pty_wait_screen :: proc(d: ^Pty_Driver, needle: string, timeout_ms: f64, pump_ms: f64 = 50) -> f64 {
	end := ms_now() + timeout_ms
	for {
		if screen_contains(&d.screen, needle) { return elapsed_ms(d) }
		if ms_now() >= end { return -1 }
		pty_read(d, pump_ms)
	}
}

// Watch_Label is one (key, needle) pair for the concurrent watch.
Watch_Label :: struct {
	key    : string,
	needle : string,
}

// Seen_Label is one recorded first-arrival.
Seen_Label :: struct {
	key  : string,
	t_ms : f64,
}

// pty_watch_screen watches EVERY label at once and returns first-seen times.
//
// SEQUENTIAL pty_wait_screen CALLS LIE. The first one burns its whole
// timeout and every label after it then "appears" at the moment we finally
// looked, so a render order that was never observed gets recorded as a
// timing result. The pending-set shape below is what makes the numbers mean
// what they look like, and it is the shape the python kept for the same
// reason.
// pty_watch_screen watches EVERY label at once and returns first-seen times.
//
// SEQUENTIAL pty_wait_screen CALLS LIE. The first one burns its whole
// timeout and every label after it then "appears" at the moment we finally
// looked, so a render ORDER that was never observed gets recorded as a
// timing result. The pending-set shape below is what makes the numbers mean
// what they look like, and it is the shape the python kept for the same
// reason.
//
// `found` is a parallel bool array rather than in-place removal from
// `pending`: same observable behaviour, and it cannot skip a label the way a
// wrong index arithmetic in an in-place remove would — a skipped label is
// silently reported as "never appeared".
pty_watch_screen :: proc(d: ^Pty_Driver, labels: []Watch_Label, timeout_ms: f64, pump_ms: f64 = 50) -> [dynamic]Seen_Label {
	found : [dynamic]bool
	for _ in labels { append(&found, false) }
	remaining := len(labels)
	seen := make([dynamic]Seen_Label)
	end := ms_now() + timeout_ms

	for remaining > 0 && ms_now() < end {
		txt_buf : [dynamic]u8
		screen_text(&d.screen, &txt_buf)
		now_txt := string(txt_buf[:])
		for i := 0; i < len(labels); i += 1 {
			if found[i] { continue }
			if contains_bytes(now_txt, labels[i].needle) {
				found[i] = true
				remaining -= 1
				append(&seen, Seen_Label{key = labels[i].key, t_ms = elapsed_ms(d)})
			}
		}
		delete(txt_buf)
		if remaining > 0 { pty_read(d, pump_ms) }
	}
	delete(found)
	return seen
}

// ─────────────────────────────────────────────────────────────────────────────
// Input
// ─────────────────────────────────────────────────────────────────────────────

pty_send :: proc(d: ^Pty_Driver, s: string) -> bool {
	wn := posix.write(d.master, raw_data(s), c.size_t(len(s)))
	if wn < 0 { return false }
	d.written += int(wn)
	return int(wn) == len(s)
}

pty_keys :: proc(d: ^Pty_Driver, s: string, pause_ms: f64 = 350, settle_ms: f64 = 500) {
	for r in s {
		ch : [4]u8
		n := rune_to_utf8(r, &ch)
		pty_send(d, string(ch[:n]))
		time.sleep(ms_duration(pause_ms))
	}
	pty_read(d, settle_ms)
}

// ─────────────────────────────────────────────────────────────────────────────
// Resize
// ─────────────────────────────────────────────────────────────────────────────

// pty_resize: TIOCSWINSZ on the MASTER → kernel SIGWINCH to the child's
// foreground group → termbox self-pipe. The model follows the terminal, not
// the other way round: the emulator is resized because the real thing was.
pty_resize :: proc(d: ^Pty_Driver, rows, cols: i32) -> bool {
	rc := set_winsize(d.master, rows, cols)
	d.rows = rows
	d.cols = cols
	screen_resize(&d.screen, int(rows), int(cols))
	return rc == 0
}

// Resize_Evidence is one measured resize.
Resize_Evidence :: struct {
	rows       : i32,
	cols       : i32,
	latency_ms : f64,
	bytes      : int,
	ok         : bool,
	timed_out  : bool,
}

// pty_resize_latency: time from TIOCSWINSZ to the FIRST BYTE of repaint.
//
// NOT "time until the read window closed". The python's earlier version
// reported its own timeout as application latency; a 2000 ms number that
// means "we waited 2000 ms" is worse than no number, because it looks like
// a measurement of the app. The burst-count mark is what makes arrival
// visible without parsing content: a new burst after the mark means the app
// answered.
pty_resize_latency :: proc(d: ^Pty_Driver, rows, cols: i32, timeout_ms: f64 = 2000) -> Resize_Evidence {
	mark := len(d.bursts)
	send_ms := elapsed_ms(d)
	pty_resize(d, rows, cols)
	end := ms_now() + timeout_ms
	ev := Resize_Evidence{rows = rows, cols = cols, ok = false, timed_out = true}
	for ms_now() < end {
		pty_read(d, 50)
		if len(d.bursts) > mark {
			// The FIRST new burst is the repaint arriving. Its own timestamp
			// relative to the send is the latency; summing bytes over all new
			// bursts matches the python exactly.
			ev.latency_ms = d.bursts[mark].t_ms - send_ms
			for i := mark; i < len(d.bursts); i += 1 {
				ev.bytes += d.bursts[i].len
			}
			ev.ok = true
			ev.timed_out = false
			return ev
		}
	}
	return ev
}

// ─────────────────────────────────────────────────────────────────────────────
// Process state
// ─────────────────────────────────────────────────────────────────────────────

pty_alive :: proc(d: ^Pty_Driver) -> bool {
	if d.has_exit { return false }
	status : c.int = 0
	pid := posix.waitpid(d.child, &status, {.NOHANG})
	if pid == 0 { return true }
	d.exit_status = status
	d.has_exit = true
	return false
}

// pty_exit_info renders "exit=N" or "exit=143 (killed by 15)", the python's
// two shapes. NOTE 128+N: a signal-killed child reports 128+sig through the
// shell convention, and the WIFSIGNALED branch is the one that knows it.
// Treating a signalled child's raw status as an exit code is the bug class
// B9 calls out — 143 read as "exit code 143, the app chose to fail" instead
// of "the app was killed by SIGTERM".
pty_exit_info :: proc(d: ^Pty_Driver) -> string {
	if !d.has_exit { return "still running" }
	if posix.WIFEXITED(d.exit_status) {
		return fmt.tprintf("exit=%d", posix.WEXITSTATUS(d.exit_status))
	}
	if posix.WIFSIGNALED(d.exit_status) {
		sig := posix.WTERMSIG(d.exit_status)
		return fmt.tprintf("exit=%d (killed by signal %d)", 128 + int(sig), int(sig))
	}
	return fmt.tprintf("status=%d", int(d.exit_status))
}

pty_kill :: proc(d: ^Pty_Driver, sig: posix.Signal) -> bool {
	sent := posix.kill(d.child, sig) == {}
	// Reap unconditionally. An unreaped child is a zombie, and a zombie still
	// holds its fd table open — a leaked child here shows up later as a pty
	// that will not EOF, in a test that looks nothing like this one.
	status : c.int = 0
	posix.waitpid(d.child, &status, posix.Wait_Flags{})
	if !d.has_exit {
		d.exit_status = status
		d.has_exit = true
	}
	return sent
}

pty_signal_group :: proc(d: ^Pty_Driver, sig: posix.Signal) -> bool {
	// setsid() in the child made it a process-group leader, so the whole tree
	// can be signalled with the negative pid.
	return posix.kill(-d.child, sig) == {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Termios / CPU
// ─────────────────────────────────────────────────────────────────────────────

// pty_termios_now reads the terminal's CURRENT termios off the slave we kept
// open. Must work after the child died — that is the whole reason the slave is
// kept open.
pty_termios_now :: proc(d: ^Pty_Driver) -> (posix.termios, bool) {
	t : posix.termios = {}
	if posix.tcgetattr(d.slave, &t) != {} {
		return t, false
	}
	return t, true
}

// pty_cpu_ticks: utime+stime of the CHILD only, in clock ticks, from /proc.
//
// INDEXED FROM THE END OF THE FIELD LIST. Field 2 of /proc/<pid>/stat is
// `comm`, the process name in parens, and it may contain spaces — counting
// from the front then shifts every later field by an unknown amount and the
// "utime" you read is really some other field. Counting back from the end
// (utime is 15th from the end, stime 14th) is space-independent.
pty_cpu_ticks :: proc(d: ^Pty_Driver) -> (i64, bool) {
	path := fmt.tprintf("/proc/{}/stat", int(d.child))
	data, ok := read_file_bytes(path)
	if !ok || len(data) < 40 { return 0, false }
	fields := split_ws(data)
	// utime is fields[-15], stime fields[-14]; need at least 15 to exist.
	if len(fields) < 15 { return 0, false }
	u := parse_i64(fields[len(fields)-15])
	s := parse_i64(fields[len(fields)-14])
	return u + s, true
}

// ─────────────────────────────────────────────────────────────────────────────
// Evidence rendering
// ─────────────────────────────────────────────────────────────────────────────

// pty_render_resize_evidence renders the coalescing line THROUGH THE PRODUCT'S
// OWN PROCEDURE. This is the entire reason for importing `termhandoff`: the
// format is then not a copy that can drift, it is the same code the app runs.
pty_render_resize_evidence :: proc(d: ^Pty_Driver) -> string {
	return th.summary(&d.coalescer)
}

// pty_product_evidence_format is the frozen literal, read off the product's
// own renderer so it can be compared without duplicating the string in a
// test.
pty_product_evidence_format :: proc() -> string {
	c : th.Coalescer = {}
	th.note_resize(&c)
	th.note_paint(&c)
	return th.summary(&c)
}

// ─────────────────────────────────────────────────────────────────────────────
// Teardown
// ─────────────────────────────────────────────────────────────────────────────

pty_close :: proc(d: ^Pty_Driver) {
	if d == nil { return }
	// Kill first: closing fds under a live child lets it keep running against
	// a half-torn-down tty, and an unreaped child is a zombie that holds its
	// fd table (and therefore the pty's slave side) open past this test.
	if !d.has_exit {
		pty_kill(d, posix.Signal.SIGKILL)
	}
	posix.close(d.master)
	posix.close(d.slave)
	delete(d.raw)
	delete(d.bursts)
}

// ─────────────────────────────────────────────────────────────────────────────
// Small utilities (self-contained: this lane owns them)
// ─────────────────────────────────────────────────────────────────────────────

// All timing in this file is milliseconds on an f64 axis, computed from
// `time.since` against a captured base Time. `Time + Duration` is not an
// operation in Odin, so a deadline is "ms since a base" compared numerically
// rather than a future Time constructed with `+`.
elapsed_ms :: proc(d: ^Pty_Driver) -> f64 {
	return ms_since(d.t0, 0)
}

// ms_since: milliseconds elapsed since `base`, plus a constant offset.
ms_since :: proc(base: time.Time, add: f64) -> f64 {
	return f64(time.duration_nanoseconds(time.since(base))) / 1e6 + add
}

ms_now :: proc() -> f64 {
	return ms_since(time.now(), 0)
}

// ms_duration turns a millisecond count into a time.Duration for time.sleep.
ms_duration :: proc(ms: f64) -> time.Duration {
	return time.Duration(i64(ms * f64(time.Millisecond)))
}

rune_to_utf8 :: proc(r: rune, out: ^[4]u8) -> int {
	b, n := utf8.encode_rune(r)
	for i := 0; i < n; i += 1 { out[i] = b[i] }
	return n
}

// read_file_bytes reads a whole (small) file with raw fds. Used for
// /proc/<pid>/stat, which reports a size of 0 even though reading it yields
// content — so any size-based short-circuit must be avoided.
read_file_bytes :: proc(path: string) -> ([]u8, bool) {
	fd := posix.open(th.cstr(path), posix.O_Flags{})
	if int(fd) < 0 { return nil, false }
	defer posix.close(fd)
	out : [dynamic]u8
	buf : [4096]u8
	for {
		n := posix.read(fd, &buf[0], c.size_t(len(buf)))
		if n <= 0 { break }
		for i := 0; i < int(n); i += 1 { append(&out, buf[i]) }
	}
	return out[:], true
}

has_prefix :: proc(s, p: string) -> bool {
	if len(p) > len(s) { return false }
	for i := 0; i < len(p); i += 1 {
		if s[i] != p[i] { return false }
	}
	return true
}

split_ws :: proc(b: []u8) -> [][]u8 {
	out : [dynamic][]u8
	i := 0
	for i < len(b) {
		for i < len(b) && is_ws(b[i]) { i += 1 }
		start := i
		for i < len(b) && !is_ws(b[i]) { i += 1 }
		if i > start { append(&out, b[start:i]) }
	}
	return out[:]
}

is_ws :: proc(b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

parse_i64 :: proc(b: []u8) -> i64 {
	if len(b) == 0 { return -1 }
	neg := false
	i := 0
	if b[0] == '-' {
		neg = true
		i = 1
	}
	v : i64 = 0
	if i >= len(b) { return -1 }
	for ; i < len(b); i += 1 {
		if b[i] < '0' || b[i] > '9' { return -1 }
		v = v * 10 + i64(b[i] - '0')
	}
	if neg { return -v }
	return v
}
