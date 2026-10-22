package unit

// ─────────────────────────────────────────────────────────────────────────────
// render_cell_test.odin — T7 port of the `render` case (26 counted checks).
//
// Source: `case_render` (src/render_cases.odin:373), driven by section 2 of
// dev/render-smoke.sh.
//
// THE EVIDENCE SURFACE
//
// The renderer's inputs are numbers (Clay's render commands) and its outputs
// are numbers (termbox cells), so the whole thing is pinned down without
// anyone eyeballing a screen: paint a known layout into the BACK buffer, then
// read each cell back with `tb_get_cell(x, y, back=1, ..)` and assert the exact
// glyph + fg + bg triple.
//
// THAT TRIPLE IS THE ASSERTION. "It rendered without panicking" is not a check
// of anything: it is silent about the glyph, silent about the colour, and
// silent about the column. A port of this case to no-panic assertions would
// drop all 26 of these while still going green — which is the exact failure
// mode this migration exists to catch, so it is not done here.
//
// THE GEOMETRY IS CLAY'S, NOT OURS
//
// Every coordinate asserted below comes from `render_find_text_loc`, i.e. from
// the boundingBox Clay itself reported for the text it was given. Hand-computed
// rows would drift the moment Clay's layout changed and would then be asserting
// a screen nobody painted. Where an expectation is arithmetic (centre,
// right-align), the arithmetic is asserted SEPARATELY from the glyph, so a
// change in Clay's rounding shows up as "the arithmetic moved" rather than as
// an inexplicable wrong glyph.
//
// THE DUMP IS NOT DECORATION
//
// `render_dump_rows` prints the painted band into the transcript.
// `core:testing` prints one line per FAILURE and NO GRID. A 44x12 frame that
// is one pixel-row short looks identical to a correct one in a log with no
// grid, and "re-run it and look" is not an option for a suite that runs in a
// sandbox with no screen. The band is the evidence; see the rendered frame at
// the end of this test's output.
//
// ONE @(test) PROC
//
// The old case painted ONCE and asserted 26 facts about that one painting.
// Keeping that shape means every assertion is about the same pixels. Splitting
// it into 26 procs would mean 26 paints, and a renderer that painted
// differently on the second frame could pass a split suite.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import clay "../../clay-odin"
import render "../../src/render"
import tb "../../vendor/termbox2-odin"

import support "../support"

@(test)
render_frame_cells :: proc(t: ^testing.T) {
	support.note(t, "case render — Clay render commands -> cells")
	if !render_session(t, "render") { return }

	tb.tb_clear()
	clay.BeginLayout()
	render_build_frame()
	cmds := clay.EndLayout(0)
	stats := render_paint_cmds(cmds)

	support.note(t, fmt.tprintf("  stats: commands={} rects={} rules={} borders={} text_rows={} glyphs={} claimed={} hidden={} cell_error={}",
		stats.commands, stats.rects, stats.rules, stats.borders, stats.text_rows,
		stats.glyphs, stats.claimed, stats.hidden, stats.cell_error))

	border_attr, _ := render.attr_of(RENDER_C_BORDER)
	text_attr, _ := render.attr_of(RENDER_C_TEXT)
	bg_attr, _ := render.attr_of(RENDER_C_BG)
	accent_attr, _ := render.attr_of(RENDER_C_ACCENT)
	hilite_attr, _ := render.attr_of(RENDER_C_HILITE)

	// --- 1. The four sides + four corners of the bordered box -----------------
	support.check(t, "border top-left corner", render_glyph_at(0, 0) == '┌',
		render_glyph_name(render_glyph_at(0, 0)))
	support.check(t, "border top-right corner", render_glyph_at(RENDER_FRAME_W-1, 0) == '┐',
		render_glyph_name(render_glyph_at(RENDER_FRAME_W-1, 0)))
	support.check(t, "border bottom-left corner", render_glyph_at(0, RENDER_FRAME_H-1) == '└',
		render_glyph_name(render_glyph_at(0, RENDER_FRAME_H-1)))
	support.check(t, "border bottom-right corner", render_glyph_at(RENDER_FRAME_W-1, RENDER_FRAME_H-1) == '┘',
		render_glyph_name(render_glyph_at(RENDER_FRAME_W-1, RENDER_FRAME_H-1)))

	top_edges, bottom_edges, left_edges, right_edges := 0, 0, 0, 0
	x : i32 = 1
	for x < RENDER_FRAME_W-1 {
		if render_glyph_at(x, 0) == '─' { top_edges += 1 }
		if render_glyph_at(x, RENDER_FRAME_H-1) == '─' { bottom_edges += 1 }
		x += 1
	}
	y : i32 = 1
	for y < RENDER_FRAME_H-1 {
		if render_glyph_at(0, y) == '│' { left_edges += 1 }
		if render_glyph_at(RENDER_FRAME_W-1, y) == '│' { right_edges += 1 }
		y += 1
	}
	// ONE check over all four sides, with every count in the detail. The old case
	// did the same: a side that is one glyph short is the bug, and which side it
	// was is detail, not a separate assertion.
	support.check(t, "all four border sides drawn",
		top_edges == RENDER_FRAME_W-2 && bottom_edges == RENDER_FRAME_W-2 &&
			left_edges == RENDER_FRAME_H-2 && right_edges == RENDER_FRAME_H-2,
		fmt.tprintf("top={}/{} bottom={}/{} left={}/{} right={}/{}",
			top_edges, RENDER_FRAME_W-2, bottom_edges, RENDER_FRAME_W-2,
			left_edges, RENDER_FRAME_H-2, right_edges, RENDER_FRAME_H-2))
	support.check(t, "border uses the border colour", render_cell_at(1, 0).fg == border_attr,
		fmt.tprintf("got 0x{:08X} want 0x{:08X}", render_cell_at(1, 0).fg, border_attr))

	// --- 2. The betweenChildren divider rule ---------------------------------
	// Three children -> two gaps -> two rules. Clay never puts the divider's
	// geometry in the Border command; it arrives later as a thin Rectangle in
	// the border's own colour, which is what the renderer's rule lookup keys
	// on. So the divider is proven by THREE things at once: the glyph is a
	// ruled glyph, it sits on a row inside the frame, and it carries the
	// BORDER's colour rather than the background's.
	rule_rows : [16]i32 = {}
	n_rules : int = 0
	y = RENDER_FRAME_PAD
	for y < RENDER_FRAME_H-1 {
		if render_glyph_at(RENDER_FRAME_PAD, y) == '─' && n_rules < len(rule_rows) {
			rule_rows[n_rules] = y
			n_rules += 1
		}
		y += 1
	}
	support.check(t, "betweenChildren rendered as ruled glyphs (2 gaps -> 2 rules)", n_rules == 2,
		fmt.tprintf("interior ─ rows: {} (n={})", rule_rows[0:n_rules], n_rules))
	support.check(t, "renderer counted the rules", stats.rules == 2,
		fmt.tprintf("stats.rules={}", stats.rules))
	if n_rules > 0 {
		rr := rule_rows[0]
		support.check(t, "rule uses the border colour", render_cell_at(RENDER_FRAME_PAD, rr).fg == border_attr,
			fmt.tprintf("got 0x{:08X} want 0x{:08X}", render_cell_at(RENDER_FRAME_PAD, rr).fg, border_attr))
		support.check(t, "rule did not erase the border's left side", render_glyph_at(0, rr) == '│',
			fmt.tprintf("row {} col 0 -> {}", rr, render_glyph_name(render_glyph_at(0, rr))))
		support.check(t, "rule did not erase the border's right side", render_glyph_at(RENDER_FRAME_W-1, rr) == '│',
			fmt.tprintf("row {} col {} -> {}", rr, RENDER_FRAME_W-1, render_glyph_name(render_glyph_at(RENDER_FRAME_W-1, rr))))
	}

	// --- 3. Text placement + colour ------------------------------------------
	_, head_box := render_find_text_loc(cmds, "HEADER")
	support.check(t, "HEADER landed at Clay's boundingBox origin",
		render_glyph_at(head_box.x, head_box.y) == 'H' && head_box.x == RENDER_FRAME_PAD && head_box.y == RENDER_FRAME_PAD,
		fmt.tprintf("clay box=({},{} {}x{}) cell=({},{}) -> {}",
			head_box.x, head_box.y, head_box.w, head_box.h, head_box.x, head_box.y,
			render_glyph_name(render_glyph_at(head_box.x, head_box.y))))
	support.check(t, "HEADER colour", render_cell_at(head_box.x, head_box.y).fg == text_attr,
		fmt.tprintf("got 0x{:08X} want 0x{:08X}", render_cell_at(head_box.x, head_box.y).fg, text_attr))
	support.check(t, "panel background reaches the cell under the text",
		render_cell_at(head_box.x, head_box.y).bg == bg_attr,
		fmt.tprintf("got 0x{:08X} want 0x{:08X}", render_cell_at(head_box.x, head_box.y).bg, bg_attr))

	// --- 4. Alignment, straight from Clay's x --------------------------------
	_, body_box := render_find_text_loc(cmds, RENDER_BODY_TEXT)
	inner_w := RENDER_FRAME_W - 2*RENDER_FRAME_PAD
	body_w := render_cols(RENDER_BODY_TEXT)
	want_centre := render.round_cell((f32(inner_w) - f32(body_w)) / 2.0) + RENDER_FRAME_PAD
	support.check(t, "clay centred the text (bbox x == centre arithmetic)", body_box.x == want_centre,
		fmt.tprintf("clay x={} want {} (text {} cols inside {} cols)", body_box.x, want_centre, body_w, inner_w))
	support.check(t, "centred text painted at that column", render_glyph_at(body_box.x, body_box.y) == 'B',
		fmt.tprintf("({}, {}) -> {}", body_box.x, body_box.y, render_glyph_name(render_glyph_at(body_box.x, body_box.y))))
	support.check(t, "centred text colour", render_cell_at(body_box.x, body_box.y).fg == accent_attr,
		fmt.tprintf("got 0x{:08X} want 0x{:08X}", render_cell_at(body_box.x, body_box.y).fg, accent_attr))

	_, foot_box := render_find_text_loc(cmds, "FOOTER")
	want_right := RENDER_FRAME_W - RENDER_FRAME_PAD - render_cols("FOOTER")
	support.check(t, "clay right-aligned the text (bbox x == right-edge arithmetic)", foot_box.x == want_right,
		fmt.tprintf("clay x={} want {}", foot_box.x, want_right))
	support.check(t, "right-aligned text painted at that column", render_glyph_at(foot_box.x, foot_box.y) == 'F',
		fmt.tprintf("({}, {}) -> {}", foot_box.x, foot_box.y, render_glyph_name(render_glyph_at(foot_box.x, foot_box.y))))
	support.check(t, "right-aligned text colour", render_cell_at(foot_box.x, foot_box.y).fg == hilite_attr,
		fmt.tprintf("got 0x{:08X} want 0x{:08X}", render_cell_at(foot_box.x, foot_box.y).fg, hilite_attr))

	// --- 5. Wide glyphs claim their trailing cell ----------------------------
	// A 2-column glyph must mark the cell behind it as used, or the next write
	// lands on top of the right half of the glyph. The claim is proven by the
	// cell being a BLANK carrying the GLYPH'S OWN colours — not by the glyph
	// being absent, which a cleared buffer would also satisfy.
	cjk_x := body_box.x + render_cols("Body ")
	support.check(t, "CJK glyph drawn at its computed column", render_glyph_at(cjk_x, body_box.y) == '中',
		fmt.tprintf("col {} -> {}", cjk_x, render_glyph_name(render_glyph_at(cjk_x, body_box.y))))
	support.check(t, "wide glyph claimed the following cell", render_glyph_at(cjk_x+1, body_box.y) == ' ',
		fmt.tprintf("col {} -> {} (want a claimed blank)", cjk_x+1, render_glyph_name(render_glyph_at(cjk_x+1, body_box.y))))
	support.check(t, "the claim carries the glyph's own colours",
		render_cell_at(cjk_x+1, body_box.y).fg == accent_attr && render_cell_at(cjk_x+1, body_box.y).bg == bg_attr,
		fmt.tprintf("fg=0x{:08X} bg=0x{:08X}", render_cell_at(cjk_x+1, body_box.y).fg, render_cell_at(cjk_x+1, body_box.y).bg))
	// 中, 文 and 😀 are each 2 columns -> three claims.
	support.check(t, "renderer recorded every claim", stats.claimed == 3,
		fmt.tprintf("stats.claimed={} (expected 3: 中 文 😀)", stats.claimed))
	// The emoji is the last wide glyph on the row; its claim must land right after it.
	emoji_x := body_box.x + render_cols("Body 中文")
	support.check(t, "emoji drawn at its column", render_glyph_at(emoji_x, body_box.y) == '😀',
		fmt.tprintf("col {} -> {}", emoji_x, render_glyph_name(render_glyph_at(emoji_x, body_box.y))))
	support.check(t, "emoji trailing cell claimed", render_glyph_at(emoji_x+1, body_box.y) == ' ',
		fmt.tprintf("col {} -> {}", emoji_x+1, render_glyph_name(render_glyph_at(emoji_x+1, body_box.y))))

	// THE LOAD-BEARING BAND — see the header. Prints the painted frame exactly as
	// the back buffer holds it.
	render_dump_rows(t, "rendered frame (back buffer, cell glyphs)", 0, 0, RENDER_FRAME_W, RENDER_FRAME_H)
}
