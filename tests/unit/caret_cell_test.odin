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
// THE CARET OVERLAYS (RCH-10: "the caret is not an extra cell")
//
// The caret is drawn OVER the character it sits on: the caret element paints
// THAT character in caret_fg on caret_bg, and the prefix/suffix do not paint it
// again. The old contract — `[prefix][█][suffix]`, a bare block that cost an
// extra cell and pushed the suffix one column right — is gone, and the
// assertions that encoded it are re-derived here:
//
//   * mid-field  : the caret cell's glyph EQUALS the character under the caret
//     (NOT '█'), with fg == caret_fg AND bg == caret_bg, and NO block glyph
//     appears anywhere in the row.
//   * at end     : the caret cell IS CARET_GLYPH ('█') with the same pair —
//     the only case where the field is one cell wider than the text.
//   * NO-REFLOW  : paint the same buffer with the caret at column k and at
//     column k+1 and every cell outside the two caret cells is identical
//     (glyph, fg AND bg). That is the assertion that actually proves the fix;
//     the control run (nothing excluded) proves the comparison can see a
//     difference at all.
//   * WIDE RUNE  : a 2-cell rune under the caret is not split — the caret
//     element's own Clay box covers BOTH cells and both carry caret_bg.
//
// WHY THE GLYPH MUST BE PAINTED (constraint B): the terminal cursor keeps
// blinking (DECSCUSR `ESC[3 q`), and an inverting blink spends half its cycle
// inverting the caret cell. Painting the character into that cell is what keeps
// it visible in BOTH blink states; a bare block relying on the terminal's cursor
// overlay would lose the character for half of every blink. `caret_glyph_survives_both_blink_states`
// pins the painted-glyph half of that (the blink itself is the terminal's
// business and unobservable here — see the limitation note below).
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

// ── row snapshots: the surface the NO-REFLOW proof compares ───────────────

// CC_ROW_MAX bounds a row snapshot. The harness terminal is RENDER_COLS (120)
// columns wide, so this grabs a whole row with slack.
CC_ROW_MAX :: 256

// caret_row_of grabs a whole row of the back buffer.
caret_row_of :: proc(y: i32) -> [CC_ROW_MAX]Render_Back_Cell {
	out: [CC_ROW_MAX]Render_Back_Cell
	x: i32 = 0
	for x < RENDER_COLS && x < CC_ROW_MAX {
		out[x] = render_cell_at(x, y)
		x += 1
	}
	return out
}

// caret_row_snap paints the editor and then grabs the row it landed on. The
// snapshot is taken AFTER the paint, from the back buffer, so it records what
// the renderer actually did rather than what this file asked for.
caret_row_snap :: proc(e: ^ui.Edit, width: i32, pal: ^ui.Palette, row: i32) -> [CC_ROW_MAX]Render_Back_Cell {
	caret_paint_row(e, width, pal)
	return caret_row_of(row)
}

// caret_in: does column x fall inside the caret's cells [x0, x0+w)?
caret_in :: proc(x, x0, w: i32) -> bool {
	return x >= x0 && x < x0+w
}

// caret_row_diff counts the columns where two row snapshots differ in ANY of
// glyph, fg or bg — the whole painted content, not just the glyph.
//
// With skip_caret set, the columns each frame's OWN caret legitimately owns are
// excluded: those are the cells the caret is allowed to change. Everything else
// must be identical, column for column. With skip_caret clear nothing is
// excluded — that run is the control which proves the comparison is not blind.
caret_row_diff :: proc(a, b: ^[CC_ROW_MAX]Render_Back_Cell, w: i32,
                      a0, aw, b0, bw: i32, skip_caret: bool) -> (n: int, detail: string) {
	n = 0
	detail = ""
	limit := int(w)
	if limit > CC_ROW_MAX {
		limit = CC_ROW_MAX
	}
	x := 0
	// C-style loop on purpose: the skip below MUST NOT bypass the increment.
	for x := 0; x < limit; x += 1 {
		if skip_caret && (caret_in(i32(x), a0, aw) || caret_in(i32(x), b0, bw)) {
			continue
		}
		if a[x].ch != b[x].ch || a[x].fg != b[x].fg || a[x].bg != b[x].bg {
			n += 1
			if len(detail) < 200 {
				detail = fmt.tprintf("{} col{}:'{}'->'{}'", detail, x,
					render_glyph_name(rune(a[x].ch)), render_glyph_name(rune(b[x].ch)))
			}
		}
	}
	return n, detail
}

// cc_count_glyph counts how many cells of a row hold glyph `g` — used to prove
// the overlaid character is painted EXACTLY ONCE.
cc_count_glyph :: proc(g: rune, y, w: i32) -> int {
	n := 0
	x: i32 = 0
	for x < w {
		if render_glyph_at(x, y) == g {
			n += 1
		}
		x += 1
	}
	return n
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
		// REQUIREMENT 1 — at END OF BUFFER there is nothing to overlay, so the
		// caret paints the fat block (every prefix above leaves the caret at the
		// end). Mid-field the same cell paints the real character instead; see
		// caret_cell_between_glyphs_not_after_them and the overlay tests below.
		support.check(t, fmt.tprintf("'{}': the caret cell at end of buffer is the fat block U+2588", p),
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

// ── the caret parked BETWEEN two painted glyphs: it OVERLAYS, it does not
//    insert a cell ────────────────────────────────────────────────────────────

@(test)
caret_cell_between_glyphs_not_after_them :: proc(t: ^testing.T) {
	if !render_session(t, "caret-cell-mid") { return }
	th, _ := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)

	e: ui.Edit
	ui.edit_init(&e)
	ui.edit_paste(&e, CC_PROBE)   // "a世b😀c" — bytes: a@0 世@1..3 b@4 😀@5..8 c@9
	ui.edit_left(&e)              // off the 'c'
	ui.edit_left(&e)              // off the emoji
	ui.edit_left(&e)              // park the caret ON the 'b', with "😀c" still to its right
	caret_paint_row(&e, RENDER_COLS-2, &pal)

	x, y, ok := ui.edit_caret_cell(&e)
	if !ok {
		support.check(t, "the parked caret reported a cell", false, "ok=false")
		return
	}
	v := ui.edit_view(&e, RENDER_COLS-2)
	want := render_cols("a世")
	support.check(t, "the parked caret sits at the display width of everything before it",
		x == want && y == 0, fmt.tprintf("cell=({},{}) want x={}", x, y, want))

	c := render_cell_at(x, y)
	// THE OVERLAY: the caret cell carries THE CHARACTER IT SITS ON, not a bare
	// block. A caret that paints '█' here is the old extra-cell behaviour and
	// fails this assertion.
	support.check(t, "the caret cell paints the character under it ('b'), NOT the block",
		rune(c.ch) == 'b' && rune(c.ch) != ui.CARET_GLYPH && v.overlay == "b",
		fmt.tprintf("glyph={} overlay='{}'", render_glyph_name(rune(c.ch)), v.overlay))
	// …as the CARET PAIR, so it reads as a caret and not as ordinary text.
	support.check(t, "the overlaid character is painted caret_fg on caret_bg (both halves of the pair)",
		c.fg == caret_attr(pal.caret_fg) && c.bg == caret_attr(pal.caret_bg),
		fmt.tprintf("fg=0x{:08X} want 0x{:08X} bg=0x{:08X} want 0x{:08X}",
			u32(c.fg), u32(caret_attr(pal.caret_fg)), u32(c.bg), u32(caret_attr(pal.caret_bg))))
	// THE CHARACTER IS DRAWN EXACTLY ONCE. If the overlay painted 'b' AND the
	// suffix still carried it, the row would hold two 'b's.
	support.check(t, "the overlaid character appears exactly ONCE in the row",
		cc_count_glyph('b', y, RENDER_COLS) == 1,
		fmt.tprintf("'b' occurs {} times", cc_count_glyph('b', y, RENDER_COLS)))
	// And no block is left stranded anywhere: the caret mid-field does not paint
	// a block at all, so the row must not contain one.
	support.check(t, "no CARET_GLYPH block is painted anywhere in the row when the caret is mid-field",
		cc_count_glyph(ui.CARET_GLYPH, y, RENDER_COLS) == 0,
		fmt.tprintf("block occurs {} times", cc_count_glyph(ui.CARET_GLYPH, y, RENDER_COLS)))
	// THE HALF THAT ONLY EXISTS WHEN THE CARET IS MID-FIELD: the text after the
	// OVERLAY is still painted, immediately to the right of the caret's own
	// cells — NOT one cell further right. That one-cell shove is the bug this
	// replaced, and the emoji is what makes it visible.
	support.check(t, "the suffix starts immediately RIGHT of the caret's cells, unshoved",
		render_glyph_at(x+v.overlay_cols, y) == '😀',
		fmt.tprintf("right of the caret's {} cell(s) = {}",
			v.overlay_cols, render_glyph_name(render_glyph_at(x+v.overlay_cols, y))))
	// …and the rune immediately BEFORE the caret is the 2-cell CJK rune, so the
	// width comes from the rune itself rather than from a fixed 1.
	before := cc_last_rune("a世") // the rune the caret was stepped back onto
	w := render.glyph_columns(before)
	support.check(t, fmt.tprintf("the rune before the caret is '{}' ({} cells wide, first cell at x-{})", before, w, w),
		w == 2 && render_glyph_at(x-w, y) == before,
		fmt.tprintf("at x-{} = {}", w, render_glyph_name(render_glyph_at(x-w, y))))
	// The painted row is exactly the text: 7 cells, no extra one.
	support.check(t, "the painted field is text_cols(buffer) wide — no extra cell mid-field",
		render_glyph_at(render_cols(CC_PROBE), y) != ui.CARET_GLYPH,
		fmt.tprintf("cell at x={} = {}", render_cols(CC_PROBE),
			render_glyph_name(render_glyph_at(render_cols(CC_PROBE), y))))
	render_dump_rows(t, "caret parked ON 'b' in a世b😀c (overlay, not a block)", 0, 0, 12, 1)
}

// ── NO REFLOW: the assertion that actually proves the overlay ─────────────

@(test)
caret_cell_overlay_never_reflows_the_row :: proc(t: ^testing.T) {
	if !render_session(t, "caret-noreflow") { return }
	th, _ := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)
	width : i32 = RENDER_COLS - 2 // roomy: no horizontal scrolling is involved

	e: ui.Edit
	ui.edit_init(&e)
	ui.edit_paste(&e, CC_PROBE) // 10 bytes, 7 cells, three width classes

	// Frame 0: the caret at END — the one case where it costs an extra cell.
	prev := caret_row_snap(&e, width, &pal, 0)
	pv := ui.edit_view(&e, width)
	px, py, pok := ui.edit_caret_cell(&e)
	if !pok {
		support.check(t, "the end-of-buffer caret reported a cell", false, "ok=false")
		return
	}
	support.check(t, "frame 0 (caret at end) paints the block at the end column",
		px == render_cols(CC_PROBE) && render_glyph_at(px, py) == ui.CARET_GLYPH && pv.overlay_cols == 1,
		fmt.tprintf("x={} cols={} glyph={}", px, pv.overlay_cols, render_glyph_name(render_glyph_at(px, py))))

	steps := 0
	reflow := 0
	blind := 0
	extra := 0
	detail := ""
	for ui.edit_left(&e) {
		cur := caret_row_snap(&e, width, &pal, 0)
		cv := ui.edit_view(&e, width)
		cx, cy, cok := ui.edit_caret_cell(&e)
		if !cok {
			support.check(t, "the caret reported a cell at every step", false, fmt.tprintf("step {}", steps+1))
			break
		}
		steps += 1

		// THE NO-REFLOW PROPERTY: outside the cells the two frames' carets own,
		// the frames are identical — same glyph, same fg, same bg, same column.
		// Painting the same buffer with the caret at column k and at column k+1
		// moves NOTHING else. The window never scrolled (both frames report
		// scroll 0), so any shove here is the caret's own doing.
		n, d := caret_row_diff(&prev, &cur, RENDER_COLS, px, pv.overlay_cols, cx, cv.overlay_cols, true)
		if n > 0 {
			reflow += 1
			detail = fmt.tprintf("{} step{} caret x={} -> x={}: {} cell(s) moved: {}", detail, steps, px, cx, n, d)
		}
		if pv.scroll != 0 || cv.scroll != 0 {
			support.check(t, "…and the window never scrolled during the walk",
				false, fmt.tprintf("prev.scroll={} cur.scroll={}", pv.scroll, cv.scroll))
		}
		// CONTROL: the same comparison with nothing excluded MUST see a
		// difference, or the no-reflow check above would be blind (an
		// always-equal snapshot comparison passes for any bug whatsoever).
		nall, _ := caret_row_diff(&prev, &cur, RENDER_COLS, px, pv.overlay_cols, cx, cv.overlay_cols, false)
		if nall == 0 {
			blind += 1
		}
		// Only the END-of-buffer caret gets the extra cell: one column past the
		// text there must be no block in any mid-field frame.
		if render_glyph_at(render_cols(CC_PROBE), cy) == ui.CARET_GLYPH {
			extra += 1
		}
		prev, pv, px = cur, cv, cx
	}

	support.check(t, "the walk covered every rune boundary of the fixture",
		steps == 5, fmt.tprintf("steps={} for '{}' (5 runes)", steps, CC_PROBE))
	support.check(t, "NO-REFLOW: moving the caret never moves a glyph outside the caret cell",
		reflow == 0, fmt.tprintf("{} step(s) reflowed — {}", reflow, detail))
	support.check(t, "the comparison is NOT blind: the caret cells themselves changed every step",
		blind == 0, fmt.tprintf("{} step(s) showed no difference at all", blind))
	support.check(t, "no mid-frame paints the extra end-of-buffer block",
		extra == 0, fmt.tprintf("{} mid-field frame(s) painted a block at x={}", extra, render_cols(CC_PROBE)))
	render_dump_rows(t, "caret walked to the left across a世b😀c", 0, 0, 12, 1)
}

// ── a 2-cell rune under the caret is not split ───────────────────────────────

// Caret fixtures that park the caret ON a wide rune, one per wide class: CJK
// (3 bytes / 2 cells) and an astral emoji (4 bytes / 2 cells).
CC_WIDE :: struct {
	text   : string, // the buffer
	left   : int,    // whole-rune steps LEFT from end-of-buffer that land ON the wide rune
	want   : rune,   // the rune the caret must overlay
	prefix : string, // the text before that rune (its display width is the caret's column)
	next   : rune,   // the character that must appear immediately after the overlay
}

@(test)
caret_cell_overlay_does_not_split_a_wide_rune :: proc(t: ^testing.T) {
	if !render_session(t, "caret-wide") { return }
	th, _ := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)

	fixtures := []CC_WIDE{
		CC_WIDE{text = "a世b", left = 2, want = '世', prefix = "a", next = 'b'},
		CC_WIDE{text = "a😀b", left = 2, want = '😀', prefix = "a", next = 'b'},
	}
	for f in fixtures {
		e: ui.Edit
		ui.edit_init(&e)
		ui.edit_paste(&e, f.text)
		k := 0
		for k < f.left {
			ui.edit_left(&e)
			k += 1
		}
		caret_paint_row(&e, RENDER_COLS-2, &pal)
		x, y, ok := ui.edit_caret_cell(&e)
		if !ok {
			support.check(t, fmt.tprintf("'{}': the caret reported a cell", f.text), false, "ok=false")
			continue
		}
		v := ui.edit_view(&e, RENDER_COLS-2)
		// The overlay is the WHOLE wide rune and claims BOTH cells.
		support.check(t, fmt.tprintf("'{}': the overlay is the whole wide rune and is 2 cells wide", f.text),
			v.overlay_cols == 2 && render.glyph_columns(cc_last_rune(v.overlay)) == 2 &&
				rune(cc_last_rune(v.overlay)) == f.want,
			fmt.tprintf("overlay='{}' cols={}", v.overlay, v.overlay_cols))
		// The caret ELEMENT covers both cells of the rune — read out of Clay's
		// own box, not recomputed here.
		box := render.snap_box(clay.GetElementData(e.caret_id).boundingBox)
		support.check(t, fmt.tprintf("'{}': the caret element's own Clay box spans 2 cells", f.text),
			box.w == 2, fmt.tprintf("clay box w={}", box.w))
		// First cell = the rune itself, in the caret pair.
		c := render_cell_at(x, y)
		support.check(t, fmt.tprintf("'{}': the caret's first cell is the rune, in caret_fg on caret_bg", f.text),
			rune(c.ch) == f.want && c.fg == caret_attr(pal.caret_fg) && c.bg == caret_attr(pal.caret_bg),
			fmt.tprintf("glyph={} fg=0x{:08X} bg=0x{:08X}", render_glyph_name(rune(c.ch)), u32(c.fg), u32(c.bg)))
		// Second cell = the rune's own tail, and it belongs to the CARET (its bg
		// is caret_bg), not to whatever glyph happens to be next.
		tail := render_cell_at(x+1, y)
		support.check(t, fmt.tprintf("'{}': the rune's second cell is inside the caret (bg == caret_bg) and is NOT the next character", f.text),
			tail.bg == caret_attr(pal.caret_bg) && rune(tail.ch) != f.next,
			fmt.tprintf("tail='{}' bg=0x{:08X} want 0x{:08X}", render_glyph_name(rune(tail.ch)),
				u32(tail.bg), u32(caret_attr(pal.caret_bg))))
		// The neighbours are unshoved: 'a' before, `next` immediately after the
		// overlay's two cells.
		support.check(t, fmt.tprintf("'{}': the neighbour after the 2-cell overlay is '{}', unshoved", f.text, f.next),
			render_glyph_at(x+2, y) == f.next && render_glyph_at(x-1, y) == 'a',
			fmt.tprintf("x-1={} x+2={}", render_glyph_name(render_glyph_at(x-1, y)),
				render_glyph_name(render_glyph_at(x+2, y))))
		// And the caret's column is still the display width of the prefix.
		support.check(t, fmt.tprintf("'{}': the caret's column is the display width of '{}'", f.text, f.prefix),
			x == render_cols(f.prefix), fmt.tprintf("x={} want {}", x, render_cols(f.prefix)))
	}
	render_dump_rows(t, "caret overlaying a 2-cell rune", 0, 0, 12, 1)
}

// ── the overlay survives a narrow window (scroll math) ───────────────────────

@(test)
caret_cell_overlay_narrow_window_holds_whole_overlay :: proc(t: ^testing.T) {
	if !render_session(t, "caret-narrow") { return }
	th, _ := app.theme_named(app.THEME_DEFAULT_NAME)
	pal := ui.palette_of(th)

	widths := []i32{2, 3, 4, 5, 6, 7}
	for w in widths {
		e: ui.Edit
		ui.edit_init(&e)
		ui.edit_paste(&e, CC_PROBE)
		for {
			caret_paint_row(&e, w, &pal)
			v := ui.edit_view(&e, w)
			x, y, ok := ui.edit_caret_cell(&e)
			if !ok {
				support.check(t, fmt.tprintf("width {}: the caret reported a cell", w), false, "ok=false")
				break
			}
			// The caret's column inside the window is a real column of it.
			support.check(t, fmt.tprintf("width {}: the caret lands inside the window (caret_x={})", w, v.caret_x),
				v.caret_x >= 0 && v.caret_x < w, fmt.tprintf("caret_x={} width={}", v.caret_x, w))
			// …and so does the WHOLE overlay, both cells of a 2-cell rune.
			support.check(t, fmt.tprintf("width {}: the whole {}-cell overlay fits (caret_x+cols <= width)", w, v.overlay_cols),
				v.overlay_cols >= 1 && v.caret_x+v.overlay_cols <= w,
				fmt.tprintf("caret_x={} overlay_cols={} width={}", v.caret_x, v.overlay_cols, w))
			// The visible slice never exceeds the window width.
			vis := ui.text_cols(v.prefix) + v.overlay_cols + ui.text_cols(v.suffix)
			support.check(t, fmt.tprintf("width {}: the visible slice fits the window", w),
				vis <= w, fmt.tprintf("prefix {} + overlay {} + suffix {} = {}, must be <= window {}",
					ui.text_cols(v.prefix), v.overlay_cols, ui.text_cols(v.suffix), vis, w))
			// Clay laid the caret where the row actually put it: right after the
			// painted prefix (the prefix is what pushes it, never a guess).
			support.check(t, fmt.tprintf("width {}: the caret cell follows the painted prefix", w),
				x == ui.text_cols(v.prefix), fmt.tprintf("clay x={} painted prefix {}", x, ui.text_cols(v.prefix)))
			// And the caret cell really is the overlay (or the block at end).
			want_glyph := ui.CARET_GLYPH
			if len(v.overlay) > 0 {
				want_glyph = cc_last_rune(v.overlay)
			}
			support.check(t, fmt.tprintf("width {}: the caret cell paints the overlay glyph", w),
				render_glyph_at(x, y) == want_glyph && x < w,
				fmt.tprintf("glyph={} want {}", render_glyph_name(render_glyph_at(x, y)), render_glyph_name(want_glyph)))
			if !ui.edit_left(&e) {
				break
			}
		}
	}
	render_dump_rows(t, "caret overlay in a narrow window", 0, 0, 12, 1)
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
	bad_mid := 0
	bad_blink := 0
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

		// THE SAME PAIR MID-FIELD, drawn with the CHARACTER rather than a block.
		// Parked on the 2-cell CJK rune, so this also sweeps the overlay's wide
		// case in every theme.
		ui.edit_left(&e) // end -> ON the '世' (one whole-rune step back)
		caret_paint_row(&e, 40, &pal)
		mx, my, mok := ui.edit_caret_cell(&e)
		if !mok {
			bad_mid += 1
			detail = fmt.tprintf("{} {}: no mid-field caret cell", detail, th.name)
			continue
		}
		mc := render_cell_at(mx, my)
		if rune(mc.ch) != '世' {
			bad_mid += 1
			detail = fmt.tprintf("{} {}: mid-field caret painted '{}' instead of the character under it",
				detail, th.name, render_glyph_name(rune(mc.ch)))
		}
		if mc.fg != caret_attr(pal.caret_fg) || mc.bg != caret_attr(pal.caret_bg) {
			bad_mid += 1
			detail = fmt.tprintf("{} {}: mid-field WRONG PAIR fg=0x{:08X} want 0x{:08X} bg=0x{:08X} want 0x{:08X}",
				detail, th.name, u32(mc.fg), u32(caret_attr(pal.caret_fg)),
				u32(mc.bg), u32(caret_attr(pal.caret_bg)))
		}
		// THE BLINK HALF OF THE REQUIREMENT, as far as the back buffer can see
		// it: the character must LIVE IN THE CELL, so that whatever the terminal
		// does to that cell when the cursor blinks (it INVERTS it), the glyph is
		// still there. A cell stripped of its glyph and painted as a bare block —
		// relying on the terminal's cursor overlay to reveal the character — is
		// exactly what this catches: the painted character would be ' ' or the
		// block, and would vanish on half of every blink cycle.
		if rune(mc.ch) == ' ' || rune(mc.ch) == 0 || rune(mc.ch) == ui.CARET_GLYPH {
			bad_blink += 1
			detail = fmt.tprintf("{} {}: mid-field caret cell holds '{}' — the character is NOT painted into the cell, so it cannot survive the blink",
				detail, th.name, render_glyph_name(rune(mc.ch)))
		}
		// …and the caret's tail cell (this rune is 2 cells) carries the caret's
		// background too, so the inverted cell is the rune's own width.
		if render_cell_at(mx+1, my).bg != caret_attr(pal.caret_bg) {
			bad_blink += 1
			detail = fmt.tprintf("{} {}: the 2-cell overlay's tail cell is outside the caret's background", detail, th.name)
		}
	}
	support.check(t, "every theme paints the caret as caret_fg knocked out of caret_bg",
		bad == 0, fmt.tprintf("{} theme(s) wrong{}", bad, detail))
	support.check(t, "every theme paints the mid-field caret as the CHARACTER under it, in the same pair",
		bad_mid == 0, fmt.tprintf("{} theme(s) wrong{}", bad_mid, detail))
	support.check(t, "every theme paints that character INTO the cell, so it is visible in both blink states",
		bad_blink == 0, fmt.tprintf("{} theme(s) wrong{}", bad_blink, detail))
}
