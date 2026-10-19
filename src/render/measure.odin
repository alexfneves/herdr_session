package render

// Clay's `measure_text` callback, answered in **terminal cells**.
//
// # Units: one Clay layout unit == one terminal cell
//
// Clay thinks in pixels. A terminal thinks in cells. Rather than carry a DPI/scale
// factor through every coordinate, we declare 1 Clay unit = 1 cell at
// initialisation time (`clay.SetLayoutDimensions{cols, rows}`) and answer
// `measure_text` in columns and lines too. Clay's floating-point bounding boxes
// then land almost exactly on the cell grid and the renderer only has to round,
// never scale.
//
// # Cells, not bytes
//
// Clay hands us a UTF-8 slice and asks "how wide is this?". The answer must be the
// number of *display columns*, which is neither the byte count nor the rune count:
//
//	"hello"     5 bytes, 5 runes -> 5 columns
//	"世界"       6 bytes, 2 runes -> 4 columns   (East Asian Wide)
//	"é"  e+U+0301 3 bytes, 2 runes -> 1 column (combining mark is zero-width)
//	"😀"        4 bytes, 1 rune  -> 2 columns   (Emoji Presentation)
//
// We get that for free from termbox2's own table (`tb_wcwidth`), which is the same
// table `tb_present()` uses to lay glyphs out. Measuring with anything else is how
// columns start drifting.
//
// Zero-width results (combining marks) are *counted* as zero columns but are not
// drawable on their own: termbox2 was built without `TB_OPT_EGC`, so a base char
// plus a combining mark cannot be composed into one cell. The renderer drops those
// glyphs, which keeps the column count correct — the accented letter simply renders
// unaccented. U+0000..U+001F and other non-printables measure as the width of
// U+FFFD, matching what the renderer paints for them.
//
// # Height
//
// One line of text is one cell tall, so every measurement returns
// `LINE_HEIGHT_CELLS`. Clay multiplies this by its own wrapped-line count
// (`Clay__CalculateWrappedText`), which is how a 3-line paragraph becomes 3
// cells. Returning anything else would inflate every line of text in the layout.

import clay "../../clay-odin"
import termbox2 "../../vendor/termbox2-odin"

import "core:mem"
import "core:unicode/utf8"

// Height of a single line of text, in cells.
LINE_HEIGHT_CELLS :: f32(1)

#assert(LINE_HEIGHT_CELLS == 1.0, "one line of text is one cell tall")

// Width used for a glyph that has no width of its own (a control character, say).
// This is the width of U+FFFD, the replacement glyph the renderer paints instead.
FALLBACK_WIDTH :: 1

// measure_text is the Clay measurement callback.
//
// It is a `proc "c"` called from inside Clay with no Odin context, therefore no
// allocator: this procedure must stay allocation-free, must not format, and must
// tolerate a nil/empty buffer.
measure_text :: proc "c" (
	text:     clay.StringSlice,
	config:   ^clay.TextElementConfig,
	userData: rawptr,
) -> clay.Dimensions {
	_ = config
	_ = userData

	columns := text_columns(mem.byte_slice(text.chars, int(text.length)))
	return clay.Dimensions{
		width  = f32(columns),
		height = LINE_HEIGHT_CELLS,
	}
}

// text_columns returns the display width of a UTF-8 string in terminal columns.
//
// Multi-line input is measured as its widest line (Clay splits on '\n' before
// asking, but it is cheap to be correct here): returning the sum across lines would
// make a paragraph look as wide as all its lines laid end to end.
text_columns :: proc "contextless" (s: []byte) -> i32 {
	widest: i32 = 0
	current: i32 = 0

	i := 0
	for i < len(s) {
		r, n := utf8.decode_rune(s[i:])
		if n <= 0 {
			// Undecodable byte: consume one and count the replacement glyph.
			current += FALLBACK_WIDTH
			i += 1
			continue
		}
		i += n

		if r == '\n' {
			if current > widest { widest = current }
			current = 0
			continue
		}
		if r == '\t' {
			// No tab stops in a Clay layout. Clay never emits tabs and a tab in a
			// cell buffer renders as a gap of unknown size, so count it as one
			// replacement glyph rather than inventing a tab width.
			current += FALLBACK_WIDTH
			continue
		}

		current += glyph_columns(r)
	}

	if current > widest { widest = current }
	return widest
}

// glyph_columns returns the number of terminal columns `r` occupies.
//
// This is the single source of truth for width in this package: measure_text uses
// it for layout and the renderer uses it for placement, so the two can never
// disagree.
glyph_columns :: proc "contextless" (r: rune) -> i32 {
	if r < 32 || r == 127 {
		return FALLBACK_WIDTH
	}

	w := termbox2.tb_wcwidth(cast(u32)(r))
	if w < 0 {
		return FALLBACK_WIDTH
	}
	return w
}
