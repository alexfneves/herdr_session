package it

// ─────────────────────────────────────────────────────────────────────────────
// resize_no_key_test.odin — ISC-13.
//
// A resize is a COMPLETE user action. Nobody pressed anything: a TIOCSWINSZ
// alone has to reach the loop, wake it, and come back as a repaint — inside one
// frame budget, at the NEW geometry.
//
// Three things have to be shown and each needs its own evidence:
//   • CAUSATION without input — `written` is the harness's own byte counter, so
//     "zero bytes written by us" is not a vibe, it is a number that would move
//     if a key had been pressed.
//   • LATENCY against a frozen budget (< 500 ms). pty_resize_latency marks the
//     burst list AFTER a drain, so the number is the arrival of the repaint and
//     not the width of our own wait window.
//   • GEOMETRY. The spine is drawn full-width by the app; measuring it BEFORE
//     the resize is what makes "it used the new width" a claim with a
//     comparison, instead of a screenshot.
//
// 3 reps, each with its own log (/tmp/hs-it-resize-no-key-repN.log) and its own
// trace file. Nothing here is concatenated across reps.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import pty "../pty"
import support "../support"

// ck is deliberately local to this file. support.check derives its ledger group
// from the CALLER's location, so a shared helper living in the harness would
// fold every scenario's assertions into one `resize_harness` group and destroy
// the per-scenario accounting this floor is measured in.
ck_no_key :: proc(t: ^testing.T, rep: int, name: string, cond: bool, detail: string) {
	support.check(t, fmt.tprintf("rep{} {}", rep, name), cond, detail)
}

@(test)
resize_no_key_isc13 :: proc(t: ^testing.T) {
	for rep in 1 ..= REPS { no_key_rep(t, rep) }
}

no_key_rep :: proc(t: ^testing.T, rep: int) {
	a, err := rh_spawn("no-key", rep, START_NO_KEY_ROWS, START_NO_KEY_COLS)
	if a == nil {
		ck_no_key(t, rep, "the app spawned on a pty", false, err)
		return
	}
	defer rh_finish(a)

	boot := pty.pty_wait_screen(a.d, BOOT_NEEDLE, BOOT_PAINT_TIMEOUT_MS)
	ck_no_key(t, rep, "the app painted before the resize",
		boot >= 0,
		fmt.tprintf("first paint at {}ms ({})", boot, pty.pty_exit_info(a.d)))
	if boot < 0 { return }

	// The baseline is the whole point of the width assertion. Take it while the
	// terminal is still 60 wide, before any resize exists.
	pty.pty_read(a.d, 400)
	base_lo, base_hi := rh_rule_widths(&a.d.screen)
	ck_no_key(t, rep, "the 60-col frame drew its spine at 60",
		base_lo == START_NO_KEY_COLS && base_hi == START_NO_KEY_COLS,
		fmt.tprintf("spine widths lo={} hi={} want {} (rows={})",
			base_lo, base_hi, START_NO_KEY_COLS, rh_rule_count(&a.d.screen)))

	wrote_before := a.d.written
	ev := pty.pty_resize_latency(a.d, START_NO_KEY_ROWS, NEW_NO_KEY_COLS, RESIZE_LATENCY_TIMEOUT_MS)

	// ISC-13 proper: the resize ALONE produced output, with no key in the
	// picture. `written` is the proof of the "no key" half; `bytes` of the
	// half that actually arrived.
	ck_no_key(t, rep, "a resize alone produced output (no key was pressed)",
		ev.bytes > 0 && a.d.written == wrote_before,
		fmt.tprintf("{} bytes after TIOCSWINSZ; bytes written by us = {} (unchanged)",
			ev.bytes, a.d.written))

	// Frozen: first repaint < 500 ms. Not a guess we are allowed to widen.
	ck_no_key(t, rep, "it landed inside one frame budget (< 500 ms)",
		ev.ok && ev.latency_ms < FIRST_FRAME_BUDGET_MS,
		fmt.tprintf("latency={} ms ok={} timed_out={}", ev.latency_ms, ev.ok, ev.timed_out))

	new_lo, new_hi := rh_rule_widths(&a.d.screen)
	ck_no_key(t, rep, "the repaint used the NEW width, not the old one",
		new_lo == NEW_NO_KEY_COLS && new_hi == NEW_NO_KEY_COLS,
		fmt.tprintf("spine widths lo={} hi={} want both {} (was {}x{} → {}x{})",
			new_lo, new_hi, NEW_NO_KEY_COLS, START_NO_KEY_ROWS, START_NO_KEY_COLS,
			START_NO_KEY_ROWS, NEW_NO_KEY_COLS))

	ck_no_key(t, rep, "zero key bytes were written by this harness, ever",
		a.d.written == 0,
		fmt.tprintf("harness bytes written = {}", a.d.written))

	stopped := rh_stop(a)
	ck_no_key(t, rep, "the app reported resize accounting",
		stopped && rh_has_resize_line(a.trace),
		fmt.tprintf("trace bytes={} ({}); want a `resize ` line", len(a.trace), a.trace_path))

	resizes, has_resizes := rh_resize_field(a.trace, "resizes")
	ck_no_key(t, rep, "the app counted the resize event",
		has_resizes && resizes >= 1,
		fmt.tprintf("resizes={} present={}", resizes, has_resizes))

	errs, has_errs := rh_total_field(a.trace, "errs")
	ck_no_key(t, rep, "the loop took no poll errors on the way",
		has_errs && errs == 0,
		fmt.tprintf("errs={} present={}", errs, has_errs))
}

START_NO_KEY_ROWS :: 30
START_NO_KEY_COLS :: 60
NEW_NO_KEY_COLS   :: 100
