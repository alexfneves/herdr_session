package probe

// render_fixture.odin — WHAT the render suite paints, and why each fixture is
// shaped the way it is.
//
// These layouts are SHARED between the cell-level tests (`render_cell_test`)
// and the wire-level tests (`render_wire_test`) deliberately. The wire
// assertion is "the bytes of THIS frame reached the tty". If each file carried
// its own copy of the layout, the wire test could be proving that a *different*
// picture left the process than the one the back-buffer grid was checked
// against, and both files would still read green. One fixture, two vantage
// points, one source of truth.
//
// Ported from `src/render_cases.odin` (the pre-migration driver). The shapes
// are copied rather than re-invented: the expected cell coordinates in
// `render_cell_test` are derived from *Clay's own* reported bounding boxes for
// exactly these layouts, so changing a fixture means re-deriving the
// expectations, which is the point.

import clay "../../clay-odin"
import tb "../../vendor/termbox2-odin"

//-----------------------------------------------------------------------------
// measure — the display-column proof table (T2.1)
//-----------------------------------------------------------------------------

// Render_Measure_Case is one row of the T2.1 proof table: the same input
// measured three ways, only one of which is the number a terminal cares about.
Render_Measure_Case :: struct {
	text  : string, // utf8 input
	bytes : int,    // how long it is in memory
	runes : int,    // how many code points
	want  : i32,    // how many COLUMNS it must occupy
	note  : string,
}

RENDER_MEASURE_CASES := []Render_Measure_Case{
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

// render_count_runes counts code points, not bytes. The table above asserts
// bytes/runes/columns as THREE DIFFERENT numbers, so the rune count has to be
// computed rather than asserted-by-eye or the row cannot falsify anything.
render_count_runes :: proc(s: string) -> int {
	n := 0
	for _ in s { n += 1 }
	return n
}

//-----------------------------------------------------------------------------
// The standard frame
//-----------------------------------------------------------------------------

// Frame colours. Deliberately distinct so a mis-wired channel is visible: if
// Clay colours were read as 0..1 instead of 0..255 everything would land
// black, and if fg/bg were swapped the corner would read as the panel.
RENDER_C_BG     : clay.Color = clay.Color{16, 20, 28, 255}
RENDER_C_BORDER : clay.Color = clay.Color{255, 60, 60, 255}
RENDER_C_TEXT   : clay.Color = clay.Color{220, 220, 220, 255}
RENDER_C_ACCENT : clay.Color = clay.Color{60, 200, 120, 255}
RENDER_C_HILITE : clay.Color = clay.Color{40, 90, 200, 255}

RENDER_FRAME_W   :: 44
RENDER_FRAME_H   :: 12
RENDER_FRAME_PAD :: 1
// RENDER_FRAME_GAP is this FIXTURE's childGap, not the product's. It is 2
// because this picture deliberately exercises Clay's `betweenChildren`
// divider path, which needs a gap to place its rule in (at 1 the rule lands on
// the next child's first row — the trap `render_border` documents).
//
// It therefore does NOT mirror src/ui/frame.odin's FRAME_GAP any more: RCH-10
// change 6 moved the product's spine off betweenChildren onto dedicated
// one-row rule elements and set the root childGap to 0. The two constants now
// describe different things on purpose — if you are here looking for the reason
// the numbers differ, that is it, and if you change one do NOT assume the other
// should follow.
RENDER_FRAME_GAP :: 2

// render_build_frame is the standard picture: a bordered panel, one left-aligned
// text row, one centred row containing wide glyphs, one right-aligned row. That
// is the minimum layout that exercises all four border sides, the
// betweenChildren divider rule, both alignment axes, and a colour per channel.
render_build_frame :: proc() {
	if clay.UI(clay.ID("frame"))({
		layout = {
			sizing          = {width = clay.SizingFixed(RENDER_FRAME_W), height = clay.SizingFixed(RENDER_FRAME_H)},
			padding         = clay.PaddingAll(RENDER_FRAME_PAD),
			childGap        = RENDER_FRAME_GAP,
			layoutDirection = .TopToBottom,
		},
		backgroundColor = RENDER_C_BG,
		border          = {color = RENDER_C_BORDER, width = clay.BorderAll(1)},
	}) {
		clay.Text("HEADER", clay.TextElementConfig{textColor = RENDER_C_TEXT})

		// A row, so childAlignment can push the text to the middle. A TEXT
		// command fits its content, so alignment only shows up in boundingBox.x
		// via the *parent's* childAlignment.
		if clay.UI(clay.ID("mid"))({
			layout = {
				sizing         = {width = clay.SizingGrow()},
				childAlignment = {x = .Center},
			},
		}) {
			clay.Text(RENDER_BODY_TEXT, clay.TextElementConfig{textColor = RENDER_C_ACCENT})
		}

		if clay.UI(clay.ID("foot"))({
			layout = {
				sizing         = {width = clay.SizingGrow()},
				childAlignment = {x = .Right},
			},
		}) {
			clay.Text("FOOTER", clay.TextElementConfig{textColor = RENDER_C_HILITE})
		}
	}
}

// RENDER_BODY_TEXT is the centred row. It carries CJK, a space-separated
// second CJK glyph and an emoji so a single row proves: centring arithmetic
// over WIDE columns, each wide glyph claiming its trailing cell, and that all
// three multi-byte classes survive the encoder into the stream.
RENDER_BODY_TEXT :: "Body 中文😀 mix"

//-----------------------------------------------------------------------------
// The clip fixture
//-----------------------------------------------------------------------------

RENDER_CLIP_W :: 14
RENDER_CLIP_H :: 3

RENDER_OVERFLOW_TEXT :: "This overflowing line is much wider than the clip box and must leak nowhere"

// RENDER_SENTINEL_FG/BG are painted into every cell by tb_clear(), so "this
// cell was never touched by the renderer" is exactly decidable.
//
// This matters because tb_clear() does NOT zero the buffer: cellbuf_clear()
// fills every cell with a SPACE and the *current clear attrs* (termbox2.h:4113-
// 4121). Probing for ch==0 to mean "untouched" is therefore wrong — a freshly
// cleared screen is full of 0x20. Setting a sentinel colour nobody paints is
// what makes the leak test meaningful instead of tautological.
RENDER_SENTINEL_FG : tb.Attr = 0x000A0B0C
RENDER_SENTINEL_BG : tb.Attr = 0x000D0E0F

// render_build_clip is a clip container at the origin with one long child that
// cannot fit inside it, in both axes.
render_build_clip :: proc() {
	if clay.UI(clay.ID("clipbox"))({
		layout = {
			sizing          = {width = clay.SizingFixed(RENDER_CLIP_W), height = clay.SizingFixed(RENDER_CLIP_H)},
			layoutDirection = .TopToBottom,
		},
		clip = {horizontal = true, vertical = true},
	}) {
		clay.Text(RENDER_OVERFLOW_TEXT, clay.TextElementConfig{textColor = RENDER_C_TEXT})
	}
}

//-----------------------------------------------------------------------------
// The duplicate-id fixture
//-----------------------------------------------------------------------------

// render_build_duplicate declares the same id twice at the same level. Clay's
// hash map sees the collision and reports it — and the whole point of the
// fixture is that Clay's DEFAULT handler is a no-op, so a message arriving
// outside the C frame can only have come from ours.
render_build_duplicate :: proc() {
	if clay.UI(clay.ID("dup-id"))({layout = {sizing = {width = clay.SizingFixed(20)}}}) {
		clay.Text("first", clay.TextElementConfig{textColor = RENDER_C_TEXT})
	}
	// Same id, same level: Clay's hash map sees a collision and reports it.
	if clay.UI(clay.ID("dup-id"))({layout = {sizing = {width = clay.SizingFixed(20)}}}) {
		clay.Text("second", clay.TextElementConfig{textColor = RENDER_C_TEXT})
	}
}

//-----------------------------------------------------------------------------
// Small string helpers the error-port needs (core:regex does not exist)
//-----------------------------------------------------------------------------

// render_contains_ci is a case-insensitive substring test over bytes. Used for
// the error-message classification checks, which must match Clay's own prose
// without depending on its casing.
render_contains_ci :: proc(haystack: string, needle: string) -> bool {
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

// render_make_long builds an n-byte message to overflow ERROR_MESSAGE_CAPACITY.
render_make_long :: proc(n: int) -> string {
	buf : [dynamic]u8
	for _ in 0 ..< n {
		append(&buf, byte('x'))
	}
	return string(buf[:])
}
