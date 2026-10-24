package unit

// ============================================================================
// caret_cell_test.odin — UIP-4 / RCH-10 change 3: what the caret LOOKS LIKE in
// the cell buffer, read back out of termbox's BACK buffer rather than asserted
// from what was asked for (ACK-2).
//
// THE FOUR WAYS THIS COULD BE VACUOUS, AND WHAT CLOSES EACH ONE
//
//   * "the caret was painted somewhere" — no: every assertion is pinned to the
//     cell CLAY reported for the caret element (edit_caret_cell) AND to the
//     display width of the text before it. A caret painted in the wrong column
//     fails on both halves, and those two agreeing is not automatic — one comes
//     from the layout engine, the other from the buffer's own widths.
//   * "the caret has a colour" — no: the requirement is a PAIR. The glyph must
//     be caret_fg AND the cell behind it caret_bg. Checking fg alone would let a
//     block painted over the row background pass, so both are asserted against
//     the palette's own two roles.
//   * "the block glyph is a block" — asserted by codepoint: U+2588, with the
//     old thin bar U+258F named as the thing it replaced.
//   * a single theme proving it — the pair is swept across every shipped theme
//     (app.theme_count() asserted first, so a zero-length sweep cannot pass).
//
// WHY THE CELL IS READ FROM THE BACK BUFFER
//
// tests/pty/screen.odin's rune emulator is colour-blind, and after a full
// stream termbox's own shutdown escapes reset the emulator's cursor to 0,0 —
// so the pty cannot be the colour surface. `render_cell_at` (tb_get_cell with
// back = 1) reads exactly what the renderer decided to paint, which is the
// same surface sessions_sel_state_test.odin uses for the selection highlight.
//
// NOT TESTED HERE (eyeball-only, recorded as a limitation in the UIP-4 report):
// that the cursor actually BLINKS (that is the terminal's DECSCUSR-driven
// behaviour and the pty emulator parses-and-ignores it), that the block READS
// as "fat", and perceived contrast. None of those are observable through the
// back buffer, so none are asserted here.
// ============================================================================

import "core:fmt"
import "core:testing"
import "core:unicode/utf8"

import clay "../../clay-odin"
import render "../../src/render"
import ui "../../src/ui"
import app "../../src/app"
import tb "../../vendor/termbox2-odin"
import support "../support"

// The probe string: ASCII (1 cell), CJK (2 cells / 3 bytes) and an astral
// emoji (2 cells / 4 bytes) — every width class a caret has to survive.
CC_PROBE :: "a世b😀c"

// caret_paint_row paints one editor into a bare root column sized to the
// harness terminal, exactly once, and presents it. The root is at (0,0) with no
// padding, so the caret's reported column IS its display column — no frame
// arithmetic can hide a drift in either number.
caret_paint_row :: proc(e: ^ui.Edit, width: i32, pal: ^ui.Palette) {
	tb.tb_clear()
	clay.BeginLayout()
	if clay.UI(clay.ID("hs.uip4.caret.root"))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingFixed(f32(RENDER_COLS)),
				height = clay.SizingFixed(f32(RENDER_ROWS)),
			},
			layoutDirection = clay.LayoutDirection.TopToBottom,
		},
		backgroundColor = pal.bg,
	}) {
		ui.edit_paint(e, "hs.uip4.caret.edit", width, pal)
	}
	cmds := clay.EndLayout(0)
	render_paint_cmds(cmds)
}

// caret_paint_pair paints TWO editors side by side in one row, both grown to
// fill, so a single shared caret id would be caught by the two cells colliding.
caret_paint_pair :: proc(a, b: ^ui.Edit, pal: ^ui.Palette) {
	tb.tb_clear()
	clay.BeginLayout()
	if clay.UI(clay.ID("hs.uip4.caret.pair.root"))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingFixed(f32(RENDER_COLS)),
				height = clay.SizingFixed(f32(RENDER_ROWS)),
			},
			layoutDirection = clay.LayoutDirection.LeftToRight,
		},
		backgroundColor = pal.bg,
	}) {
		ui.edit_paint(a, "hs.uip4.caret.e1", 40, pal)
		ui.edit_paint(b, "hs.uip4.caret.e2", 40, pal)
	}
	cmds := clay.EndLayout(0)
	render_paint_cmds(cmds)
}

caret_attr :: proc(c: clay.Color) -> tb.Attr {
	return render.attr_painted(c)
}

// last_rune returns the final rune of a UTF-8 string.
cc_last_rune :: proc(s: string) -> rune {
	if len(s) == 0 { return 0 }
	r, _ := utf8.decode_last_rune_in_string(s)
	return r
}

// ── the block, the pair and the derived column ─────────────────────────────

@(test)
caret_cell_block_pair_at_derived_column :: proc(t: ^testing.T) {
	if !render_session(t, "caret-cell") { return }
	th, _ := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)

	// Each prefix puts the caret at a different column through a different mix
	// of widths, so one fixture cannot be the only thing these numbers agree with.
	prefixes := []string{"a", "a世", "a世b", "a世b😀"}
	fg_want := caret_attr(pal.caret_fg)
	bg_want := caret_attr(pal.caret_bg)

	for p in prefixes {
		e: ui.Edit
		ui.edit_init(&e)
		ui.edit_paste(&e, p)
		caret_paint_row(&e, RENDER_COLS-2, &pal)

		x, y, ok := ui.edit_caret_cell(&e)
		want_x := render_cols(p)
		support.check(t, fmt.tprintf("'{}': the caret reported a cell at all", p), ok,
			fmt.tprintf("ok={}", ok))
		if !ok { continue }

		// REQUIREMENT 3 — the caret's column is the DISPLAY WIDTH of the
		// prefix, never its byte length.
		support.check(t, fmt.tprintf("'{}': caret column == display width of the prefix", p),
			x == want_x,
			fmt.tprintf("x={} display={} bytes={}", x, want_x, len(p)))
		// …and the byte/display gap is real for the wide-rune cases, so the
		// check above is not trivially true of an ASCII-only fixture.
		if len(p) != int(want_x) {
			support.check(t, fmt.tprintf("'{}': a byte caret would have drifted (bytes={} cells={})", p, len(p), want_x),
				len(p) > int(want_x), fmt.tprintf("bytes={} cells={}", len(p), want_x))
		}
		support.check(t, fmt.tprintf("'{}': the caret sits on row 0 of a bare root", p), y == 0,
			fmt.tprintf("y={}", y))

		c := render_cell_at(x, y)
		// REQUIREMENT 1 — the block, not the thin bar.
		support.check(t, fmt.tprintf("'{}': the caret cell is the fat block U+2588", p),
			rune(c.ch) == '█' && rune(c.ch) != '▏',
			fmt.tprintf("cell={}", render_glyph_name(rune(c.ch))))
		// REQUIREMENT 2 — BOTH halves of the pair, not either one.
		support.check(t, fmt.tprintf("'{}': caret cell fg == caret_fg", p),
			c.fg == fg_want, fmt.tprintf("got=0x{:08X} want caret_fg=0x{:08X}", u32(c.fg), u32(fg_want)))
		support.check(t, fmt.tprintf("'{}': caret cell bg == caret_bg", p),
			c.bg == bg_want, fmt.tprintf("got=0x{:08X} want caret_bg=0x{:08X}", u32(c.bg), u32(bg_want)))

		// The glyph immediately before the caret is the last rune typed — which
		// is what makes the caret's position "after the text" rather than
		// "somewhere over there".
		lr := cc_last_rune(p)
		w := render.glyph_columns(lr)
		support.check(t, fmt.tprintf("'{}': the rune immediately before the caret is '{}'", p, lr),
			render_glyph_at(x-w, y) == lr,
			fmt.tprintf("at x-{} = {}", w, render_glyph_name(render_glyph_at(x-w, y))))
	}

	render_dump_rows(t, "caret cell (block at the derived column)", 0, 0, 24, 2)
}

// ── the caret parked BETWEEN two painted glyphs ────────────────────────────

@(test)
caret_cell_between_glyphs_not_after_them :: proc(t: ^testing.T) {
	if !render_session(t, "caret-cell-mid") { return }
	th, _ := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)

	e: ui.Edit
	ui.edit_init(&e)
	ui.edit_paste(&e, CC_PROBE)
	ui.edit_left(&e) // park the caret before the trailing 'c'
	caret_paint_row(&e, RENDER_COLS-2, &pal)

	x, y, ok := ui.edit_caret_cell(&e)
	if !ok {
		support.check(t, "the parked caret reported a cell", false, "ok=false")
		return
	}
	want := render_cols("a世b😀")
	support.check(t, "the parked caret sits at the display width of everything before it",
		x == want && y == 0, fmt.tprintf("cell=({},{}) want x={}", x, y, want))

	c := render_cell_at(x, y)
	support.check(t, "the parked cell is the caret pair (fg+bg), not the text pair",
		rune(c.ch) == '█' && c.fg == caret_attr(pal.caret_fg) && c.bg == caret_attr(pal.caret_bg),
		fmt.tprintf("glyph={} fg=0x{:08X} bg=0x{:08X}", render_glyph_name(rune(c.ch)), u32(c.fg), u32(c.bg)))

	// THE HALF THAT ONLY EXISTS WHEN THE CARET IS MID-FIELD: the text after the
	// caret is still painted, immediately to the right. An editor that appended
	// the caret instead of inserting it would fail here and pass every
	// end-of-line test.
	support.check(t, "the suffix is painted immediately RIGHT of the caret",
		render_glyph_at(x+1, y) == 'c',
		fmt.tprintf("right of caret = {}", render_glyph_name(render_glyph_at(x+1, y))))
	// …and the rune immediately BEFORE the caret is the emoji, which occupies
	// TWO cells: its first cell sits at x-2 and the pad cell at x-1. Expecting
	// 'b' at x-1 would be wrong for a 2-cell rune, so the width comes from the
	// rune itself.
	before := cc_last_rune("a世b😀") // the caret is parked one rune from the end
	w := render.glyph_columns(before)
	support.check(t, fmt.tprintf("the rune before the caret is '{}' ({} cells wide, first cell at x-{})", before, w, w),
		render_glyph_at(x-w, y) == before,
		fmt.tprintf("at x-{} = {}", w, render_glyph_name(render_glyph_at(x-w, y))))
	render_dump_rows(t, "caret parked mid-field (a世b[█]c)", 0, 0, 12, 1)
}

// ── two editors, two carets, no collision ─────────────────────────────────

@(test)
caret_cell_two_editors_do_not_share_a_caret_cell :: proc(t: ^testing.T) {
	if !render_session(t, "caret-cell-pair") { return }
	th, _ := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)

	a, b: ui.Edit
	ui.edit_init(&a)
	ui.edit_init(&b)
	ui.edit_paste(&a, "ab")
	ui.edit_paste(&b, "cd")
	caret_paint_pair(&a, &b, &pal)

	ax, ay, aok := ui.edit_caret_cell(&a)
	bx, by, bok := ui.edit_caret_cell(&b)
	if !aok || !bok {
		support.check(t, "both editors reported a caret cell", false,
			fmt.tprintf("e1 ok={} e2 ok={}", aok, bok))
		return
	}
	support.note(t, fmt.tprintf("  two carets in one frame: e1=({},{}) e2=({},{})", ax, ay, bx, by))
	// Each caret is at ITS OWN derived column: 2 for "ab", and for the second
	// editor its own container's origin + 2 — definitely not the same cell.
	support.check(t, "editor 1's caret is at its own derived column", ax == render_cols("ab"),
		fmt.tprintf("x={} want 2", ax))
	support.check(t, "editor 2's caret is NOT in editor 1's cell (ids are parented, not shared)",
		bx != ax || by != ay,
		fmt.tprintf("e1=({},{}) e2=({},{})", ax, ay, bx, by))
	support.check(t, "editor 2's caret is further right than editor 1's, in the same row",
		bx > ax && by == ay, fmt.tprintf("e1=({},{}) e2=({},{})", ax, ay, bx, by))
	support.check(t, "and BOTH cells are the caret block with the caret pair",
		rune(render_cell_at(ax, ay).ch) == '█' && rune(render_cell_at(bx, by).ch) == '█' &&
			render_cell_at(bx, by).fg == caret_attr(pal.caret_fg) &&
			render_cell_at(bx, by).bg == caret_attr(pal.caret_bg),
		fmt.tprintf("e1={} e2={}", render_glyph_name(rune(render_cell_at(ax, ay).ch)),
			render_glyph_name(rune(render_cell_at(bx, by).ch))))
	render_dump_rows(t, "two editors, two carets", 0, 0, RENDER_COLS-2, 1)
}

// ── never painted == no cell, not a stale one ─────────────────────────────

@(test)
caret_cell_unpainted_editor_has_no_cell :: proc(t: ^testing.T) {
	// The anti-staleness half: the driver HIDES the terminal cursor when this
	// returns false. If an editor could report a cell it never painted, the
	// cursor would sit on some older frame's caret after a state change.
	e: ui.Edit
	ui.edit_init(&e)
	x, y, ok := ui.edit_caret_cell(&e)
	support.check(t, "an editor that never painted reports NO caret cell",
		!ok && x == 0 && y == 0, fmt.tprintf("ok={} cell=({},{})", ok, x, y))

	// And once painted, it does — so the check above is not just "always false".
	if !render_session(t, "caret-cell-fresh") { return }
	th, _ := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)
	ui.edit_paste(&e, "x")
	caret_paint_row(&e, 20, &pal)
	x2, y2, ok2 := ui.edit_caret_cell(&e)
	support.check(t, "…and after a real paint it reports one", ok2 && x2 == 1 && y2 == 0,
		fmt.tprintf("ok={} cell=({},{})", ok2, x2, y2))
}

// ── every shipped theme paints the pair ───────────────────────────────────

@(test)
caret_cell_every_theme_paints_the_pair :: proc(t: ^testing.T) {
	if !render_session(t, "caret-cell-sweep") { return }
	n := app.theme_count()
	support.check(t, "the sweep covers every shipped theme", n > 0,
		fmt.tprintf("app.theme_count() = {}", n))

	bad := 0
	detail := ""
	for i := 0; i < n; i += 1 {
		th := app.theme_at(i)
		pal := ui.palette_of(th)
		e: ui.Edit
		ui.edit_init(&e)
		ui.edit_paste(&e, "a世")
		caret_paint_row(&e, 40, &pal)
		x, y, ok := ui.edit_caret_cell(&e)
		if !ok {
			bad += 1
			detail = fmt.tprintf("{} {}: no caret cell — cannot prove anything", detail, th.name)
			continue
		}
		c := render_cell_at(x, y)
		if c.fg != caret_attr(pal.caret_fg) || c.bg != caret_attr(pal.caret_bg) {
			bad += 1
			detail = fmt.tprintf("{} {}: WRONG PAIR fg=0x{:08X} want 0x{:08X} bg=0x{:08X} want 0x{:08X}",
				detail, th.name, u32(c.fg), u32(caret_attr(pal.caret_fg)),
				u32(c.bg), u32(caret_attr(pal.caret_bg)))
			continue
		}
		if rune(c.ch) != '█' {
			bad += 1
			detail = fmt.tprintf("{} {}: glyph {} is not the block", detail, th.name, render_glyph_name(rune(c.ch)))
		}
	}
	support.check(t, "every theme paints the caret as caret_fg knocked out of caret_bg",
		bad == 0, fmt.tprintf("{} theme(s) wrong{}", bad, detail))
}
