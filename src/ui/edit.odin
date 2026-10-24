package ui

// ============================================================================
// ui.edit — a single-line editor whose caret lives in DISPLAY COLUMNS (T5.3)
//
// The one bug this file exists to prevent is treating the caret as a byte offset
// into the buffer. "世" is 3 bytes and 2 cells; "😀" is 4 bytes and 2 cells. A
// byte-offset caret sits five cells away from where those glyphs actually end, so
// the caret drifts left of the text and every wide rune makes it worse. Here:
//
//   * the buffer is UTF-8 bytes,
//   * the caret is a BYTE index (so inserting mid-string is cheap), and
//   * the caret's SCREEN position is always DERIVED — edit_caret_col() is the
//     display width of the prefix, measured through the same tb_wcwidth-backed
//     path Clay uses. Nothing else computes it, and nothing caches it.
//
// The same rule protects the visible window: edit_view cuts the shown text on
// CELL boundaries, so a 2-cell rune is never sliced in half and the column the
// user sees always matches the column the buffer contains.
//
// ── PASTE IS SANITISED, NOT TRUSTED ─────────────────────────────────────────
// A paste is a burst of bytes that may carry CR/LF/TAB, a bare ESC, full CSI
// sequences, DEL or C1 controls. Whatever reaches the buffer gets rendered as
// cells, so an embedded "\x1b[31m" would otherwise *display* as text and a bare
// ESC could be read back by a naive input path as "back". edit_paste accepts
// only runes that are printable AND at least one cell wide, which drops: control
// characters (incl. ESC 0x1b, DEL 0x7f, C1 0x80..0x9f), zero-width runes
// (combining marks and variation selectors that render as nothing while still
// eating the buffer) and invalid/overlong UTF-8. What survives is exactly what
// can be drawn.
//
// ── WHY THE CARET IS A CLAY ELEMENT ─────────────────────────────────────────
// The caret is a real element in the Clay tree (a one-cell Text of '█'), not a
// tb_set_cell smeared over the layout. That keeps the frame rule — every glyph
// arrives through Clay -> render.paint — true, keeps the caret clipped by
// whatever scissor the enclosing section is under, and lets Clay lay the row out
// as [prefix][caret][suffix] like any other row.
//
// ── WHY A FIXED BUFFER ───────────────────────────────────────────────────────
// Editing means inserting and deleting in the middle, and `delete(arr[i:j])` on a
// [dynamic]byte CRASHES this toolchain (verified: SIGSEGV, core dumped). A fixed
// array with an explicit length plus two hand-rolled shift helpers has no such
// cliff, never reallocates on the render path, and gives a hard cap on how long
// one line of input can get.
// ============================================================================

import clay "../../clay-odin"
import tb "../../vendor/termbox2-odin"

import "core:unicode/utf8"

// CARET_GLYPH is a one-cell full block: it fills the cell it sits on, so it
// stays visible against any background and cannot be missed the way a one-pixel
// bar is on a high-DPI terminal.
CARET_GLYPH :: '█'

// CARET_TEXT is the same glyph as a string, for the text element.
CARET_TEXT :: "█"

// EDIT_MAX caps one line of input. Generous for a filter or a session name, and a
// hard bound on what a single paste can put on screen.
EDIT_MAX :: 1024

// Edit is the editor state. `caret` is a BYTE index into buf; every screen
// position is derived from it, never the other way round.
Edit :: struct {
	buf : [EDIT_MAX]u8,
	len : int, // bytes in use
	caret : int, // byte index, 0 <= caret <= len
}

edit_init :: proc(e: ^Edit) {
	e.len = 0
	e.caret = 0
}

edit_clear :: proc(e: ^Edit) {
	e.len = 0
	e.caret = 0
}

edit_text :: proc(e: ^Edit) -> string {
	if e.len <= 0 {
		return ""
	}
	return string(e.buf[0:e.len])
}

edit_is_empty :: proc(e: ^Edit) -> bool {
	return e.len == 0
}

// ── buffer surgery (hand-rolled; see the fixed-buffer note above) ────────────

insert_bytes :: proc(e: ^Edit, at: int, s: []u8) -> bool {
	n := len(s)
	if n == 0 {
		return true
	}
	if e.len+n > EDIT_MAX {
		return false
	}
	if at < 0 || at > e.len {
		return false
	}
	tail := e.len - at
	i := 0
	for i < tail {
		e.buf[at+n+i] = e.buf[at+i]
		i += 1
	}
	i = 0
	for i < n {
		e.buf[at+i] = s[i]
		i += 1
	}
	e.len += n
	return true
}

remove_bytes :: proc(e: ^Edit, at: int, count: int) {
	want := count
	if at < 0 || at >= e.len {
		return
	}
	if at+want > e.len {
		want = e.len - at
	}
	tail := e.len - (at + want)
	i := 0
	for i < tail {
		e.buf[at+i] = e.buf[at+want+i]
		i += 1
	}
	e.len -= want
	if e.caret > e.len {
		e.caret = e.len
	}
}

// ── what may enter the buffer ───────────────────────────────────────────────
//
// Three independent gates, because each catches a different class of junk:
//   explicit ranges -> C0 controls (incl. ESC), DEL, C1 controls
//   tb_iswprint     -> anything termbox itself refuses to render
//   width >= 1      -> zero-width runes (combining marks, variation selectors)
edit_is_drawable :: proc(r: rune) -> bool {
	if r < 0x20 || r == 0x7f {
		return false
	}
	if r >= 0x80 && r <= 0x9f {
		return false
	}
	if tb.tb_iswprint(u32(r)) == 0 {
		return false
	}
	return cell_cols(r) >= 1
}

// edit_insert_rune inserts one drawable rune at the caret. Returns false and
// changes nothing when the rune is not drawable or the line is full, so the
// caller can tell "rejected" apart from "inserted".
edit_insert_rune :: proc(e: ^Edit, r: rune) -> bool {
	if !edit_is_drawable(r) {
		return false
	}
	tmp, n := utf8.encode_rune(r)
	if n <= 0 {
		return false
	}
	at := e.caret
	if at < 0 {
		at = 0
	}
	if at > e.len {
		at = e.len
	}
	if !insert_bytes(e, at, tmp[0:n]) {
		return false
	}
	e.caret = at + n
	return true
}

// edit_paste pushes a paste burst through the sanitiser and inserts what
// survives. Returns the number of RUNES accepted, so the caller can report
// "nothing usable" without reading the buffer.
edit_paste :: proc(e: ^Edit, pasted: string) -> int {
	accepted := 0
	i := 0
	for i < len(pasted) {
		// Whole escape sequences are dropped, not just the ESC byte. A filter
		// field left holding "[200~" is worse than one holding nothing: the
		// leftovers read as user content. An introducer (ESC + [ ] P or O)
		// skips forward to the sequence's final byte (0x40..0x7E).
		b := pasted[i]
		if b == 0x1b {
			if i+1 < len(pasted) && (pasted[i+1] == '[' || pasted[i+1] == ']' ||
				pasted[i+1] == 'P' || pasted[i+1] == 'O') {
				j := i + 2
				for j < len(pasted) && !(pasted[j] >= 0x40 && pasted[j] <= 0x7e) {
					j += 1
				}
				i = j + 1
				continue
			}
			i += 1
			continue
		}
		// Control characters and NUL never reach the buffer either.
		if b <= 0x1f || b == 0x7f {
			i += 1
			continue
		}
		r, size := utf8.decode_rune_in_string(pasted[i:])
		if r == utf8.RUNE_ERROR || size <= 0 {
			// Invalid UTF-8: skip ONE byte and keep going rather than dropping
			// the rest of the paste.
			i += 1
			continue
		}
		if edit_insert_rune(e, r) {
			accepted += 1
		}
		i += size
	}
	return accepted
}

// edit_backspace deletes the WHOLE rune before the caret. Dropping a single byte
// of a 3-byte CJK rune would leave a broken sequence that renders as garbage, so
// the rune boundary is found first and its full byte length is removed.
edit_backspace :: proc(e: ^Edit) -> bool {
	if e.caret <= 0 || e.len == 0 {
		return false
	}
	_, n := utf8.decode_last_rune_in_string(string(e.buf[0:e.caret]))
	if n <= 0 {
		n = 1 // undecodable tail: drop exactly one byte so the field stays usable
	}
	if n > e.caret {
		n = e.caret
	}
	start := e.caret - n
	remove_bytes(e, start, n)
	e.caret = start
	return true
}

// edit_delete_forward removes the whole rune AFTER the caret — the same
// rune-boundary rule as backspace, in the other direction.
edit_delete_forward :: proc(e: ^Edit) -> bool {
	if e.caret >= e.len {
		return false
	}
	_, n := utf8.decode_rune_in_string(string(e.buf[e.caret:e.len]))
	if n <= 0 {
		n = 1
	}
	remove_bytes(e, e.caret, n)
	return true
}

// edit_left / edit_right move the caret by ONE WHOLE RUNE. Stepping a byte at a
// time would stop inside a multi-byte rune, where no display column can be
// derived from the caret at all.
edit_left :: proc(e: ^Edit) -> bool {
	if e.caret <= 0 {
		return false
	}
	_, n := utf8.decode_last_rune_in_string(string(e.buf[0:e.caret]))
	if n <= 0 {
		n = 1
	}
	e.caret -= n
	if e.caret < 0 {
		e.caret = 0
	}
	return true
}

edit_right :: proc(e: ^Edit) -> bool {
	if e.caret >= e.len {
		return false
	}
	_, n := utf8.decode_rune_in_string(string(e.buf[e.caret:e.len]))
	if n <= 0 {
		n = 1
	}
	e.caret += n
	if e.caret > e.len {
		e.caret = e.len
	}
	return true
}

// ── the derived caret column (the whole point) ──────────────────────────────

// edit_caret_col returns the caret's DISPLAY COLUMN: the terminal-cell width of
// every rune before the caret. Never len(buf), never the byte index.
edit_caret_col :: proc(e: ^Edit) -> i32 {
	if e.caret <= 0 || e.len == 0 {
		return 0
	}
	return text_cols(string(e.buf[0:e.caret]))
}

// edit_width is the whole buffer's display width.
edit_width :: proc(e: ^Edit) -> i32 {
	return text_cols(edit_text(e))
}

// Edit_View is everything needed to draw one line of editor inside `width`
// cells. `scroll` is the left-hand cut in DISPLAY COLUMNS, chosen so the caret
// cell always lands inside the window.
Edit_View :: struct {
	prefix : string, // visible text before the caret
	suffix : string, // visible text after the caret
	caret_x : i32, // caret column WITHIN the window (0..width-1)
	scroll : i32, // columns cut off the left
}

edit_view :: proc(e: ^Edit, width: i32) -> Edit_View {
	v := Edit_View{}
	if width <= 0 {
		return v
	}
	caret_col := edit_caret_col(e)
	full := edit_width(e)

	// Scroll only when we must: the caret cell stays inside [0, width-1].
	scroll: i32 = 0
	if caret_col >= width {
		scroll = caret_col - width + 1
	}
	// Never scroll past the end of the text, so a shrinking terminal can never
	// reveal columns that do not exist.
	max_scroll := full - width + 1
	if max_scroll < 0 {
		max_scroll = 0
	}
	if scroll > max_scroll {
		scroll = max_scroll
	}
	if scroll < 0 {
		scroll = 0
	}

	prefix_full := ""
	if e.caret > 0 && e.caret <= e.len {
		prefix_full = string(e.buf[0:e.caret])
	}
	suffix_full := ""
	if e.caret < e.len {
		suffix_full = string(e.buf[e.caret:e.len])
	}

	v.scroll = scroll
	v.caret_x = caret_col - scroll
	v.prefix = window_cols(prefix_full, scroll, v.caret_x)
	rest := width - v.caret_x - 1
	if rest < 0 {
		rest = 0
	}
	v.suffix = window_cols(suffix_full, 0, rest)
	return v
}

// edit_paint draws one line of editor as [prefix][caret][suffix]. All three are
// ordinary Clay text elements, so the caret obeys whatever scissor the enclosing
// section is under.
edit_paint :: proc(e: ^Edit, id: string, width: i32, pal: ^Palette) {
	v := edit_view(e, width)
	if clay.UI(clay.ID(id))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingGrow(),
				height = clay.SizingFixed(1),
			},
			layoutDirection = clay.LayoutDirection.LeftToRight,
		},
	}) {
		if len(v.prefix) > 0 {
			clay.Text(v.prefix, clay.TextElementConfig{textColor = pal.fg})
		}
		clay.Text(CARET_TEXT, clay.TextElementConfig{textColor = pal.caret})
		if len(v.suffix) > 0 {
			clay.Text(v.suffix, clay.TextElementConfig{textColor = pal.fg})
		}
	}
}
