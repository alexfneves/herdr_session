package main

// PHASE 2 DRIVER — Clay -> termbox2 renderer, proven cell by cell.
//
// The renderer's inputs are numbers (Clay's render commands) and its outputs are
// numbers (termbox cells), so the whole thing can be pinned down without anyone
// eyeballing a screen: render a known layout into the back buffer, then read the
// cells back with `tb_get_cell(.., back=1, ..)` and assert on glyph + fg + bg.
// The pty in dev/render-smoke.sh supplies the terminal; the typescript it records
// proves the colours actually left the process as truecolour SGR.
//
// Cases:
//   measure          display-column maths (headless, no tty needed)
//   render           bordered box + betweenChildren rule + alignment + colours
//   clip             scissor: overflowing content must not paint outside the box
//   clay-error       a deliberate duplicate id, surfaced outside the C frame
//   layout-dump      the raw command stream (for humans updating the renderer)

import clay "../clay-odin"
import render "./render"
import termbox2 "../vendor/termbox2-odin"

import "core:c"
import "core:fmt"
import "core:mem"

// ---------------------------------------------------------------------------
// Clay session
// ---------------------------------------------------------------------------

CLAY_PAD :: 64 * 1024 // slack over MinMemorySize, so the arena is never the limit

clay_buf : []u8 = nil

// clay_start brings up a Clay context wired to our measurement function and our
// error handler, sized from Clay's own MinMemorySize rather than a guessed magic
// number.
clay_start :: proc() -> bool {
	need := int(clay.MinMemorySize()) + CLAY_PAD
	if len(clay_buf) < need {
		if len(clay_buf) > 0 { delete(clay_buf) }
		clay_buf = make([]u8, need)
	}

	arena := clay.CreateArenaWithCapacityAndMemory(c.size_t(len(clay_buf)), raw_data(clay_buf))
	ctx := clay.Initialize(arena, clay.Dimensions{width = 120, height = 40}, render.errors_handler_for())
	if ctx == nil {
		say("  [FAIL] clay.Initialize returned nil")
		return false
	}
	clay.SetMeasureTextFunction(render.measure_text, nil)
	return true
}

cols :: proc(s: string) -> i32 {
	return render.text_columns(transmute([]u8)(s))
}

// ---------------------------------------------------------------------------
// Back-buffer probing
// ---------------------------------------------------------------------------

Cell :: struct {
	ch : u32,
	fg : termbox2.Attr,
	bg : termbox2.Attr,
}

cell_at :: proc(x, y: i32) -> Cell {
	out := Cell{}
	ptr: ^termbox2.Cell = nil
	if termbox2.tb_get_cell(x, y, 1, &ptr) == termbox2.TB_OK && ptr != nil {
		out.ch = ptr.ch
		out.fg = ptr.fg
		out.bg = ptr.bg
	}
	return out
}

glyph_at :: proc(x, y: i32) -> rune {
	return rune(cell_at(x, y).ch)
}

glyph_name :: proc(ch: rune) -> string {
	return fmt.tprintf("U+{:04X} '{}'", u32(ch), ch)
}

// dump_rows renders a band of the back buffer as plain text, so the evidence is
// readable in a log rather than only on a live terminal. The ASCII frame
// characters are ours; anything inside is what the renderer actually put there.
dump_rows :: proc(label: string, x0, y0, w, h: i32) {
	say(fmt.tprintf("  .{} {}.", repeat_str("-", max(2, 62-len(label))), label))
	y: i32 = 0
	for y < h {
		buf: [dynamic]byte
		x: i32 = 0
		for x < w {
			push_str(&buf, fmt.tprintf("{}", glyph_at(x0+x, y0+y)))
			x += 1
		}
		say(fmt.tprintf("  |{}|", string(buf[:])))
		clear(&buf)
		y += 1
	}
	say(fmt.tprintf("  `{}'", repeat_str("-", int(w)+2)))
}

push_str :: proc(out: ^[dynamic]byte, s: string) {
	i := 0
	for i < len(s) {
		append(out, s[i])
		i += 1
	}
}

repeat_str :: proc(s: string, n: int) -> string {
	buf: [dynamic]byte
	i := 0
	for i < n {
		push_str(&buf, s)
		i += 1
	}
	return string(buf[:])
}

// paint_cmds pushes an already-computed command stream through the renderer.
paint_cmds :: proc(cmds: clay.ClayArray(clay.RenderCommand)) -> render.Stats {
	view := render.Renderer{}
	stats := render.render_frame(&view, cmds)
	termbox2.tb_present()
	return stats
}

// render_and_present lays out `build`, paints it and pushes it to the terminal.
render_and_present :: proc(build: proc()) -> render.Stats {
	clay.BeginLayout()
	build()
	return paint_cmds(clay.EndLayout(0))
}

cmd_text :: proc(cmds: clay.ClayArray(clay.RenderCommand), i: int) -> string {
	t := cmds.internalArray[i].renderData.text
	return string(mem.byte_slice(t.stringContents.chars, int(t.stringContents.length)))
}

// find_text_loc returns the index and snapped box of the first TEXT command whose
// contents equal `want`. Tests then assert against *Clay's* own geometry instead
// of hand-computed rows, so a Clay that lays out differently fails loudly rather
// than silently retargeting the assertion.
find_text_loc :: proc(cmds: clay.ClayArray(clay.RenderCommand), want: string) -> (int, render.Rect) {
	i := 0
	for i < int(cmds.length) {
		c := cmds.internalArray[i]
		if c.commandType == .Text && cmd_text(cmds, i) == want {
			return i, render.snap_box(c.boundingBox)
		}
		i += 1
	}
	return -1, render.Rect{}
}


// ---------------------------------------------------------------------------
// Case: measure
// ---------------------------------------------------------------------------

// Measure_Case is one row of the T2.1 proof table.
Measure_Case :: struct {
	text : string, // utf8 input
	bytes : int, // how long it is in memory
	runes : int, // how many code points
	want : i32, // how many columns it must occupy
	note : string,
}

MEASURE_CASES := []Measure_Case{
	{"hello", 5, 5, 5, "ASCII"},
	{"hello world", 11, 11, 11, "ASCII with a space"},
	{"世界", 6, 2, 4, "CJK — 6 bytes, 2 runes, 4 columns"},
	{"中a文b", 8, 4, 6, "mixed CJK/ASCII"},
	{"e\u0301", 3, 2, 1, "e + U+0301 combining acute"},
	{"e\u0301\u0301n", 5, 4, 2, "two stacking marks on e, then n"},
	{"😀", 4, 1, 2, "emoji — 4 bytes, 1 rune, 2 columns"},
	{"a😀b", 6, 2, 4, "emoji between ASCII"},
	{"", 0, 0, 0, "empty string"},
	{"tab\there", 8, 8, 8, "tab counted as one replacement glyph (no tab stops in a layout)"},
}

// case_measure is T2.1's proof. Display columns, not bytes, not runes.
case_measure :: proc() -> bool {
	say("case measure — Clay measure_text in terminal columns")

	for it in MEASURE_CASES {
		got := cols(it.text)
		check(fmt.tprintf("cols({}) == {}", it.text, it.want), got == it.want,
			fmt.tprintf("got {}  (bytes={} runes={})  {}", got, len(it.text), count_runes(it.text), it.note))
	}

	// The function Clay itself calls must report one cell per line: Clay multiplies
	// this by its own wrapped-line count, so anything else inflates every line.
	word := "multi"
	measured := render.measure_text(clay.StringSlice{
		chars = raw_data(word),
		length = 5,
	}, nil, nil)
	check("measure_text height == 1 cell/line", measured.height == 1.0,
		fmt.tprintf("got {} cells per line", measured.height))
	check("measure_text width == 5 columns", measured.width == 5.0,
		fmt.tprintf("got {}", measured.width))

	// And the two must agree: what we measure is what tb_wcwidth reports, or the
	// columns drift between layout and paint.
	drift := 0
	sample := "hello 世界 😀 combining é"
	idx := 0
	for r in sample {
		w := render.glyph_columns(r)
		tw := termbox2.tb_wcwidth(u32(r))
		if tw < 0 { tw = 1 }
		if w != tw { drift += 1 }
		idx += 1
	}
	check("glyph_columns agrees with tb_wcwidth", drift == 0,
		fmt.tprintf("mismatches={} over {} runes", drift, idx))

	return !any_failed
}

// ---------------------------------------------------------------------------
// Case: render
// ---------------------------------------------------------------------------

// frame colours. Deliberately distinct so a mis-wired channel is visible: if Clay
// colours were read as 0..1 instead of 0..255 everything would land black.
C_BG      : clay.Color = clay.Color{16, 20, 28, 255}
C_BORDER  : clay.Color = clay.Color{255, 60, 60, 255}
C_TEXT    : clay.Color = clay.Color{220, 220, 220, 255}
C_ACCENT  : clay.Color = clay.Color{60, 200, 120, 255}
C_HILITE  : clay.Color = clay.Color{40, 90, 200, 255}

FRAME_W :: 44
FRAME_H :: 12
FRAME_PAD :: 1
FRAME_GAP :: 2 // must be >= 2: see the childGap trap noted in render_border

build_frame :: proc() {
	if clay.UI(clay.ID("frame"))({
		layout = {
			sizing = {width = clay.SizingFixed(FRAME_W), height = clay.SizingFixed(FRAME_H)},
			padding = clay.PaddingAll(FRAME_PAD),
			childGap = FRAME_GAP,
			layoutDirection = .TopToBottom,
		},
		backgroundColor = C_BG,
		border = {color = C_BORDER, width = clay.BorderAll(1)},
	}) {
		clay.Text("HEADER", clay.TextElementConfig{textColor = C_TEXT})

		// A row, so childAlignment can push the text to the middle. A TEXT
		// command fits its content, so alignment only shows up in boundingBox.x
		// via the *parent's* childAlignment.
		if clay.UI(clay.ID("mid"))({
			layout = {
				sizing = {width = clay.SizingGrow()},
				childAlignment = {x = .Center},
			},
		}) {
			clay.Text("Body 中文😀 mix", clay.TextElementConfig{textColor = C_ACCENT})
		}

		if clay.UI(clay.ID("foot"))({
			layout = {
				sizing = {width = clay.SizingGrow()},
				childAlignment = {x = .Right},
			},
		}) {
			clay.Text("FOOTER", clay.TextElementConfig{textColor = C_HILITE})
		}
	}
}

// case_render is T2.2's proof: the four border sides, the betweenChildren rule,
// alignment and truecolour all reach the cell grid.
case_render :: proc() -> bool {
	say("case render — Clay render commands -> cells")
	if !enter_terminal() { return false }
	if !clay_start() { leave_terminal(); return false }

	termbox2.tb_clear()
	clay.BeginLayout()
	build_frame()
	cmds := clay.EndLayout(0)
	stats := paint_cmds(cmds)

	say(fmt.tprintf("  stats: commands={} rects={} rules={} borders={} text_rows={} glyphs={} claimed={} hidden={} cell_error={}",
		stats.commands, stats.rects, stats.rules, stats.borders, stats.text_rows,
		stats.glyphs, stats.claimed, stats.hidden, stats.cell_error))

	border_attr, _ := render.attr_of(C_BORDER)
	text_attr, _ := render.attr_of(C_TEXT)
	bg_attr, _ := render.attr_of(C_BG)
	accent_attr, _ := render.attr_of(C_ACCENT)
	hilite_attr, _ := render.attr_of(C_HILITE)

	// --- 1. The four sides + four corners of the bordered box -----------------
	check("border top-left corner", glyph_at(0, 0) == '┌', glyph_name(glyph_at(0, 0)))
	check("border top-right corner", glyph_at(FRAME_W-1, 0) == '┐', glyph_name(glyph_at(FRAME_W-1, 0)))
	check("border bottom-left corner", glyph_at(0, FRAME_H-1) == '└', glyph_name(glyph_at(0, FRAME_H-1)))
	check("border bottom-right corner", glyph_at(FRAME_W-1, FRAME_H-1) == '┘', glyph_name(glyph_at(FRAME_W-1, FRAME_H-1)))

	top_edges, bottom_edges, left_edges, right_edges := 0, 0, 0, 0
	x: i32 = 1
	for x < FRAME_W-1 {
		if glyph_at(x, 0) == '─' { top_edges += 1 }
		if glyph_at(x, FRAME_H-1) == '─' { bottom_edges += 1 }
		x += 1
	}
	y: i32 = 1
	for y < FRAME_H-1 {
		if glyph_at(0, y) == '│' { left_edges += 1 }
		if glyph_at(FRAME_W-1, y) == '│' { right_edges += 1 }
		y += 1
	}
	check("all four border sides drawn",
		top_edges == FRAME_W-2 && bottom_edges == FRAME_W-2 && left_edges == FRAME_H-2 && right_edges == FRAME_H-2,
		fmt.tprintf("top={}/{} bottom={}/{} left={}/{} right={}/{}",
			top_edges, FRAME_W-2, bottom_edges, FRAME_W-2, left_edges, FRAME_H-2, right_edges, FRAME_H-2))
	check("border uses the border colour", cell_at(1, 0).fg == border_attr,
		fmt.tprintf("got 0x{:08X} want 0x{:08X}", cell_at(1, 0).fg, border_attr))

	// --- 2. The betweenChildren divider rule ---------------------------------
	// Three children -> two gaps -> two rules. Clay never puts the divider's
	// geometry in the Border command; it arrives later as a thin Rectangle in the
	// border's own colour, which is what the renderer's rule lookup keys on.
	rule_rows: [16]i32 = {}
	n_rules: int = 0
	y = FRAME_PAD
	for y < FRAME_H-1 {
		if glyph_at(FRAME_PAD, y) == '─' && n_rules < len(rule_rows) {
			rule_rows[n_rules] = y
			n_rules += 1
		}
		y += 1
	}
	check("betweenChildren rendered as ruled glyphs (2 gaps -> 2 rules)", n_rules == 2,
		fmt.tprintf("interior ─ rows: {} (n={})", rule_rows[0:n_rules], n_rules))
	check("renderer counted the rules", stats.rules == 2, fmt.tprintf("stats.rules={}", stats.rules))
	if n_rules > 0 {
		rr := rule_rows[0]
		check("rule uses the border colour", cell_at(FRAME_PAD, rr).fg == border_attr,
			fmt.tprintf("got 0x{:08X} want 0x{:08X}", cell_at(FRAME_PAD, rr).fg, border_attr))
		check("rule did not erase the border's left side", glyph_at(0, rr) == '│',
			fmt.tprintf("row {} col 0 -> {}", rr, glyph_name(glyph_at(0, rr))))
		check("rule did not erase the border's right side", glyph_at(FRAME_W-1, rr) == '│',
			fmt.tprintf("row {} col {} -> {}", rr, FRAME_W-1, glyph_name(glyph_at(FRAME_W-1, rr))))
	}

	// --- 3. Text placement + colour ------------------------------------------
	_, head_box := find_text_loc(cmds, "HEADER")
	check("HEADER landed at Clay's boundingBox origin",
		glyph_at(head_box.x, head_box.y) == 'H' && head_box.x == FRAME_PAD && head_box.y == FRAME_PAD,
		fmt.tprintf("clay box=({},{} {})x{} cell=({},{}) -> {}",
			head_box.x, head_box.y, head_box.w, head_box.h, head_box.x, head_box.y,
			glyph_name(glyph_at(head_box.x, head_box.y))))
	check("HEADER colour", cell_at(head_box.x, head_box.y).fg == text_attr,
		fmt.tprintf("got 0x{:08X} want 0x{:08X}", cell_at(head_box.x, head_box.y).fg, text_attr))
	check("panel background reaches the cell under the text", cell_at(head_box.x, head_box.y).bg == bg_attr,
		fmt.tprintf("got 0x{:08X} want 0x{:08X}", cell_at(head_box.x, head_box.y).bg, bg_attr))

	// --- 4. Alignment, straight from Clay's x --------------------------------
	body := "Body 中文😀 mix"
	_, body_box := find_text_loc(cmds, body)
	inner_w := FRAME_W - 2*FRAME_PAD
	body_w := cols(body)
	want_centre := render.round_cell((f32(inner_w) - f32(body_w)) / 2.0) + FRAME_PAD
	check("clay centred the text (bbox x == centre arithmetic)", body_box.x == want_centre,
		fmt.tprintf("clay x={} want {} (text {} cols inside {} cols)", body_box.x, want_centre, body_w, inner_w))
	check("centred text painted at that column", glyph_at(body_box.x, body_box.y) == 'B',
		fmt.tprintf("({}, {}) -> {}", body_box.x, body_box.y, glyph_name(glyph_at(body_box.x, body_box.y))))
	check("centred text colour", cell_at(body_box.x, body_box.y).fg == accent_attr,
		fmt.tprintf("got 0x{:08X} want 0x{:08X}", cell_at(body_box.x, body_box.y).fg, accent_attr))

	_, foot_box := find_text_loc(cmds, "FOOTER")
	want_right := FRAME_W - FRAME_PAD - cols("FOOTER")
	check("clay right-aligned the text (bbox x == right-edge arithmetic)", foot_box.x == want_right,
		fmt.tprintf("clay x={} want {}", foot_box.x, want_right))
	check("right-aligned text painted at that column", glyph_at(foot_box.x, foot_box.y) == 'F',
		fmt.tprintf("({}, {}) -> {}", foot_box.x, foot_box.y, glyph_name(glyph_at(foot_box.x, foot_box.y))))
	check("right-aligned text colour", cell_at(foot_box.x, foot_box.y).fg == hilite_attr,
		fmt.tprintf("got 0x{:08X} want 0x{:08X}", cell_at(foot_box.x, foot_box.y).fg, hilite_attr))

	// --- 5. Wide glyphs claim their trailing cell ----------------------------
	cjk_x := body_box.x + cols("Body ")
	check("CJK glyph drawn at its computed column", glyph_at(cjk_x, body_box.y) == '中',
		fmt.tprintf("col {} -> {}", cjk_x, glyph_name(glyph_at(cjk_x, body_box.y))))
	check("wide glyph claimed the following cell", glyph_at(cjk_x+1, body_box.y) == ' ',
		fmt.tprintf("col {} -> {} (want a claimed blank)", cjk_x+1, glyph_name(glyph_at(cjk_x+1, body_box.y))))
	check("the claim carries the glyph's own colours",
		cell_at(cjk_x+1, body_box.y).fg == accent_attr && cell_at(cjk_x+1, body_box.y).bg == bg_attr,
		fmt.tprintf("fg=0x{:08X} bg=0x{:08X}", cell_at(cjk_x+1, body_box.y).fg, cell_at(cjk_x+1, body_box.y).bg))
	// 中, 文 and 😀 are each 2 columns -> three claims.
	check("renderer recorded every claim", stats.claimed == 3,
		fmt.tprintf("stats.claimed={} (expected 3: 中 文 😀)", stats.claimed))
	// The emoji is the last wide glyph on the row; its claim must land right after it.
	emoji_x := body_box.x + cols("Body 中文")
	check("emoji drawn at its column", glyph_at(emoji_x, body_box.y) == '😀',
		fmt.tprintf("col {} -> {}", emoji_x, glyph_name(glyph_at(emoji_x, body_box.y))))
	check("emoji trailing cell claimed", glyph_at(emoji_x+1, body_box.y) == ' ',
		fmt.tprintf("col {} -> {}", emoji_x+1, glyph_name(glyph_at(emoji_x+1, body_box.y))))

	dump_rows("rendered frame (back buffer, cell glyphs)", 0, 0, FRAME_W, FRAME_H)

	leave_terminal()
	return !any_failed
}

// ---------------------------------------------------------------------------
// Case: clip
// ---------------------------------------------------------------------------

CLIP_W :: 14
CLIP_H :: 3
OVERFLOW_TEXT :: "This overflowing line is much wider than the clip box and must leak nowhere"

// SENTINEL_FG/BG are painted into every cell by tb_clear(), so "this cell was
// never touched by the renderer" is exactly decidable.
//
// This matters because tb_clear() does NOT zero the buffer: cellbuf_clear() fills
// every cell with a SPACE and the *current clear attrs* (termbox2.h:4113-4121).
// Probing for ch==0 to mean "untouched" is therefore wrong — a freshly cleared
// screen is full of 0x20. Setting a sentinel colour nobody paints is what makes
// the leak test meaningful.
SENTINEL_FG : termbox2.Attr = 0x000A0B0C
SENTINEL_BG : termbox2.Attr = 0x000D0E0F

// first_leak_label names the glyph found at a leaked cell, for the failure detail.
first_leak_label :: proc(x, y: i32) -> string {
	if x < 0 { return "n/a" }
	return glyph_name(glyph_at(x, y))
}

// untouched reports whether the renderer left this cell alone.
untouched :: proc(x, y: i32) -> bool {
	c := cell_at(x, y)
	return c.ch == u32(' ') && c.fg == SENTINEL_FG && c.bg == SENTINEL_BG
}

build_clip :: proc() {
	// A clip container at the origin with one long child that cannot fit inside.
	if clay.UI(clay.ID("clipbox"))({
		layout = {
			sizing = {width = clay.SizingFixed(CLIP_W), height = clay.SizingFixed(CLIP_H)},
			layoutDirection = .TopToBottom,
		},
		clip = {horizontal = true, vertical = true},
	}) {
		clay.Text(OVERFLOW_TEXT, clay.TextElementConfig{textColor = C_TEXT})
	}
}

// case_clip proves the scissor: a ~75-column child inside a 14-column box, with
// every cell outside the box checked to be exactly as tb_clear() left it.
case_clip :: proc() -> bool {
	say("case clip — scissor must contain the overflow")
	if !enter_terminal() { return false }
	if !clay_start() { leave_terminal(); return false }

	termbox2.tb_set_clear_attrs(SENTINEL_FG, SENTINEL_BG)
	termbox2.tb_clear()

	clay.BeginLayout()
	build_clip()
	cmds := clay.EndLayout(0)
	stats := paint_cmds(cmds)
	say(fmt.tprintf("  stats: commands={} text_rows={} glyphs={} hidden={} scissors={} cell_error={}",
		stats.commands, stats.text_rows, stats.glyphs, stats.hidden, stats.scissors, stats.cell_error))

	full := cols(OVERFLOW_TEXT)
	say(fmt.tprintf("  overflow text is {} columns inside a {}-column clip", full, CLIP_W))
	if full <= CLIP_W {
		say("  [FAIL] the fixture is not actually overflowing — the test would pass vacuously")
		any_failed = true
	}
	_, box := find_text_loc(cmds, OVERFLOW_TEXT)
	say(fmt.tprintf("  clay gave the text a {}-column box at ({},{})", box.w, box.x, box.y))

	// 1. The interior really is painted with the right glyphs.
	check("clip interior carries the text",
		glyph_at(0, 0) == 'T' && glyph_at(5, 0) == 'o' && glyph_at(13, 0) == 'i',
		fmt.tprintf("(0,0)={} (5,0)={} (13,0)={}   (want OVE[R]FLOW chars 'T','o','i')",
			glyph_name(glyph_at(0, 0)), glyph_name(glyph_at(5, 0)), glyph_name(glyph_at(13, 0))))
	check("interior painted right up to the clip width", glyph_at(CLIP_W-1, 0) != ' ',
		fmt.tprintf("(col {}, row 0) -> {}", CLIP_W-1, glyph_name(glyph_at(CLIP_W-1, 0))))

	// 2. Past the clip's right edge: not a cell touched, on any row the text ran
	//    into. This is the assertion the whole scissor exists for.
	scanned := 0
	touched := 0
	fx: i32 = -1
	fy: i32 = -1
	row: i32 = 0
	for row < CLIP_H {
		x: i32 = CLIP_W
		for x < termbox2.tb_width() {
			scanned += 1
			if !untouched(x, row) {
				touched += 1
				if fx < 0 { fx = x; fy = row }
			}
			x += 1
		}
		row += 1
	}
	check("nothing painted past the clip's right edge", touched == 0,
		fmt.tprintf("{}/{} cells outside were painted (first at ({},{}) -> {})",
			touched, scanned, fx, fy, first_leak_label(fx, fy)))

	// 3. Below the clip: still nothing.
	scanned = 0
	touched = 0
	bx: i32 = -1
	by: i32 = -1
	y: i32 = CLIP_H
	for y < termbox2.tb_height() {
		x: i32 = 0
		for x < termbox2.tb_width() {
			scanned += 1
			if !untouched(x, y) {
				touched += 1
				if bx < 0 { bx = x; by = y }
			}
			x += 1
		}
		y += 1
	}
	check("nothing painted below the clip", touched == 0,
		fmt.tprintf("{}/{} cells below row {} were painted (first at ({},{}) -> {})",
			touched, scanned, CLIP_H-1, bx, by, first_leak_label(bx, by)))

	// 4. To the left of / above the clip in this fixture is the clip itself, so
	//    the control is that the guard is a real intersection and not just a
	//    "draw the first N columns" hack: the interior must stop at exactly
	//    CLIP_W, which check 2 proves from the other side.
	check("the clip is a real intersection, not a prefix draw",
		untouched(CLIP_W, 0) && !untouched(CLIP_W-1, 0),
		fmt.tprintf("col {} untouched={} col {} untouched={}",
			CLIP_W, untouched(CLIP_W, 0), CLIP_W-1, untouched(CLIP_W-1, 0)))

	check("the scissor commands were consumed", stats.scissors >= 2,
		fmt.tprintf("stats.scissors={} (start + end)", stats.scissors))

	dump_rows("clip container painted; everything right/below must be blank",
		0, 0, CLIP_W+20, CLIP_H+3)

	leave_terminal()
	return !any_failed
}

// ---------------------------------------------------------------------------
// Case: clay-error
// ---------------------------------------------------------------------------

build_duplicate :: proc() {
	if clay.UI(clay.ID("dup-id"))({layout = {sizing = {width = clay.SizingFixed(20)}}}) {
		clay.Text("first", clay.TextElementConfig{textColor = C_TEXT})
	}
	// Same id, same level: Clay's hash map sees a collision and reports it.
	if clay.UI(clay.ID("dup-id"))({layout = {sizing = {width = clay.SizingFixed(20)}}}) {
		clay.Text("second", clay.TextElementConfig{textColor = C_TEXT})
	}
}

// case_clay_error proves T2.3: Clay's default handler swallows everything, so a
// duplicate id must land in our ring buffer inside the C frame and still be
// readable, intact, afterwards.
case_clay_error :: proc() -> bool {
	say("case clay-error — duplicate id survives the C frame")
	if !enter_terminal() { return false }
	if !clay_start() { leave_terminal(); return false }

	render.errors_clear()
	check("no errors before the frame", render.errors_total() == 0,
		fmt.tprintf("total={}", render.errors_total()))

	termbox2.tb_clear()
	render_and_present(build_duplicate)

	total := render.errors_total()
	check("the duplicate id was reported", total > 0, fmt.tprintf("total={}", total))

	msg := render.errors_latest()
	say(fmt.tprintf("  reported: {}", msg))
	check("message is non-empty", len(msg) > 0, fmt.tprintf("len={}", len(msg)))
	check("message survived intact outside the C frame",
		len(msg) > 8 && render.errors_count() >= 1,
		fmt.tprintf("retained={} len={}", render.errors_count(), len(msg)))

	// And it must be identifiable as a duplicate-id class error, not just noise.
	is_dup := false
	i := 0
	for i < render.errors_count() {
		one := render.errors_at(i)
		if str_contains_ignore_case(one, "already") || str_contains_ignore_case(one, "duplicate") {
			is_dup = true
		}
		i += 1
	}
	check("message reads as a duplicate-id problem", is_dup, fmt.tprintf("\"{}\"", msg))

	// The kind mapping must work — the raw ordinal is what we key on, because
	// clay.odin's ErrorType enum does not name all of clay.h's members.
	recs := render.errors_records()
	kind_ok := len(recs) > 0
	first_kind := ""
	if len(recs) > 0 { first_kind = recs[0].kind }
	for r in recs {
		if r.kind != "DuplicateId" { kind_ok = false }
	}
	check("error kind mapped from the ordinal", kind_ok,
		fmt.tprintf("all {} records have kind DuplicateId (first={})", len(recs), first_kind))

	// Truncation must be honest, not a silent cut or an overrun. A synthetic
	// oversized message goes straight through the same handler Clay uses.
	render.errors_clear()
	long := make_long_message(render.ERROR_MESSAGE_CAPACITY * 3)
	render.errors_handler(clay.ErrorData{
		errorType = clay.ErrorType.DuplicateId,
		errorText = clay.MakeString(long),
		userData = nil,
	})
	trunc := render.errors_records()[0]
	tlen := len(render.record_message(&trunc))
	check("an oversized message is truncated to capacity",
		tlen <= render.ERROR_MESSAGE_CAPACITY && trunc.truncated,
		fmt.tprintf("len={} cap={} truncated={}", tlen, render.ERROR_MESSAGE_CAPACITY, trunc.truncated))
	check("truncated message is still readable",
		tlen > render.ERROR_MESSAGE_CAPACITY/2,
		fmt.tprintf("kept {} of {} bytes", tlen, len(long)))
	delete(long)

	// An unknown ordinal must degrade, never mislabel or trap.
	render.errors_clear()
	render.errors_handler(clay.ErrorData{
		errorType = cast(clay.ErrorType)(200),
		errorText = clay.MakeString("future clay error"),
		userData = nil,
	})
	check("an unmapped ordinal degrades to UnknownError",
		render.errors_records()[0].kind == "UnknownError",
		fmt.tprintf("kind={}", render.errors_records()[0].kind))

	// The plan's own acceptance case: an element opened and never closed must be
	// reported too, not just duplicate ids.
	render.errors_clear()
	clay.BeginLayout()
	// Deliberately unbalanced. Clay_EndLayout closes one element itself, so two
	// opens with zero closes is what leaves the stack non-empty and trips
	// UNBALANCED_OPEN_CLOSE (clay.h:4448-4457).
	clay._OpenElement()
	clay._OpenElement()
	unbalanced := clay.EndLayout(0)
	_ = unbalanced
	say(fmt.tprintf("  unbalanced frame: total={} latest={}", render.errors_total(), render.errors_latest()))
	check("an unclosed element is reported too", render.errors_total() > 0,
		fmt.tprintf("total={} latest={}", render.errors_total(), render.errors_latest()))
	kinds := ""
	buf: [dynamic]byte
	for r in render.errors_records() {
		push_str(&buf, r.kind)
		push_str(&buf, ",")
	}
	kinds = string(buf[:])
	check("unbalanced open maps to UnbalancedOpenClose",
		str_contains_ignore_case(kinds, "UnbalancedOpenClose"),
		fmt.tprintf("kinds={}", kinds))

	// The ring must be bounded: never let a hostile/error-storm grow memory.
	before := render.errors_count()
	k := 0
	for k < 40 {
		render_and_present(build_duplicate)
		k += 1
	}
	say(fmt.tprintf("  after 40 more duplicate frames: retained={} total={} dropped={}",
		render.errors_count(), render.errors_total(), render.errors_dropped()))
	check("retention stays bounded (no unbounded growth)",
		render.errors_count() <= 8 && render.errors_count() >= before,
		fmt.tprintf("retained={} (window is 8)", render.errors_count()))
	check("overflow is counted, not hidden", render.errors_dropped() > 0,
		fmt.tprintf("dropped={}", render.errors_dropped()))

	leave_terminal()
	return !any_failed
}

count_runes :: proc(s: string) -> int {
	n := 0
	for _ in s { n += 1 }
	return n
}

make_long_message :: proc(n: int) -> string {
	sb: [dynamic]byte
	i := 0
	for i < n {
		append(&sb, byte('x'))
		i += 1
	}
	return string(sb[:])
}

str_contains_ignore_case :: proc(haystack: string, needle: string) -> bool {
	if len(needle) == 0 { return true }
	if len(haystack) < len(needle) { return false }
	i := 0
	for i + len(needle) <= len(haystack) {
		j := 0
		for j < len(needle) {
			a := haystack[i+j]
			b := needle[j]
			if a >= 'A' && a <= 'Z' { a += 32 }
			if b >= 'A' && b <= 'Z' { b += 32 }
			if a != b { break }
			j += 1
		}
		if j == len(needle) { return true }
		i += 1
	}
	return false
}

// ---------------------------------------------------------------------------
// Case: layout-dump
// ---------------------------------------------------------------------------

case_layout_dump :: proc() -> bool {
	say("case layout-dump — the renderer's input, verbatim")
	if !enter_terminal() { return false }
	if !clay_start() { leave_terminal(); return false }
	termbox2.tb_clear()

	clay.BeginLayout()
	build_frame()
	cmds := clay.EndLayout(0)

	i := 0
	for i < int(cmds.length) {
		c := cmds.internalArray[i]
		kind := fmt.tprintf("{}", c.commandType)
		detail := ""
		if c.commandType == .Text {
			t := c.renderData.text
			detail = fmt.tprintf(" \"{}\" ({} cols)",
				string(mem.byte_slice(t.stringContents.chars, int(t.stringContents.length))),
				cols(string(mem.byte_slice(t.stringContents.chars, int(t.stringContents.length)))))
		} else if c.commandType == .Border {
			b := c.renderData.border
			detail = fmt.tprintf(" L={} R={} T={} B={} betweenChildren={}",
				b.width.left, b.width.right, b.width.top, b.width.bottom, b.width.betweenChildren)
		}
		fmt.printf("  %-16v (%v,%v) %vx%v%v\n", kind, c.boundingBox.x, c.boundingBox.y,
			c.boundingBox.width, c.boundingBox.height, detail)
		i += 1
	}
	termbox2.tb_present()
	leave_terminal()
	return true
}
