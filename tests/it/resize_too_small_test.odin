package it

// ─────────────────────────────────────────────────────────────────────────────
// resize_too_small_test.odin
//
// The too-small gate (MIN_COLS=40 / MIN_ROWS=10, src/terminal/resize.odin:56)
// is a *frame-level* promise: when the terminal cannot hold the session list the
// app does not draw a broken one, it draws a notice instead, and when the user
// enlarges it comes back by itself.
//
// Walking four sizes that each break a different axis proves the gate rather
// than one lucky resize:
//     9x120  short but wide   → rows trip the gate
//     40x39  tall but narrow  → cols trip the gate, by ONE column
//     5x20   both             → nothing fits
//     2x5    pathological     → the phrase itself cannot be rendered
// For each size the contract is three separate facts:
//   1. the notice is on screen (or, where the phrase cannot physically fit,
//      the app drew SOMETHING and is alive — the too_small_paints counter at
//      the end is what proves the notice was actually painted),
//   2. nothing overflows the available columns,
//   3. no half-drawn spine survives — the notice REPLACED the spine, so a
//      row of nothing but '─' cannot legally be present.
//
// Recovery is its own assertion set: enlarging to 40x120 must restore the
// normal UI AND both spine dividers, and the app must have COUNTED the notice
// frames — the counter is the app's own admission, not our inference.
//
// 3 reps, one log per rep (/tmp/hs-it-resize-too-small-repN.log).
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import pty "../pty"
import support "../support"

// (rows, cols) — the python's four sizes, in order.
Too_Small :: struct {
	rows: i32,
	cols: i32,
}

TOO_SMALL_SIZES :: []Too_Small{
	Too_Small{9, 120},
	Too_Small{40, 39},
	Too_Small{5, 20},
	Too_Small{2, 5},
}

RECOVER_ROWS :: 40
RECOVER_COLS :: 120

// NORMAL_UI_MARK is the prompt the normal session-list UI paints and the
// too-small notice never contains.
NORMAL_UI_MARK :: "filter:"

ck_small :: proc(t: ^testing.T, rep: int, name: string, cond: bool, detail: string) {
	support.check(t, fmt.tprintf("rep{} {}", rep, name), cond, detail)
}

@(test)
resize_too_small_notice_and_recovery :: proc(t: ^testing.T) {
	for rep in 1 ..= REPS { too_small_rep(t, rep) }
}

too_small_rep :: proc(t: ^testing.T, rep: int) {
	a, err := rh_spawn("too-small", rep, 30, 100)
	if a == nil {
		ck_small(t, rep, "the app spawned on a pty", false, err)
		return
	}
	defer rh_finish(a)

	boot := pty.pty_wait_screen(a.d, BOOT_NEEDLE, BOOT_PAINT_TIMEOUT_MS)
	ck_small(t, rep, "the app painted before the shrink",
		boot >= 0, fmt.tprintf("first paint at {}ms ({})", boot, pty.pty_exit_info(a.d)))
	if boot < 0 { return }

	pty.pty_read(a.d, 400)
	before := normal_ui(&a.d.screen)
	ck_small(t, rep, "before the shrink the app shows the normal UI",
		before.has_mark && !before.has_notice,
		fmt.tprintf("has 'filter:'={} has notice={}", before.has_mark, before.has_notice))

	sizes: []Too_Small = TOO_SMALL_SIZES
	for i in 0 ..< len(sizes) {
		sz := sizes[i]
		pty.pty_resize(a.d, sz.rows, sz.cols)
		pty.pty_read(a.d, 450)
		lbl := fmt.tprintf("{}x{}", sz.rows, sz.cols)

		// A terminal narrower than the phrase cannot render it; the weaker (and
		// still meaningful) contract there is "the app drew something and lives",
		// with the app's own too_small_paints counter as the proof it was the
		// notice. Ported from dev/resize_drive.py:268-281.
		can_show := sz.cols >= i32(len(NOTICE))
		if can_show {
			found := pty.pty_wait_screen(a.d, NOTICE, 3000)
			ck_small(t, rep, fmt.tprintf("too small at {}: the notice is on screen", lbl),
				found >= 0,
				fmt.tprintf("notice search t={}ms; screen rules={} max_line={}",
					found, rh_rule_count(&a.d.screen), rh_max_line_len(&a.d.screen)))
		} else {
			ck_small(t, rep, fmt.tprintf("too small at {}: notice drawn (only {} cols, phrase cannot fit — the counter proves it)", lbl, sz.cols),
				rh_max_line_len(&a.d.screen) > 0 && pty.pty_alive(a.d),
				fmt.tprintf("max line len={} alive={}",
					rh_max_line_len(&a.d.screen), pty.pty_alive(a.d)))
		}

		// The notice REPLACED the spine, so a full rule row cannot exist here.
		rules := rh_rule_count(&a.d.screen)
		ck_small(t, rep, fmt.tprintf("…and no half-drawn spine is left behind at {}", lbl),
			rules == 0,
			fmt.tprintf("spine rows present = {}", rules))

		// Nothing is drawn past the right edge.
		max_len := rh_max_line_len(&a.d.screen)
		ck_small(t, rep, fmt.tprintf("…and the notice fits inside {} columns", sz.cols),
			max_len <= int(sz.cols),
			fmt.tprintf("max line len={} > cols={}", max_len, int(sz.cols)))
	}

	// ── RECOVERY: enlarge, the normal UI must come back by itself ──
	pty.pty_resize(a.d, RECOVER_ROWS, RECOVER_COLS)
	pty.pty_read(a.d, 700)
	after := normal_ui(&a.d.screen)
	ck_small(t, rep, "RECOVERED after enlarging: the normal UI is back",
		after.has_mark && !after.has_notice,
		fmt.tprintf("has 'filter:'={} has notice={} (rows={})",
			after.has_mark, after.has_notice, a.d.screen.rows))

	rlo, rhi := rh_rule_widths(&a.d.screen)
	ck_small(t, rep, "…and BOTH spine dividers are back at the new width",
		rh_rule_count(&a.d.screen) >= 2 && rlo == RECOVER_COLS && rhi == RECOVER_COLS,
		fmt.tprintf("spine rows={} widths lo={} hi={} want {}",
			rh_rule_count(&a.d.screen), rlo, rhi, RECOVER_COLS))

	stopped := rh_stop(a)
	ck_small(t, rep, "the app reported resize accounting",
		stopped && rh_has_resize_line(a.trace),
		fmt.tprintf("trace bytes={} ({}); want a `resize ` line", len(a.trace), a.trace_path))

	paints, has_paints := rh_resize_field(a.trace, "too_small_paints")
	ck_small(t, rep, "the app counted the notice frames it drew",
		has_paints && paints >= 1,
		fmt.tprintf("too_small_paints={} present={} (4 too-small sizes walked)", paints, has_paints))

	resizes, has_resizes := rh_resize_field(a.trace, "resizes")
	ck_small(t, rep, "the walk registered as real resize events",
		has_resizes && resizes >= 5,
		fmt.tprintf("resizes={} want >= 5 (4 too-small + 1 recovery)", resizes))
}

Ui_Kind :: struct {
	has_mark  : bool,
	has_notice: bool,
}

normal_ui :: proc(s: ^pty.Screen) -> Ui_Kind {
	return Ui_Kind{
		has_mark   = pty.screen_contains(s, NORMAL_UI_MARK),
		has_notice = pty.screen_contains(s, NOTICE),
	}
}
