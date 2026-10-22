package it

// ─────────────────────────────────────────────────────────────────────────────
// resize_flood_test.odin — the border drag.
//
// Thirty TIOCSWINSZ calls with no sleep between them, which is what a user
// dragging a terminal edge actually produces. What has to survive is not just
// the process:
//
//   • the FRAME: after coalescing, what is on screen must be the LAST size we
//     asked for. A coalescer that dropped events leaves a stale frame, which
//     looks exactly like a correct one until you measure it.
//   • the INVARIANT. Standard signals are not queued: if the window manager
//     fires 30 SIGWINCHs while the child is unscheduled, the kernel merges them
//     into ONE pending signal, so `resizes` can come back small even though 30
//     size changes happened. Both shapes are real and both must hold:
//         resizes >= 2 → the APP collapsed them → passes*2 <= resizes
//         resizes == 1 → the KERNEL collapsed them → passes <= 1
//     Asserting only the first fails spuriously under kernel merging; asserting
//     only the second passes while doing nothing. (Reasoning ported from
//     dev/resize_drive.py:213-235.)
//   • the LEDGER: no dropped resize (passes >= 1) and no real poll error, with
//     EINTR excluded because it is counted separately and handled by looping.
//
// 3 reps, one log per rep (/tmp/hs-it-resize-flood-repN.log).
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import pty "../pty"
import support "../support"

FLOOD_N :: 30

ck_flood :: proc(t: ^testing.T, rep: int, name: string, cond: bool, detail: string) {
	support.check(t, fmt.tprintf("rep{} {}", rep, name), cond, detail)
}

@(test)
resize_flood_survives_and_lands_final_size :: proc(t: ^testing.T) {
	for rep in 1 ..= REPS { flood_rep(t, rep) }
}

flood_rep :: proc(t: ^testing.T, rep: int) {
	storm_ms: f64 = 0
	a, err := rh_spawn("flood", rep, 30, 70)
	if a == nil {
		ck_flood(t, rep, "the app spawned on a pty", false, err)
		return
	}
	defer rh_finish(a)

	boot := pty.pty_wait_screen(a.d, BOOT_NEEDLE, BOOT_PAINT_TIMEOUT_MS)
	ck_flood(t, rep, "the app painted before the storm",
		boot >= 0, fmt.tprintf("first paint at {}ms ({})", boot, pty.pty_exit_info(a.d)))
	if boot < 0 { return }

	// SETTLE BEFORE THE STORM. The python sleeps 0.3 s and reads 0.2 s first, and
	// that is not padding: the coalescing invariant is a statement about a burst
	// arriving at an IDLE loop. Start while the app is still working through its
	// boot repaint and you are measuring something else — events land one per
	// poll cycle and the ratio collapses (observed: 22 events / 7 passes with no
	// settle, 1 event / 1 pass after it).
	quiet_pre := 0
	for i in 0 ..< 6 {
		quiet_pre = rh_silence_window(a.d, 200)
		if quiet_pre == 0 { break }
	}
	rh_log(a.log, fmt.tprintf("pre-storm silence: {} bytes in the last window", quiet_pre))

	wrote_before := a.d.written
	storm_t0 := pty.elapsed_ms(a.d)
	last_rows: i32 = 0
	last_cols: i32 = 0
	for i in 0 ..< FLOOD_N {
		last_rows = 20 + i32(i % 12)
		last_cols = 60 + i32(i * 2)
		if !pty.pty_resize(a.d, last_rows, last_cols) {
			ck_flood(t, rep, fmt.tprintf("TIOCSWINSZ #{} succeeded", i + 1), false,
				fmt.tprintf("resize to {}x{} failed", last_rows, last_cols))
		}
	}
	storm_ms = pty.elapsed_ms(a.d) - storm_t0
	rh_log(a.log, fmt.tprintf("storm: {} TIOCSWINSZ in {} ms (final {}x{})",
		FLOOD_N, storm_ms, last_rows, last_cols))
	// Settle so the last repaint has actually landed before we read the grid.
	pty.pty_read(a.d, 1500)

	ck_flood(t, rep, "the app survived the storm",
		pty.pty_alive(a.d), pty.pty_exit_info(a.d))

	ck_flood(t, rep, "no key input across the whole drag",
		a.d.written == wrote_before && a.d.written == 0,
		fmt.tprintf("bytes written by us over {} resizes = {}", FLOOD_N, a.d.written))

	// The frame must match the LAST request, not something from mid-drag.
	lo, hi := rh_rule_widths(&a.d.screen)
	ck_flood(t, rep, "the surviving frame is the FINAL size, not a stale one",
		lo == int(last_cols) && hi == int(last_cols) && rh_rule_count(&a.d.screen) >= 2,
		fmt.tprintf("spine widths lo={} hi={} want {} (last request {}x{}, rows={})",
			lo, hi, int(last_cols), last_rows, last_cols, rh_rule_count(&a.d.screen)))

	stopped := rh_stop(a)
	ck_flood(t, rep, "the app reported resize accounting",
		stopped && rh_has_resize_line(a.trace),
		fmt.tprintf("trace bytes={} ({}); want a `resize ` line", len(a.trace), a.trace_path))

	resizes, has_resizes := rh_resize_field(a.trace, "resizes")
	passes, has_passes := rh_resize_field(a.trace, "passes")
	max_run, _ := rh_resize_field(a.trace, "max_run")

	ck_flood(t, rep, "the app saw resize events at all",
		has_resizes && resizes > 0,
		fmt.tprintf("resize_events={}", resizes))

	// No dropped resize: whatever the kernel delivered, the app laid it out.
	ck_flood(t, rep, "every resize still ended up laid out (no dropped resize)",
		has_passes && passes >= 1,
		fmt.tprintf("{} events -> {} passes", resizes, passes))

	// Layout passes never exceed resize events.
	ck_flood(t, rep, "layout passes never exceed resize events",
		has_passes && has_resizes && passes <= resizes,
		fmt.tprintf("{} resize events -> {} layout passes", resizes, passes))

	// The has_* flags are inside the expression on purpose: a trace with no
	// counters would otherwise satisfy the `resizes < 2 → passes <= 1` branch
	// with 0 and 0 and report a merge that never happened.
	coalesced := has_resizes && has_passes &&
		((resizes >= 2 && passes * 2 <= resizes) || (resizes < 2 && passes <= 1))
	ck_flood(t, rep, "COALESCED: the burst collapsed into far fewer layout passes than events",
		coalesced,
		fmt.tprintf("resizes={} passes={} max_run={} (app-merge needs passes*2<=resizes; kernel-merge needs passes<=1)",
			resizes, passes, max_run))

	errs, has_errs := rh_total_field(a.trace, "errs")
	eintr, has_eintr := rh_resize_field(a.trace, "eintr")
	ck_flood(t, rep, "the storm produced no real poll error (EINTR excluded, counted separately)",
		has_errs && errs == 0,
		fmt.tprintf("errs(fatal)={} eintr={} eintr_reported={}", errs, eintr, has_eintr))
}
