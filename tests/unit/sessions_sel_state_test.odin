package unit

// ============================================================================
// sessions_sel_state_test.odin — UIP-3 / RCH-10 change 5: the selection
// highlight must NOT flatten the running/stopped state colour.
//
// WHAT WAS WRONG
//
// `sess_paint_row` used to read `state_fg := fg; if !is_sel { running/stopped }`.
// While a row was selected the state word took the ROW's colour (pal.sel_fg)
// instead of its own, so a selected RUNNING row and a selected STOPPED row
// painted the word with ONE colour. The selection collapsed the only thing that
// column exists to say. The fix gives the selected row its own PAIR —
// `run_hl` / `stop_hl` — per-cell.
//
// WHY BOTH run-vs-stop AND state-vs-sel_fg ARE ASSERTED (AND WHY THE OLD
// COMMENT SAYING OTHERWISE WAS WRONG)
//
// An earlier version of this header argued that comparing the state cell against
// the row colour "is WRONG and would fail on a correct palette — several
// shipped themes deliberately set run_hl to the same value as sel_fg (the
// loudest thing on a bright bar)". THAT CLAIM DESCRIBES THE BUG, NOT THE
// DESIGN, and it is now deleted on purpose. Six of ten themes did set run_hl ==
// sel_fg, and the user's complaint about exactly that is what this change
// exists to fix: a selected row whose state word is the bar's own text colour
// is a selected row whose state has been deleted, however nicely the role is
// named. `run_hl == sel_fg` is not a legitimate styling choice any more.
//
// So both comparisons are made, and they are not redundant:
//
//   * run-vs-stop says a selected RUNNING row does not look like a selected
//     STOPPED row (RCH-10 change 5);
//   * state-vs-device-cell (which is painted sel_fg) says the state word does
//     not look like the rest of the highlighted text — the user's rule, seen
//     in the back buffer rather than in the palette.
//
// A palette could satisfy the first and fail the second (that is exactly the
// state the shipped table was in), which is why neither is dropped.
//
// WHY PER-CELL, AND WHY TWO PAINTS
//
// The pty rune emulator is blind to colour (tests/pty/screen.odin). The real
// evidence surface is termbox's BACK buffer via `render_cell_at` → tb_get_cell
// (back = 1) — what the renderer DECIDED, not what was asked for (ACK-2).
// Only one row can be selected at a time, so the selected-running cell and the
// selected-stopped cell come from two separate frames of the SAME two rows.
// That is exactly how the view works in production.
//
// HOW EACH ASSERTION COULD FAIL (D-E)
//
//   * same state column / adjacent rows — fails if the two cells being compared
//     are not in one column, which would make the colour comparison meaningless.
//   * the cell IS the state word (glyph 'r'/'s') — fails if the position was
//     derived wrong and we are colour-checking an empty cell that happens to be
//     two distinct colours.
//   * unselected pair == running / stopped — fails if the fix overreached and
//     painted the highlight colour everywhere, which would pass the headline
//     check while destroying the unselected encoding.
//   * selected running == run_hl, selected stopped == stop_hl — fails if the
//     view reads the wrong role, or the roles are swapped, or the old `fg`
//     fallback is still in the path.
//   * selected_run != selected_stop — THE requirement. Fails, and only this,
//     if the flatten guard survives (both would read sel_fg) or if a future
//     palette gives both roles one value.
//   * selected cells sit ON the accent bar — fails if the selection rectangle
//     is not where the state cell is, because then "under selection" was never
//     actually being tested.
//   * selection still paints the row (device cell == sel_fg) — fails if the
//     fix broke the highlight itself while changing the state cell.
//   * every theme swept — a zero-length sweep asserts nothing, so the count is
//     checked against app.theme_count() before any verdict.
//
// Demonstrated falsifiable by building the same suite against (a) the old
// flattening condition and (b) a palette with the two highlight roles folded
// into one value; both turn these checks red. See the worker report for UIP-3.
//
// NO BLENDING IS AVAILABLE HERE. Overlay blending has been a deliberate no-op
// since Phase 2 (src/ui/sessions.odin header), so a tint-based approach paints
// nothing at all. Per-cell foreground is the only working model (D-Q).
// ============================================================================

import "core:fmt"
import "core:testing"

import clay "../../clay-odin"
import render "../../src/render"
import ui "../../src/ui"
import app "../../src/app"
import tb "../../vendor/termbox2-odin"
import support "../support"

// The table is painted into a bare root element sized to the harness terminal.
// The filter line is switched OFF so the state column's row geometry is one
// header row down from a known origin — this test is about the state CELL, and
// the filter is exercised by its own suite.
SEL_BODY_ROWS :: RENDER_ROWS - 1

// ── fixture ────────────────────────────────────────────────────────────────

// Two rows, distinct names, opposite states, ONE running and ONE stopped so
// each state word appears exactly once per frame and can be located by Clay's
// own reported geometry rather than by hand-computed offsets.
sel_fixture_rows :: proc() -> []app.Session {
	rows : [dynamic]app.Session
	append(&rows, app.Session{
		device  = "local",
		label   = "local",
		name    = "alpha-2026-10-18-10-00-00-000",
		running = true,
		ts      = app.ts_unknown(),
	})
	append(&rows, app.Session{
		device  = "local",
		label   = "local",
		name    = "beta-2026-10-18-11-00-00-000",
		running = false,
		ts      = app.ts_unknown(),
	})
	return rows[:]
}

// Sel_Frame is one painted frame: the command stream, the boxes Clay reported
// for each state word, and the back-buffer cells read at those boxes.
Sel_Frame :: struct {
	stats     : render.Stats,
	run_rect  : render.Rect,
	stop_rect : render.Rect,
	run       : Render_Back_Cell,
	stop      : Render_Back_Cell,
	run_dev   : Render_Back_Cell, // device cell of the RUNNING row
	stop_dev  : Render_Back_Cell, // device cell of the STOPPED row
	found     : bool,             // both state words were located
}

// sel_paint_frame paints the fixture with `sel_idx` selected (-1 = nothing) and
// reads the interesting cells back out of the BACK buffer.
sel_paint_frame :: proc(rows: []app.Session, sel_idx: int, pal: ^ui.Palette) -> Sel_Frame {
	v: ui.Sessions
	ui.sessions_init(&v)
	v.show_filter = false
	if sel_idx >= 0 && sel_idx < len(rows) {
		v.sel = app.selection_of(&rows[sel_idx])
	}

	tb.tb_clear()
	clay.BeginLayout()
	if clay.UI(clay.ID("hs.uip3.selstate.root"))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingFixed(f32(RENDER_COLS)),
				height = clay.SizingFixed(f32(RENDER_ROWS)),
			},
			layoutDirection = clay.LayoutDirection.TopToBottom,
		},
		backgroundColor = pal.bg,
	}) {
		ui.sessions_paint(&v, rows, RENDER_COLS, SEL_BODY_ROWS, pal)
	}
	cmds := clay.EndLayout(0)
	f := Sel_Frame{stats = render_paint_cmds(cmds)}

	// Positions come from CLAY's own reported bounding boxes for the state
	// words, and the device column from its own header text — not from
	// arithmetic this test invented (D-F).
	i_run, run_rect := render_find_text_loc(cmds, "running")
	i_stop, stop_rect := render_find_text_loc(cmds, "stopped")
	i_dev, dev_rect := render_find_text_loc(cmds, "device")
	f.found = i_run >= 0 && i_stop >= 0 && i_dev >= 0
	f.run_rect = run_rect
	f.stop_rect = stop_rect
	if f.found {
		f.run = render_cell_at(run_rect.x, run_rect.y)
		f.stop = render_cell_at(stop_rect.x, stop_rect.y)
		f.run_dev = render_cell_at(dev_rect.x, run_rect.y)
		f.stop_dev = render_cell_at(dev_rect.x, stop_rect.y)
	}
	return f
}

sel_attr :: proc(c: clay.Color) -> tb.Attr {
	return render.attr_painted(c)
}

// ── THE OTHER REQUIREMENT: on the bar, the state word is not bar text ─────

@(test)
sel_state_highlight_is_not_the_bar_text_in_the_back_buffer :: proc(t: ^testing.T) {
	// The user's complaint came from a screenshot, not from a palette table:
	// `running` on a selected row looked like every other character on the
	// highlight bar. `sel_state_no_theme_flattens_running_into_stopped` proves
	// the two STATE words differ; it would still pass if BOTH of them equalled
	// sel_fg. This test closes that gap where it was observed — in the cells the
	// renderer actually decided, comparing the state cell against a NEIGHBOURING
	// cell of the same selected row (the device column), which is painted
	// sel_fg and is the "other highlighted text" the user meant.
	//
	// Swept over every shipped theme, because one theme slipping through is
	// exactly what happened before.
	if !render_session(t, "sel-state-vs-bar-text") { return }

	rows := sel_fixture_rows()
	defer delete(rows)

	n := app.theme_count()
	support.check(t, "the sweep covers every shipped theme", n > 0,
		fmt.tprintf("app.theme_count() = {}", n))

	same_as_bar := 0
	not_the_role := 0
	too_close := 0
	detail := ""
	for i := 0; i < n; i += 1 {
		th := app.theme_at(i)
		pal := ui.palette_of(th)
		sel_attr_hex := clay_hex(pal.sel_fg)

		f_run := sel_paint_frame(rows, 0, &pal)
		f_stop := sel_paint_frame(rows, 1, &pal)
		if !f_run.found || !f_stop.found {
			same_as_bar += 1
			detail = fmt.tprintf("{} {}; state word not locatable — cannot prove anything", detail, th.name)
			continue
		}

		// (1) the state cell's ink differs from the same row's other cells
		if f_run.run.fg == f_run.run_dev.fg {
			same_as_bar += 1
			detail = fmt.tprintf("{} {}; selected RUNNING's state cell fg == the device cell fg (0x{:08X}) — the state word IS bar text",
				detail, th.name, u32(f_run.run.fg))
		}
		if f_stop.stop.fg == f_stop.stop_dev.fg {
			same_as_bar += 1
			detail = fmt.tprintf("{} {}; selected STOPPED's state cell fg == the device cell fg (0x{:08X})", detail, th.name, u32(f_stop.stop.fg))
		}

		// (2) the device cell really IS sel_fg, so (1) is a comparison against
		// the bar text and not against some third colour that happens to differ
		sel := sel_attr(pal.sel_fg)
		if f_run.run_dev.fg != sel {
			not_the_role += 1
			detail = fmt.tprintf("{} {}; device cell fg=0x{:08X} but sel_fg=0x{:08X} — the control against which (1) was judged is not sel_fg",
				detail, th.name, u32(f_run.run_dev.fg), u32(sel))
		}

		// (3) not merely different, but far enough apart to see: the derived
		// role is underwritten by >= 1.6 against sel_fg, checked on the value
		// that was actually painted.
		run_hl := clay_hex(pal.run_hl)
		stop_hl := clay_hex(pal.stop_hl)
		if app.theme_contrast(run_hl, sel_attr_hex) < app.THEME_HL_FLOOR_TEXT ||
		   app.theme_contrast(stop_hl, sel_attr_hex) < app.THEME_HL_FLOOR_TEXT {
			too_close += 1
			detail = fmt.tprintf("{} {}; run vs sel_fg={:.3f} stop vs sel_fg={:.3f} (floor {:.2f})",
				detail, th.name,
				app.theme_contrast(run_hl, sel_attr_hex),
				app.theme_contrast(stop_hl, sel_attr_hex),
				app.THEME_HL_FLOOR_TEXT)
		}

		// (4) and the cell IS the derived role, so (1) is a statement about
		// the derivation and not about an unrelated colour in the cell
		if f_run.run.fg != sel_attr(pal.run_hl) || f_stop.stop.fg != sel_attr(pal.stop_hl) {
			not_the_role += 1
			detail = fmt.tprintf("{} {}; state cell fg=0x{:08X}/0x{:08X} but derived roles are 0x{:08X}/0x{:08X}",
				detail, th.name, u32(f_run.run.fg), u32(f_stop.stop.fg),
				u32(sel_attr(pal.run_hl)), u32(sel_attr(pal.stop_hl)))
		}
	}

	support.check(t, "on a SELECTED row the state cell's fg != the device cell's fg (sel_fg) — every theme",
		same_as_bar == 0, fmt.tprintf("{} violation(s){}", same_as_bar, detail))
	support.check(t, "…and the comparison was made against sel_fg / the derived role itself",
		not_the_role == 0, fmt.tprintf("{} control failure(s){}", not_the_role, detail))
	support.check(t, "…with the derived role at least 1.6:1 off sel_fg, not one quantum off",
		too_close == 0, fmt.tprintf("{} too-close theme(s){}", too_close, detail))
}

// ── THE requirement ────────────────────────────────────────────────────────

@(test)
sel_state_selection_does_not_flatten_running_into_stopped :: proc(t: ^testing.T) {
	support.note(t, "UIP-3 change 5 — selected running vs selected stopped, per cell, back buffer")
	if !render_session(t, "sel-state") { return }

	th, kind := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)
	rows := sel_fixture_rows()
	defer delete(rows)

	// Three frames of the SAME two rows: nothing selected (baseline), the
	// RUNNING row selected, the STOPPED row selected.
	f_none := sel_paint_frame(rows, -1, &pal)
	f_run := sel_paint_frame(rows, 0, &pal)
	f_stop := sel_paint_frame(rows, 1, &pal)

	if !f_none.found || !f_run.found || !f_stop.found {
		support.check(t, "both state words were located in every frame", false,
			fmt.tprintf("found: baseline={} run={} stop={} (a frame that cannot locate the cells cannot test anything)",
				f_none.found, f_run.found, f_stop.found))
		return
	}

	// GROUNDING 1 — the two cells compared are one column on adjacent rows. If
	// this fails, the colour comparison below is comparing unrelated cells.
	support.check(t, "the two state words occupy the SAME state column",
		f_none.run_rect.x == f_none.stop_rect.x,
		fmt.tprintf("run x={} stop x={} (state col must be shared)", f_none.run_rect.x, f_none.stop_rect.x))
	support.check(t, "…and on adjacent rows, so nothing else can be in the way",
		f_none.stop_rect.y == f_none.run_rect.y+1,
		fmt.tprintf("run y={} stop y={}", f_none.run_rect.y, f_none.stop_rect.y))

	// GROUNDING 2 — the cell read IS the state word, not an adjacent blank.
	support.check(t, "the cell under test really is the state word",
		rune(f_none.run.ch) == 'r' && rune(f_none.stop.ch) == 's',
		fmt.tprintf("run={} stop={}", render_glyph_name(rune(f_none.run.ch)), render_glyph_name(rune(f_none.stop.ch))))

	// GROUNDING 3 — the selection rectangle actually covers the state cell, so
	// "under selection" is a fact and not an assumption.
	accent := sel_attr(pal.accent)
	support.check(t, "the state cell is drawn ON the accent bar in both selected frames",
		f_run.run.bg == accent && f_stop.stop.bg == accent,
		fmt.tprintf("run bg=0x{:08X} stop bg=0x{:08X} want accent=0x{:08X}",
			u32(f_run.run.bg), u32(f_stop.stop.bg), u32(accent)))

	// ── THE assertion: selected-running ≠ selected-stopped ────────────────
	// This is the check that change 5 lives or dies on. Under the old
	// `if !is_sel` condition BOTH of these read pal.sel_fg and this goes red.
	// It cannot pass by accident: it is the same column, same row height, same
	// bar, and the only thing that can make it pass is two different
	// foregrounds on the state word while selected.
	support.check(t, "selection does NOT flatten running into stopped (the requirement)",
		f_run.run.fg != f_stop.stop.fg,
		fmt.tprintf("sel_run.fg=0x{:08X} sel_stop.fg=0x{:08X} — identical means FLATTENED",
			u32(f_run.run.fg), u32(f_stop.stop.fg)))

	// AND the two are the SPECIFIC palette roles, not just "different".
	// "Some colour changed" is not the requirement; `run_hl` / `stop_hl` are.
	support.check(t, "…selected running is exactly run_hl",
		f_run.run.fg == sel_attr(pal.run_hl),
		fmt.tprintf("got=0x{:08X} want run_hl=0x{:08X}", u32(f_run.run.fg), u32(sel_attr(pal.run_hl))))
	support.check(t, "…and selected stopped is exactly stop_hl",
		f_stop.stop.fg == sel_attr(pal.stop_hl),
		fmt.tprintf("got=0x{:08X} want stop_hl=0x{:08X}", u32(f_stop.stop.fg), u32(sel_attr(pal.stop_hl))))

	// THE OTHER HALF — unselected rows keep the UNSELECTED roles. Without this
	// a "make the state column always the highlight colour" change would pass
	// every check above while silently deleting the unselected encoding.
	support.check(t, "unselected running is still pal.running (baseline frame)",
		f_none.run.fg == sel_attr(pal.running),
		fmt.tprintf("got=0x{:08X} want running=0x{:08X}", u32(f_none.run.fg), u32(sel_attr(pal.running))))
	support.check(t, "unselected stopped is still pal.stopped (baseline frame)",
		f_none.stop.fg == sel_attr(pal.stopped),
		fmt.tprintf("got=0x{:08X} want stopped=0x{:08X}", u32(f_none.stop.fg), u32(sel_attr(pal.stopped))))

	// …and the unselected row of a SELECTED frame keeps its own role too: the
	// highlight must not leak across rows, and the fix must not become
	// "the state column is always highlighted".
	support.check(t, "selecting the running row leaves the stopped row on pal.stopped",
		f_run.stop.fg == sel_attr(pal.stopped),
		fmt.tprintf("got=0x{:08X} want stopped=0x{:08X}", u32(f_run.stop.fg), u32(sel_attr(pal.stopped))))
	support.check(t, "…and selecting the stopped row leaves the running row on pal.running",
		f_stop.run.fg == sel_attr(pal.running),
		fmt.tprintf("got=0x{:08X} want running=0x{:08X}", u32(f_stop.run.fg), u32(sel_attr(pal.running))))

	// The highlight itself is intact: every other cell of the selected row is
	// still sel_fg. Fails if changing the state cell broke the bar.
	sel_fg := sel_attr(pal.sel_fg)
	support.check(t, "the selected row's OTHER cells are still sel_fg (bar not broken)",
		f_run.run_dev.fg == sel_fg && f_stop.stop_dev.fg == sel_fg,
		fmt.tprintf("run row dev fg=0x{:08X} stop row dev fg=0x{:08X} want sel_fg=0x{:08X}",
			u32(f_run.run_dev.fg), u32(f_stop.stop_dev.fg), u32(sel_fg)))
	support.check(t, "…and the unselected row's device cell is plain fg",
		f_none.run_dev.fg == sel_attr(pal.fg) && f_none.stop_dev.fg == sel_attr(pal.fg),
		fmt.tprintf("run dev=0x{:08X} stop dev=0x{:08X} want fg=0x{:08X}",
			u32(f_none.run_dev.fg), u32(f_none.stop_dev.fg), u32(sel_attr(pal.fg))))

	support.note(t, fmt.tprintf("  theme={} kind={} stats(cmds={} glyphs={})",
		th.name, kind, f_run.stats.commands, f_run.stats.glyphs))

	render_dump_rows(t, "sel-state: running selected (state col highlighted)",
		f_none.run_rect.x - 2, f_none.run_rect.y - 1, 24, 4)
}

// ── the same property, for every shipped theme ─────────────────────────────

@(test)
sel_state_no_theme_flattens_running_into_stopped :: proc(t: ^testing.T) {
	if !render_session(t, "sel-state-sweep") { return }

	rows := sel_fixture_rows()
	defer delete(rows)

	// A sweep over zero themes cannot falsify anything, so the sweep size is
	// asserted BEFORE any per-theme verdict is trusted.
	n := app.theme_count()
	support.check(t, "the sweep actually covers every shipped theme", n > 0,
		fmt.tprintf("app.theme_count() = {}", n))

	flattened := 0
	wrong_role := 0
	detail := ""
	for i := 0; i < n; i += 1 {
		th := app.theme_at(i)
		pal := ui.palette_of(th)
		f_run := sel_paint_frame(rows, 0, &pal)
		f_stop := sel_paint_frame(rows, 1, &pal)
		if !f_run.found || !f_stop.found {
			flattened += 1
			detail = fmt.tprintf("{} {}; a state word could not be located — cannot prove anything",
				detail, th.name)
			continue
		}
		if f_run.run.fg == f_stop.stop.fg {
			flattened += 1
			detail = fmt.tprintf("{} {}; FLATTENED sel_run=0x{:08X} == sel_stop=0x{:08X}",
				detail, th.name, u32(f_run.run.fg), u32(f_stop.stop.fg))
			continue
		}
		if f_run.run.fg != sel_attr(pal.run_hl) || f_stop.stop.fg != sel_attr(pal.stop_hl) {
			wrong_role += 1
			detail = fmt.tprintf("{} {}; WRONG ROLE sel_run=0x{:08X} want 0x{:08X} sel_stop=0x{:08X} want 0x{:08X}",
				detail, th.name, u32(f_run.run.fg), u32(sel_attr(pal.run_hl)),
				u32(f_stop.stop.fg), u32(sel_attr(pal.stop_hl)))
		}
	}

	support.check(t, "no theme renders a selected RUNNING row like a selected STOPPED row",
		flattened == 0, fmt.tprintf("{} flattened/unprovable theme(s){}", flattened, detail))
	support.check(t, "and every theme draws the pair from run_hl / stop_hl specifically",
		wrong_role == 0, fmt.tprintf("{} wrong-role theme(s){}", wrong_role, detail))
}
