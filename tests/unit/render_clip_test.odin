package unit

// ─────────────────────────────────────────────────────────────────────────────
// render_clip_test.odin — T7 port of the `clip` case (6 ported checks + 1
// additive vacuity guard = 7 counted).
//
// Source: `case_clip` (src/render_cases.odin:601), section 3 of
// dev/render-smoke.sh.
//
// WHAT IS ACTUALLY BEING PROVEN
//
// A ~75-column child inside a 14-column clip must leak NOTHING: not one cell
// past the right edge, not one cell below the box. That is ~4.7k cells checked
// individually, and the proof is that every single one is exactly as
// `tb_clear()` left it.
//
// THE SENTINEL IS WHY THIS IS DECIDABLE AT ALL
//
// `tb_clear()` does not zero the back buffer — `cellbuf_clear()` fills every
// cell with a SPACE plus the *current clear attrs*. So "nobody painted here"
// cannot be tested with `ch == 0`; a freshly cleared screen is full of 0x20.
// Setting a colour no fixture ever uses (RENDER_SENTINEL_FG/BG) turns
// untouched into an exactly decidable predicate: space glyph AND sentinel fg
// AND sentinel bg. Any one of the three would be a false positive on its own.
//
// THE ADDITIVE GUARD, AND WHY IT IS COUNTED
//
// The old case had the same guard but emitted only on failure, so it added
// nothing to the assertion count while the fixture was good. That leaves the
// failure mode unobservable in the green direction: if someone shortened
// OVERFLOW_TEXT to fit inside 14 columns, the leak test below would pass while
// testing no overflow at all, and the suite's count would not change. Making
// it a counted assertion means a fixture that stopped overflowing shows up as
// one fewer passing assertion than the floor — which the gate cannot miss.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import clay "../../clay-odin"
import tb "../../vendor/termbox2-odin"

import support "../support"

// render_untouched is the leak predicate: this cell is exactly as tb_clear()
// left it. See the header for why all THREE conditions are required.
render_untouched :: proc(x, y: i32) -> bool {
	c := render_cell_at(x, y)
	return c.ch == u32(' ') && c.fg == RENDER_SENTINEL_FG && c.bg == RENDER_SENTINEL_BG
}

// render_leak_label names the glyph found at a leaked cell, so a failure says
// WHAT leaked rather than only WHERE.
render_leak_label :: proc(x, y: i32) -> string {
	if x < 0 { return "n/a" }
	return render_glyph_name(render_glyph_at(x, y))
}

@(test)
render_clip_contains_overflow :: proc(t: ^testing.T) {
	support.note(t, "case clip — scissor must contain the overflow")
	if !render_session(t, "clip") { return }

	// Sentinel attrs BEFORE the clear: the clear is what spreads them.
	tb.tb_set_clear_attrs(RENDER_SENTINEL_FG, RENDER_SENTINEL_BG)
	tb.tb_clear()

	clay.BeginLayout()
	render_build_clip()
	cmds := clay.EndLayout(0)
	stats := render_paint_cmds(cmds)
	support.note(t, fmt.tprintf("  stats: commands={} text_rows={} glyphs={} hidden={} scissors={} cell_error={}",
		stats.commands, stats.text_rows, stats.glyphs, stats.hidden, stats.scissors, stats.cell_error))

	full := render_cols(RENDER_OVERFLOW_TEXT)
	support.note(t, fmt.tprintf("  overflow text is {} columns inside a {}-column clip", full, RENDER_CLIP_W))
	support.check(t, "the fixture actually overflows the clip", full > RENDER_CLIP_W,
		fmt.tprintf("text is {} columns, clip is {} — at or below the clip width the leak checks below would pass vacuously",
			full, RENDER_CLIP_W))

	_, box := render_find_text_loc(cmds, RENDER_OVERFLOW_TEXT)
	support.note(t, fmt.tprintf("  clay gave the text a {}-column box at ({},{})", box.w, box.x, box.y))

	// 1. The interior really is painted with the right glyphs. Without this the
	//    "nothing outside" checks could be satisfied by a renderer that painted
	//    nothing anywhere.
	support.check(t, "clip interior carries the text",
		render_glyph_at(0, 0) == 'T' && render_glyph_at(5, 0) == 'o' && render_glyph_at(13, 0) == 'i',
		fmt.tprintf("(0,0)={} (5,0)={} (13,0)={}   (want OVE[R]FLOW chars 'T','o','i')",
			render_glyph_name(render_glyph_at(0, 0)), render_glyph_name(render_glyph_at(5, 0)),
			render_glyph_name(render_glyph_at(13, 0))))
	support.check(t, "interior painted right up to the clip width", render_glyph_at(RENDER_CLIP_W-1, 0) != ' ',
		fmt.tprintf("(col {}, row 0) -> {}", RENDER_CLIP_W-1, render_glyph_name(render_glyph_at(RENDER_CLIP_W-1, 0))))

	// 2. Past the clip's right edge: not one cell touched, on any row the text
	//    ran into. This is the assertion the whole scissor exists for.
	scanned, touched := 0, 0
	fx, fy : i32 = -1, -1
	row : i32 = 0
	for row < RENDER_CLIP_H {
		x : i32 = RENDER_CLIP_W
		for x < tb.tb_width() {
			scanned += 1
			if !render_untouched(x, row) {
				touched += 1
				if fx < 0 { fx = x; fy = row }
			}
			x += 1
		}
		row += 1
	}
	support.check(t, "nothing painted past the clip's right edge", touched == 0,
		fmt.tprintf("{}/{} cells outside were painted (first at ({},{}) -> {})",
			touched, scanned, fx, fy, render_leak_label(fx, fy)))

	// 3. Below the clip: still nothing.
	scanned, touched = 0, 0
	bx, by : i32 = -1, -1
	y : i32 = RENDER_CLIP_H
	for y < tb.tb_height() {
		x : i32 = 0
		for x < tb.tb_width() {
			scanned += 1
			if !render_untouched(x, y) {
				touched += 1
				if bx < 0 { bx = x; by = y }
			}
			x += 1
		}
		y += 1
	}
	support.check(t, "nothing painted below the clip", touched == 0,
		fmt.tprintf("{}/{} cells below row {} were painted (first at ({},{}) -> {})",
			touched, scanned, RENDER_CLIP_H-1, bx, by, render_leak_label(bx, by)))

	// 4. The control that makes check 2 non-trivial: the boundary is a real
	//    intersection and not a "draw the first N columns" hack. Column
	//    CLIP_W-1 painted and column CLIP_W untouched, ADJACENT CELLS, same
	//    row — a prefix draw cannot tell the two apart from a clip.
	support.check(t, "the clip is a real intersection, not a prefix draw",
		render_untouched(RENDER_CLIP_W, 0) && !render_untouched(RENDER_CLIP_W-1, 0),
		fmt.tprintf("col {} untouched={} col {} untouched={}",
			RENDER_CLIP_W, render_untouched(RENDER_CLIP_W, 0),
			RENDER_CLIP_W-1, render_untouched(RENDER_CLIP_W-1, 0)))

	support.check(t, "the scissor commands were consumed", stats.scissors >= 2,
		fmt.tprintf("stats.scissors={} (start + end)", stats.scissors))

	// THE BAND: painted container plus enough empty space to the right and
	// below that a leak would be visible to the eye in the transcript too.
	render_dump_rows(t, "clip container painted; everything right/below must be blank",
		0, 0, RENDER_CLIP_W+20, RENDER_CLIP_H+3)
}
