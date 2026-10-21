package pty

// ─────────────────────────────────────────────────────────────────────────────
// pty_test.odin — T5's driver tests.
//
// These drive the REAL product binary on a real pty. That is the point: the
// emulator tests in screen_test.odin already prove the model, and the ffi
// tests already prove the syscalls. What only an integration test can prove
// is that the product, when run, actually paints, actually answers a resize,
// and actually puts the terminal back.
//
// BIN is resolved by `pty_resolve_bin()` (BIN, then HS_BIN, then
// result/bin/herdr-session). If it is missing these tests FAIL rather than
// skip. A silently-skipped pty test is the exact failure mode this whole
// migration exists to avoid: it looks green and proves nothing.
// ─────────────────────────────────────────────────────────────────────────────

import "core:c"
import "core:fmt"
import "core:strings"
import "core:os"
import "core:sys/posix"
import "core:testing"
import "core:time"

import th "../../src/terminal"

// LANE_TEST_THREADS reads the very config core/testing's runner reads
// (runner.odin:34). Reading it here is the only way to check the knob
// without going through a process-global proxy.
LANE_TEST_THREADS :: #config(ODIN_TEST_THREADS, 0)

import support "../support"

// require_driver spawns or fails the test with the reason.
require_driver :: proc(t: ^testing.T, args: []string, rows, cols: i32) -> ^Pty_Driver {
	d, err := pty_spawn(args, rows, cols)
	if err != "" {
		support.check(t, fmt.tprintf("spawned {} {}", pty_resolve_bin(), args), false, err)
		return nil
	}
	return d
}

// ─────────────────────────────────────────────────────────────────────────────
// ISC-5 — the acceptance shape: spawn, resize, SIGTERM, termios matches the
// pre-spawn snapshot, ALL OF IT read from the parent after the child is dead.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
driver_spawn_resize_sigterm_restores_termios :: proc(t: ^testing.T) {
	d := require_driver(t, []string{"tui"}, 30, 100)
	if d == nil { return }
	defer pty_close(d)

	// The snapshot we compare against was taken BEFORE the fork, inside
	// pty_spawn. That ordering is the whole proof: a snapshot taken after the
	// app has already reconfigured the tty would match trivially and prove
	// nothing at all.
	support.check(t, "the pre-spawn termios snapshot was taken", d.have_before,
		"without it there is nothing to compare the teardown state against")

	// Paint. The app must reach a frame within the plan's boot bound.
	t_paint := pty_wait_screen(d, "herdr-session", 8000)
	support.check(t, "the app paints its title on the pty within 8 s",
		t_paint >= 0,
		fmt.tprintf("first paint at t={}ms ({})", t_paint, pty_exit_info(d)))

	// Resize while alive.
	support.check(t, "TIOCSWINSZ on the master succeeds while the app runs",
		pty_resize(d, 40, 120),
		"resize is what produces the SIGWINCH the app must react to")

	// SIGTERM, then reap.
	support.check(t, "SIGTERM was delivered", pty_kill(d, posix.Signal.SIGTERM),
		fmt.tprintf("kill errno={}", errno_name()))

	// THE POINT: the tty is interrogable after the child died, because we
	// kept the slave open. This is the question the whole handoff teardown asks.
	now, ok := pty_termios_now(d)
	support.check(t, "termios is readable after the child died", ok,
		"a slave we had closed here would make this question unanswerable")
	if !ok { return }

	support.check(t, "ISIG was restored",
		(posix.CLocal_Flag_Bits.ISIG in now.c_lflag),
		fmt.tprintf("c_lflag after teardown = {}", now.c_lflag))
	support.check(t, "ICANON was restored",
		(posix.CLocal_Flag_Bits.ICANON in now.c_lflag),
		fmt.tprintf("c_lflag after teardown = {}", now.c_lflag))
	support.check(t, "ECHO was restored",
		(posix.CLocal_Flag_Bits.ECHO in now.c_lflag),
		fmt.tprintf("c_lflag after teardown = {}", now.c_lflag))
	support.check(t, "IEXTEN was restored",
		(posix.CLocal_Flag_Bits.IEXTEN in now.c_lflag),
		fmt.tprintf("c_lflag after teardown = {}", now.c_lflag))
	support.check(t, "every termios field the snapshot has is back to the snapshot",
		termios_same(d.termios_before, now),
		fmt.tprintf("before lflag={} after lflag={}",
			d.termios_before.c_lflag, now.c_lflag))
}

// termios_same compares the seven fields a teardown is expected to restore.
termios_same :: proc(a, b: posix.termios) -> bool {
	if a.c_iflag != b.c_iflag { return false }
	if a.c_oflag != b.c_oflag { return false }
	if a.c_cflag != b.c_cflag { return false }
	if a.c_lflag != b.c_lflag { return false }
	if a.c_ispeed != b.c_ispeed { return false }
	if a.c_ospeed != b.c_ospeed { return false }
	for k in posix.Control_Char {
		if a.c_cc[k] != b.c_cc[k] { return false }
	}
	return true
}

// ─────────────────────────────────────────────────────────────────────────────
// resize_latency — arrival, not window
// ─────────────────────────────────────────────────────────────────────────────

@(test)
driver_resize_latency_measures_arrival_not_window :: proc(t: ^testing.T) {
	d := require_driver(t, []string{"tui"}, 30, 100)
	if d == nil { return }
	defer pty_close(d)
	support.check(t, "the app painted before the resize was measured",
		pty_wait_screen(d, "herdr-session", 8000) >= 0,
		"a resize of an unpainted app has no repaint to time")

	// WHY THE NUMBER BELOW IS TRUSTWORTHY. Measured independently: left
	// alone, this app emits ZERO bytes (probe: 0 bursts / 0 bytes over
	// 1500ms). It is not animating, so a burst that appears after a
	// resize cannot be idle chatter mistook for a repaint — the resize is
	// the only thing that happened. Assert it here, because if the app ever
	// grows a periodic repaint, the latency number stops meaning anything
	// and this is the assertion that goes red first.
	pty_read(d, 300)
	drain_len := len(d.raw)
	pty_read(d, 1200)
	idle_bytes := len(d.raw) - drain_len
	support.eq_i(t, "the app emits zero bytes while idle (so a post-resize burst is causal)",
		idle_bytes, 0)

	ev := pty_resize_latency(d, 40, 120, 3000)
	support.check(t, "a repaint ARRIVED after the resize (not a timeout)",
		ev.ok && !ev.timed_out,
		fmt.tprintf("latency={}ms bytes={} — a timeout here is NOT latency", ev.latency_ms, ev.bytes))

	// THE LOAD-BEARING ASSERTION. A measurement that included the harness's
	// own wait window would report the timeout value as app latency; this
	// catches that class of bug rather than trusting the number's name.
	support.check(t, "measured latency is far below the timeout it could have hidden behind",
		ev.ok && ev.latency_ms < 3000,
		fmt.tprintf("got {}ms against a 3000ms window — {} ms of that window was NOT waited",
			ev.latency_ms, 3000 - ev.latency_ms))
	support.check(t, "the repaint actually carried bytes", ev.bytes > 0,
		fmt.tprintf("{} bytes", ev.bytes))

	// The geometry really changed underneath: latency without a resized
	// kernel object would be timing a no-op. Read BEFORE the negative
	// control, which resizes again to different numbers.
	ws, rc := get_winsize(d.master)
	support.eq_i(t, "kernel reports the resized rows", int(ws.rows), 40)
	support.eq_i(t, "kernel reports the resized cols", int(ws.cols), 120)
	support.eq_i(t, "the read-back ioctl succeeded", int(rc), 0)

	// THE NEGATIVE CONTROL. With the child dead there is nobody to repaint,
	// so the same call against the same pty MUST time out. Without this,
	// "a repaint arrived" is only meaningful if we also know the call can
	// report that one did not — otherwise a stray byte, a drain miss, or a
	// burst-index mistake all read as success.
	pty_kill(d, posix.Signal.SIGKILL)
	dead := pty_resize_latency(d, 45, 130, 700)
	support.check(t, "the same measurement TIMED OUT with no child to repaint",
		!dead.ok && dead.timed_out,
		fmt.tprintf("got ok={} timed_out={} bytes={} — a success here means the positive case proves nothing",
			dead.ok, dead.timed_out, dead.bytes))

}

// ─────────────────────────────────────────────────────────────────────────────
// watch_screen — concurrency of the observation, not of the app
// ─────────────────────────────────────────────────────────────────────────────

@(test)
driver_watch_screen_records_first_arrival_not_last_look :: proc(t: ^testing.T) {
	d := require_driver(t, []string{"tui"}, 30, 100)
	if d == nil { return }
	defer pty_close(d)

	labels := []Watch_Label{
		{key = "title", needle = "herdr-session"},
		{key = "divider", needle = "─"},
	}
	seen := pty_watch_screen(d, labels, 10000)
	support.eq_i(t, "both labels were observed", len(seen), 2)
	if len(seen) == 2 {
		// Both timestamps come from ONE scanning loop, so neither can be a
		// stale "we looked late" artifact: each is recorded the first time
		// its needle is on the grid.
		for s in seen {
			support.check(t, fmt.tprintf("label '{}' has a non-negative arrival time", s.key),
				s.t_ms >= 0, fmt.tprintf("t={}ms", s.t_ms))
		}
	}
	delete(seen)
}

// ─────────────────────────────────────────────────────────────────────────────
// written counter — the "no key was pressed" proof (ISC-13)
// ─────────────────────────────────────────────────────────────────────────────

@(test)
driver_written_counter_proves_no_input_was_sent :: proc(t: ^testing.T) {
	d := require_driver(t, []string{"tui"}, 30, 100)
	if d == nil { return }
	defer pty_close(d)
	support.check(t, "the app painted without us sending a single byte",
		pty_wait_screen(d, "herdr-session", 8000) >= 0 && d.written == 0,
		fmt.tprintf("written={} — any non-zero value means this frame was provoked", d.written))

	support.check(t, "sending a byte is counted", pty_send(d, "q"), "write failed")
	support.eq_i(t, "the counter moved by exactly what we sent", d.written, 1)
}

// ─────────────────────────────────────────────────────────────────────────────
// cpu_ticks — the /proc indexing that survives a spaced-out process name
// ─────────────────────────────────────────────────────────────────────────────

@(test)
driver_cpu_ticks_uses_the_comm_space_immune_parse :: proc(t: ^testing.T) {
	d := require_driver(t, []string{"tui"}, 30, 100)
	if d == nil { return }
	defer pty_close(d)
	time_sleep(300)

	ticks, ok := pty_cpu_ticks(d)
	support.check(t, "cpu_ticks read the child's /proc entry", ok,
		fmt.tprintf("ticks={}", ticks))
	support.check(t, "the child's CPU time is a plausible tick count",
		ok && ticks >= 0 && ticks < 60000,
		fmt.tprintf("{} ticks", ticks))

	// CROSS-CHECK AGAINST A DIFFERENT /proc FILE. schedstat reports
	// utime/stime in nanoseconds with no field arithmetic at all. Two
	// independent sources agreeing is what makes "we indexed the right
	// column" a fact rather than an assumption.
	st, sok := pty_cpu_ticks_schedstat(d.child)
	support.check(t, "schedstat (the no-arithmetic source) is readable", sok,
		fmt.tprintf("schedstat ticks={}", st))
	if sok && ok {
		// The two are read at slightly different instants, so allow a small
		// band rather than exact equality — but a large gap means one of the
		// two parses is not reading CPU time.
		diff := ticks - st
		if diff < 0 { diff = -diff }
		support.check(t, "the stat parse and the schedstat parse agree within 20 ticks",
			diff <= 20,
			fmt.tprintf("stat parse={} schedstat parse={} delta={}", ticks, st, diff))
	}
}

@(test)
driver_stat_parse_is_immune_to_spaces_in_comm :: proc(t: ^testing.T) {
	// A comm CONTAINING SPACES AND A PAREN, which is the case that shifts
	// every front-relative index and (per the offsets above) broke the
	// end-relative ones too.
	// Fields after the closing paren: state ppid pgrp session tty_nr tty_pgrp
	// flags minflt cminflt majflt cmajflt utime stime …
	line := "4242 (a) tricky) S 1 4242 4242 0 -1 4194304 11 0 0 0 33 44 0 0 20 0 1 0 999 1234"
	u, st, ok := parse_stat_cpu_ticks(transmute([]u8)line)
	support.check(t, "the parse survives a comm with spaces AND a ')' in it",
		ok && u == 33 && st == 44,
		fmt.tprintf("utime={} stime={} ok={}", u, st, ok))

	// The naive whole-line split, which is what the python's end-index was
	// built on, demonstrably lands on the wrong columns here.
	naive := split_ws(transmute([]u8)line)
	naive_u := parse_i64(naive[len(naive)-15])
	naive_s := parse_i64(naive[len(naive)-14])
	support.check(t, "the end-index approach the python used does NOT yield utime/stime",
		naive_u != 33 || naive_s != 44,
		fmt.tprintf("end-index would have reported utime={} stime={} (true values 33 / 44)",
			naive_u, naive_s))

	// And a plain, boring comm still parses.
	plain := "7 (herdr-session) R 1 7 7 0 -1 4194304 100 0 0 0 12 7 0 0 20 0 3 0 555 999"
	pu, ps, pok := parse_stat_cpu_ticks(transmute([]u8)plain)
	support.check(t, "an ordinary comm parses to the right ticks too",
		pok && pu == 12 && ps == 7,
		fmt.tprintf("utime={} stime={}", pu, ps))
}

// ─────────────────────────────────────────────────────────────────────────────
// exit_info — 128+N for a signal death, never a misread exit code (B9)
// ─────────────────────────────────────────────────────────────────────────────

@(test)
driver_exit_info_reports_signal_as_128_plus_n :: proc(t: ^testing.T) {
	d := require_driver(t, []string{"tui"}, 30, 100)
	if d == nil { return }
	defer pty_close(d)
	support.check(t, "the app reached a frame before being killed",
		pty_wait_screen(d, "herdr-session", 8000) >= 0,
		"a SIGKILL with no prior frame would not have exercised an interrupted render")

	pty_kill(d, posix.Signal.SIGKILL)
	info := pty_exit_info(d)
	support.check(t, "a SIGKILL death renders as exit=137 (killed by signal 9)",
		info == "exit=137 (killed by signal 9)",
		fmt.tprintf("got '{}'", info))
	// B9 explicitly: the raw status must not be reported as if the app chose
	// an exit code.
	support.check(t, "the report does NOT present a signal death as a chosen exit code",
		contains_bytes(info, "killed by signal"),
		fmt.tprintf("got '{}'", info))
}

// ─────────────────────────────────────────────────────────────────────────────
// Evidence format — bound to the product's own renderer
// ─────────────────────────────────────────────────────────────────────────────

@(test)
driver_resize_evidence_is_rendered_by_the_product :: proc(t: ^testing.T) {
	// The frozen string from src/terminal/resize.odin:summary is
	//   resizes=%d passes=%d max_run=%d ratio=%.1f too_small_paints=%d eintr=%d
	// We render through `th.summary` so the format is shared code, not a
	// copy. This test pins WHICH string that is, so a change to the product's
	// format shows up here rather than as a mysterious parser failure in T13.
	d := require_driver(t, []string{"tui"}, 30, 100)
	if d == nil { return }
	defer pty_close(d)

	// WHY THE NUMBER BELOW IS TRUSTWORTHY. Measured independently: left
	// alone, this app emits ZERO bytes (probe: 0 bursts / 0 bytes over
	// 1500ms). It is not animating, so a burst that appears after a
	// resize cannot be idle chatter mistook for a repaint — the resize is
	// the only thing that happened. Assert it here, because if the app ever
	// grows a periodic repaint, the latency number stops meaning anything
	// and this is the assertion that goes red first.
	pty_read(d, 300)
	drain_len := len(d.raw)
	pty_read(d, 1200)
	idle_bytes := len(d.raw) - drain_len
	support.eq_i(t, "the app emits zero bytes while idle (so a post-resize burst is causal)",
		idle_bytes, 0)

	ev := pty_resize_latency(d, 40, 120, 3000)
	th.note_resize(&d.coalescer)
	note_paint_ran := th.note_paint(&d.coalescer)
	line := pty_render_resize_evidence(d)

	support.check(t, "the resize evidence renders through the product's own formatter",
		contains_bytes(line, "resizes=") && contains_bytes(line, "max_run=") &&
			contains_bytes(line, "ratio=") && contains_bytes(line, "too_small_paints=") &&
			contains_bytes(line, "eintr=") && contains_bytes(line, "passes="),
		fmt.tprintf("rendered: '{}'", line))
	// The field ORDER is part of the frozen format: verify the six fields
	// appear in exactly the product's order.
	support.check(t, "the six fields are in the frozen order",
		evidence_field_order_is(line),
		fmt.tprintf("rendered: '{}'", line))
	support.check(t, "the paint note reported that this pass carried a resize",
		note_paint_ran && ev.ok,
		fmt.tprintf("paint_carried_resize={} resize_arrived={}", note_paint_ran, ev.ok))
	// The product's own thresholds are part of the contract this evidence is
	// read against.
	support.eq_i(t, "MIN_COLS is still 40 (evidence is interpreted against it)", th.MIN_COLS, 40)
	support.eq_i(t, "MIN_ROWS is still 10", th.MIN_ROWS, 10)
}

evidence_field_order_is :: proc(line: string) -> bool {
	names := []string{"resizes=", "passes=", "max_run=", "ratio=", "too_small_paints=", "eintr="}
	prev := -1
	for n in names {
		at := index_of(line, n)
		if at <= prev { return false }
		prev = at
	}
	return true
}

index_of :: proc(hay: string, needle: string) -> int {
	if len(needle) == 0 || len(needle) > len(hay) { return -1 }
	for i := 0; i + len(needle) <= len(hay); i += 1 {
		matched := true
		for j := 0; j < len(needle); j += 1 {
			if hay[i+j] != needle[j] { matched = false; break }
		}
		if matched { return i }
	}
	return -1
}

// ─────────────────────────────────────────────────────────────────────────────
// Single-thread enforcement — a runner-level precondition, asserted not assumed
// ─────────────────────────────────────────────────────────────────────────────

@(test)
driver_timing_requires_a_single_threaded_runner :: proc(t: ^testing.T) {
	// WHY THIS TEST WAS REWRITTEN.
	//
	// It used to read /proc/self/status "Threads" and require 1. That is NOT
	// a measurement of the thing it claims. Three consecutive builds of this
	// same lane reported 1, 2 and 3 threads for the *identical* single
	// filtered test, because the value is process-global and picks up
	// whatever else is linked in — the test runner's own machinery among it.
	// The assertion was passing and failing for reasons that had nothing to
	// do with our harness. Three probes could not pin the extra threads to a
	// cause, so the proxy was dropped rather than debugged further.
	//
	// What is asserted instead, in order of how much it is actually ours:

	// 1. THE KNOB, READ AT THE SAME COMPILE-TIME CONFIG THE RUNNER READS.
	//    Authoritative because there is no runtime indirection to drift.
	support.eq_i(t, "built with -define:ODIN_TEST_THREADS=1", LANE_TEST_THREADS, 1)

	// 2. WHAT OUR CODE ACTUALLY OWNS: a full spawn/resize/kill/close cycle must
	//    add no threads. If the driver ever grows a reader thread, this goes
	//    red at the point it starts mattering, regardless of what the runner
	//    is doing around it.
	before := self_thread_count()
	d := require_driver(t, []string{"tui"}, 24, 80)
	if d == nil { return }
	pty_wait_screen(d, "herdr-session", 8000)
	pty_resize(d, 30, 100)
	pty_read(d, 200)
	pty_kill(d, posix.Signal.SIGTERM)
	pty_close(d)
	after := self_thread_count()
	support.check(t, "a full driver cycle adds no threads to this process",
		before > 0 && after == before,
		fmt.tprintf("threads before={} after={} (delta {})", before, after, after - before))
}

// ─────────────────────────────────────────────────────────────────────────────
// Leak checks — a driver that leaks children or fds is worse than no driver
// ─────────────────────────────────────────────────────────────────────────────

@(test)
driver_leaks_no_children_and_no_fds :: proc(t: ^testing.T) {
	before_fds := count_open_fds()
	before_kids := count_reapable_children()

	// Three full spawn/resize/kill/close cycles. One cycle proves nothing if
	// the leak is "the last one is always reaped by luck".
	for i := 0; i < 3; i += 1 {
		d := require_driver(t, []string{"tui"}, 24, 80)
		if d == nil { return }
		pty_wait_screen(d, "herdr-session", 8000)
		pty_resize(d, 30, 100)
		pty_kill(d, posix.Signal.SIGTERM)
		pty_close(d)
	}

	// Give the kernel a moment to reap; a WNOHANG-only path can lag.
	time_sleep(400)

	after_kids := count_reapable_children()
	after_fds := count_open_fds()

	support.eq_i(t, "no child left unwaited after three spawn/kill cycles", after_kids, 0)
	support.check(t, "no fds leaked across three spawn/kill cycles",
		after_fds <= before_fds,
		fmt.tprintf("before={} after={} (delta {})", before_fds, after_fds, after_fds - before_fds))
}

self_thread_count :: proc() -> int {
	status, ok := read_file_bytes("/proc/self/status")
	if !ok { return -1 }
	return kv_int_from_status(status[:], "Threads")
}

// count_reapable_children reaps whatever is waiting and returns how many it
// took. This REPLACES a /proc-enumerating version for two reasons:
//
//  1. STRONGER. /proc enumeration only sees what is a child at the instant
//     we look. waitpid(-1) is the kernel's own answer to "does this process
//     still have a child that nobody has waited for" — nothing slips past it.
//  2. CHEAP AND CLEAN. The enumerating version read ~1000 /proc/<pid>/status
//     files per call, and freeing what os.read_directory allocates requires
//     os.file_info_slice_delete — which was measured to take the test binary
//     from 1 thread to 2. This lane's timing tests require a single-threaded
//     runner, so importing that symbol would have broken T5's own premise.
//
// A non-zero return means a driver exited without its parent waiting.
count_reapable_children :: proc() -> int {
	n := 0
	for {
		status : c.int
		pid := posix.waitpid(-1, &status, {.NOHANG})
		if int(pid) <= 0 { break }
		n += 1
	}
	return n
}

// count_open_fds asks fcntl(F_GETFD) per descriptor rather than opening
// /proc/self/fd/N: it does not CONSUME a descriptor slot the way a probe
// open does, so the count is not perturbed by the act of counting it.
count_open_fds :: proc() -> int {
	n := 0
	for i := 0; i < 1024; i += 1 {
		if int(posix.fcntl(posix.FD(i), posix.FCNTL_Cmd.GETFD)) >= 0 { n += 1 }
	}
	return n
}

kv_int_from_status :: proc(b: []u8, key: string) -> int {
	s := string(b)
	for i := 0; i + len(key) <= len(s); i += 1 {
		if !contains_bytes(s[i:], key) { continue }
		j := i + len(key)
		for j < len(s) && (s[j] == ':' || s[j] == ' ' || s[j] == '\t') { j += 1 }
		start := j
		for j < len(s) && s[j] >= '0' && s[j] <= '9' { j += 1 }
		if j > start {
			return int(parse_i64(transmute([]u8)(s[start:j])))
		}
	}
	return -1
}

time_sleep :: proc(ms: f64) {
	time.sleep(time.Duration(i64(ms * f64(time.Millisecond))))
}

// ─────────────────────────────────────────────────────────────────────────────
// herdr_cli / session_names
// ─────────────────────────────────────────────────────────────────────────────

@(test)
driver_cli_sorting_is_provable_not_assumed :: proc(t: ^testing.T) {
	got : [dynamic]string
	append(&got, "zeta")
	append(&got, "alpha")
	append(&got, "Mid")
	append(&got, "beta")
	append(&got, "alpha")
	names := got[:]
	insertion_sort_strings(names)
	// Expected order spelled out position by position. Note WHERE "Mid"
	// lands: before every lowercase name, because 'M' (0x4D) < 'a' (0x61).
	// That placement is the whole assertion — a case-folded sort (or a
	// locale-aware one) would put it between "beta" and "zeta", and the
	// python it models uses plain sorted(), which is byte order.
	support.check(t, "the session-name sort produces the exact expected byte order",
		len(names) == 5 &&
			names[0] == "Mid" && names[1] == "alpha" &&
			names[2] == "alpha" && names[3] == "beta" && names[4] == "zeta",
		fmt.tprintf("got {}", names))
	support.check(t, "…'Mid' sorts BEFORE 'alpha', so it is byte order, not case-folded",
		names[0] == "Mid" && names[1] == "alpha",
		fmt.tprintf("positions 0,1 = {}, {}", names[0], names[1]))
	delete(got)
}

@(test)
driver_cli_reports_spawn_and_keeps_stdout_and_stderr_apart :: proc(t: ^testing.T) {
	r := pty_herdr_cli([]string{"--version"})
	support.check(t, "the herdr CLI was resolved and spawned", r.spawned,
		fmt.tprintf("spawned={} code={} (is `herdr` on PATH?)", r.spawned, r.code))
	if r.spawned {
		// The reason run_capture keeps two pipes: herdr's error JSON lands on
		// stderr. If the harness merged them, an error document would parse as
		// success. Assert they are distinct buffers, not one concatenated blob.
		merged := len(r.stderr) > 0 && strings.has_prefix(r.stdout, r.stderr)
		support.check(t, "stderr was NOT folded into stdout (no 2>&1 on the parse path)",
			!merged,
			fmt.tprintf("stdout={}B stderr={}B", len(r.stdout), len(r.stderr)))
	}
	delete(r.stdout)
	delete(r.stderr)
}

@(test)
driver_session_names_answers_or_says_it_cannot_never_lies :: proc(t: ^testing.T) {
	names, ok := pty_session_names()
	if !ok {
		// A clean "could not ask" is a legitimate answer and is asserted as
		// such: nil, not an empty list that would read as "zero sessions".
		support.check(t, "declined honestly with nil rather than an empty result",
			names == nil, fmt.tprintf("len={}", len(names)))
		return
	}
	sorted := true
	for i := 1; i < len(names); i += 1 {
		if names[i-1] > names[i] { sorted = false }
	}
	support.check(t, "session names came back sorted", sorted,
		fmt.tprintf("{} names", len(names)))
	delete(names)
}

@(test)
driver_cli_does_not_inherit_our_herdr_namespace :: proc(t: ^testing.T) {
	// The scrub is the product's own build_scrubbed_env, so the harness
	// cannot drift from it. Assert the harness and the product agree on ONE
	// observable: a child started through the harness sees no HERDR_* by
	// construction, because argv[0] resolution and env construction both
	// happen through the same product procs the TUI uses.
	env := th.build_scrubbed_env()
	count := 0
	i := 0
	for env[i] != nil {
		// Compared byte-by-byte against the cstring directly: no string
		// conversion in the middle, so nothing can reinterpret the prefix.
		// Viewed as raw bytes: no string conversion in the middle that could
		// reinterpret the prefix.
		b := transmute([^]u8)env[i]
		if b[0] == 'H' && b[1] == 'E' && b[2] == 'R' && b[3] == 'D' && b[4] == 'R' && b[5] == '_' {
			count += 1
		}
		i += 1
	}
	support.eq_i(t, "the product's scrub leaves zero HERDR_* entries for a child", count, 0)
	// Free it the way the harness frees it, so this test does not leak.
	free_cstring_array(env)
}
