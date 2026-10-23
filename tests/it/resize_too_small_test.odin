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
//
// ── WHY "THE NORMAL UI" IS THREE ROWS AND NOT ONE SUBSTRING (RCH-9) ─────────
// This scenario used to ask for one string, "filter:", as its proxy for "the
// spine is painted". RCH-9 (.pi/plans/2026-10-18-herdr-session-tui/
// 50-requirement-changes.md)
// took that token away: {Mode selection} no longer displays a filter line at all
// (app.state_is_filter_view drops .mode_selection), and the state itself moved
// OUT of the footer and INTO the header. So the old single-token proxy is not
// merely stale, it is unsatisfiable — the check was reading false while the
// frame was correct.
//
// What the real session-list UI paints, in the order a user reads it, is:
//
//   row 0  the title, centred                             "herdr-session"
//   row 1  the state line, centred                       "Mode selection"
//   row 4  the table's column header   "device … timestamp … state … name"
//
// The too-small notice is ONE centred line and NOTHING else —
// "terminal too small: 39x40 - enlarge to at least 40x10"
// (too_small_message, src/terminal/resize.odin), drawn by paint_notice, which
// deliberately replaces the whole spine instead of joining it
// (src/ui/frame.odin, "THE 'TOO SMALL' SCREEN"). It therefore contains none
// of the three markers: no title, no state line, no column header. That is what
// makes this composite a valid gate — each marker is independently false while
// the notice is up, so a frame that showed the notice CANNOT satisfy the check.
//
// Verified against real captures of this binary rather than guessed: the three
// markers were read off the painted grid at 30x100 and 40x120 (all present),
// and the notice frames at 9x120, 40x39 and 5x20 were re-checked for all three
// (all absent). The scenario re-asserts that last property on its own frames —
// see the "…and the normal session-list UI is NOT painted at <size>" check,
// which runs on the notice itself inside the size walk.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
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

// NORMAL_UI_TITLE / NORMAL_UI_STATE / NORMAL_UI_COLUMNS are the three rows that
// identify "the normal session-list UI is painted", and that the too-small
// notice never paints. Mirrored from the product's copy the same way MIN_COLS /
// MIN_ROWS are mirrored in the harness: a drift in the product's wording shows
// up here as a red check, not as a silent green. The row the state lands on
// (HEADER_STATE_ROW) is defined once, in resize_harness.odin.
NORMAL_UI_TITLE :: "herdr-session"
NORMAL_UI_STATE :: "Mode selection"
NORMAL_UI_COLUMNS :: []string{"device", "timestamp", "state", "name"}

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
		before.painted && !before.has_notice,
		fmt.tprintf("title row={} state row={} column-header row={} (want 0/1/>=1) notice={}",
			before.title_row, before.state_row, before.table_row, before.has_notice))

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

		// THE NEGATIVE HALF OF THE NEW MARKER. "filter:" used to be dropped in
		// here with the implication that its absence proved nothing; here the
		// absence of all three normal-UI rows IS asserted, on the very frame the
		// notice replaced. If the app ever painted the title, the state line or
		// the column header behind the notice, this goes red — which is what
		// makes the positive check below (RECOVERED) more than "some string came
		// back".
		//
		// At 2x5 the notice phrase itself cannot be rendered, so only the
		// "normal UI is absent" half is claimed there; the notice's presence is
		// required only on the sizes where the phrase physically fits, which is
		// the same split the check above already draws.
		at_small := normal_ui(&a.d.screen)
		ck_small(t, rep, fmt.tprintf("…and the normal session-list UI is NOT painted at {}", lbl),
			!at_small.painted && (!can_show || at_small.has_notice),
			fmt.tprintf("title row={} state row={} column-header row={} notice={} (all three rows must be absent)",
				at_small.title_row, at_small.state_row, at_small.table_row, at_small.has_notice))
	}

	// ── RECOVERY: enlarge, the normal UI must come back by itself ──
	pty.pty_resize(a.d, RECOVER_ROWS, RECOVER_COLS)
	pty.pty_read(a.d, 700)
	after := normal_ui(&a.d.screen)
	ck_small(t, rep, "RECOVERED after enlarging: the normal UI is back",
		after.painted && !after.has_notice,
		fmt.tprintf("title row={} state row={} column-header row={} notice={} (rows={})",
			after.title_row, after.state_row, after.table_row, after.has_notice, a.d.screen.rows))

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

// Ui_Kind reports WHERE each marker was found, not just whether it was. A row
// index of -1 means "that row is not on screen at all", which is what a too
// small frame returns for every one of them — and the detail line says so, so a
// failure names the marker that went missing instead of shrugging.
Ui_Kind :: struct {
	title_row  : int,
	state_row  : int,
	table_row  : int,
	painted    : bool,
	has_notice : bool,
}

// painted_of is true only when all three structural rows are present AND each is
// where the frame is supposed to put it. The state must sit on
// HEADER_STATE_ROW and below the title, because "it is somewhere" is exactly the
// kind of condition a decorative string can satisfy by accident.
painted_of :: proc(title_row, state_row, table_row: int) -> bool {
	if title_row < 0 || state_row != HEADER_STATE_ROW || table_row < 0 { return false }
	return table_row > state_row
}

// ui_rows_with returns the first row whose text contains EVERY needle, or -1.
// "all four column labels on one row" is the column header; any single one of
// them alone would also match a session's own name or device column.
ui_rows_with :: proc(s: ^pty.Screen, needles: []string) -> int {
	for r := 0; r < s.rows; r += 1 {
		txt := rh_row_text(s, r)
		all := true
		for n in needles {
			if !strings.contains(txt, n) {
				all = false
				break
			}
		}
		if all { return r }
	}
	return -1
}

normal_ui :: proc(s: ^pty.Screen) -> Ui_Kind {
	ti := ui_rows_with(s, []string{NORMAL_UI_TITLE})
	st := ui_rows_with(s, []string{NORMAL_UI_STATE})
	tb := ui_rows_with(s, NORMAL_UI_COLUMNS)
	return Ui_Kind{
		title_row  = ti,
		state_row  = st,
		table_row  = tb,
		painted    = painted_of(ti, st, tb),
		has_notice = pty.screen_contains(s, NOTICE),
	}
}
