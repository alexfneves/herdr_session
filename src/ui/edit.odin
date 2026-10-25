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
// The caret is a real element in the Clay tree (a container holding one Text),
// not a tb_set_cell smeared over the layout. That keeps the frame rule — every
// glyph arrives through Clay -> render.paint — true, keeps the caret clipped by
// whatever scissor the enclosing section is under, and lets Clay lay the row out
// as [prefix][caret][suffix] like any other row.
//
// ── THE CARET OVERLAYS THE CHARACTER IT SITS ON (IT IS NOT AN EXTRA CELL) ────
// The caret is drawn OVER the glyph it precedes. The caret element is exactly as
// wide as that glyph (1 cell for a narrow rune, 2 for a wide CJK/emoji rune) and
// paints THAT CHARACTER — the real one, from the buffer — in `caret_fg` on
// `caret_bg`. The prefix and the suffix do not paint it again: every glyph in
// the field is drawn exactly once. Consequences:
//
//   * moving the caret left/right reflows NOTHING. The text after the caret does
//     not slide a cell right when the caret enters the field, and sliding back
//     and forth cannot shuffle the row.
//   * the whole painted field is `text_cols(buffer)` cells wide, plus exactly
//     ONE extra cell only when the caret sits at the END of the buffer — where
//     there is no glyph to overlay, so the caret paints CARET_GLYPH ('█') and
//     owns that cell outright.
//   * the caret element is `edit_caret_cell`'s cell, i.e. where the real
//     terminal cursor lands, which is why "the caret is a real Clay element
//     carrying its own background" still has to hold.
//
// WHY THE GLYPH IS PAINTED AND NEVER LEFT TO THE TERMINAL'S CURSOR
//
// The terminal cursor is kept BLINKING (DECSCUSR `ESC[3 q`) — a hard product
// requirement — and an inverted-cell blink spends half its cycle inverting the
// cell the cursor is on. If the caret cell instead held a bare block and relied
// on the terminal's own cursor overlay to reveal the character underneath, that
// character would VANISH for half of every blink. So the character is painted
// into the caret cell by Clay and is visible in BOTH blink states: with the
// blink off you see the glyph in `caret_fg` on `caret_bg`; with the blink on
// the terminal INVERTS that same cell and the glyph is still there, knocked out
// in the other colour. Removing the glyph to paint a bare block, or trusting
// the cursor overlay to bring it back, breaks the blink requirement and is the
// thing this paragraph exists to prevent.
//
// ── WHY A FIXED BUFFER ───────────────────────────────────────────────────────
// Editing means inserting and deleting in the middle, and `delete(arr[i:j])` on a
// [dynamic]byte CRASHES this toolchain (verified: SIGSEGV, core dumped). A fixed
// array with an explicit length plus two hand-rolled shift helpers has no such
// cliff, never reallocates on the render path, and gives a hard cap on how long
// one line of input can get.
// ============================================================================

import clay "../../clay-odin"
import render "../render"
import tb "../../vendor/termbox2-odin"

import "core:c"
import "core:unicode/utf8"

// CARET_GLYPH is a one-cell full block: it fills the cell it sits on, so it
// stays visible against any background and cannot be missed the way a one-pixel
// bar is on a high-DPI terminal. It is painted ONLY where there is nothing to
// overlay — the caret at the END of the buffer. Mid-field, the caret paints the
// real character under it instead (see the overlay note above).
CARET_GLYPH :: '█'

// CARET_TEXT is the same glyph as a string, for the text element.
CARET_TEXT :: "█"

// CARET_ID_LABEL is the label the caret element's Clay id is derived from.
// LOCAL means parented: inside an editor opened as `hs.tui.name.edit` the caret
// is an element of its own, and a second editor in the same frame can never
// collide with it.
CARET_ID_LABEL :: "caret"

// EDIT_MAX caps one line of input. Generous for a filter or a session name, and a
// hard bound on what a single paste can put on screen.
EDIT_MAX :: 1024

// Edit is the editor state. `caret` is a BYTE index into buf; every screen
// position is derived from it, never the other way round.
Edit :: struct {
	buf : [EDIT_MAX]u8,
	len : int, // bytes in use
	caret : int, // byte index, 0 <= caret <= len

	// caret_id is CLAY'S OWN id for the caret element edit_paint laid out, and
	// caret_laid_out says whether that happened in the frame currently being
	// assembled. Whoever aims the real terminal cursor reads them back through
	// edit_caret_cell after layout. The id is MINTED BY THE PAINT, so it can
	// never name an element this frame did not draw.
	caret_id       : clay.ElementId,
	caret_laid_out : bool,
}

edit_init :: proc(e: ^Edit) {
	e.len = 0
	e.caret = 0
	e.caret_id = clay.ElementId{}
	e.caret_laid_out = false
}

edit_clear :: proc(e: ^Edit) {
	e.len = 0
	e.caret = 0
	e.caret_id = clay.ElementId{}
	e.caret_laid_out = false
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
// cells. `scroll` is the left-hand cut in DISPLAY COLUMNS, chosen so the WHOLE
// caret overlay — both cells of it, when it sits on a wide rune — always lands
// inside the window.
//
// The three pieces tile the visible row with no gaps and no overlaps:
//
//   [prefix][  overlay, painted by the caret element  ][suffix]
//
// `overlay` is the character the caret sits on and is drawn EXACTLY ONCE, by
// the caret. It is not part of `prefix` or `suffix`.
Edit_View :: struct {
	prefix : string, // visible text before the caret
	overlay : string, // the glyph the caret sits ON; "" at end of buffer
	overlay_cols : i32, // cells the caret element occupies — NEVER 0 (1 at end)
	suffix : string, // visible text AFTER the overlay
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

	// The caret claims exactly the cells of the glyph it sits on. At end of
	// buffer there is no glyph: it paints CARET_GLYPH and costs one cell, which
	// is the ONLY case where the field is one cell wider than the text.
	ov_bytes : int = 0
	ov_cols : i32 = 1
	if e.caret < e.len {
		r, n := utf8.decode_rune_in_string(string(e.buf[e.caret:e.len]))
		if n > 0 && r != utf8.RUNE_ERROR {
			w := cell_cols(r)
			if w < 1 {
				w = 1
			}
			ov_bytes = n
			ov_cols = w
			v.overlay = string(e.buf[e.caret : e.caret+n])
		} else {
			// Undecodable byte under the caret: the block stands in for it over
			// the single cell that byte itself measured, so the column arithmetic
			// still adds up against edit_width().
			ov_bytes = 1
			ov_cols = 1
		}
	}
	v.overlay_cols = ov_cols

	// Scroll only when we must: the caret's WHOLE overlay stays inside
	// [0, width-1] — a 2-cell overlay near the right edge scrolls one cell
	// further than a 1-cell one would, so its second cell is never orphaned.
	scroll: i32 = 0
	if caret_col+ov_cols > width {
		scroll = caret_col + ov_cols - width
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
	// A window narrower than the overlaid rune cannot fit the rune at all; never
	// report a negative caret, just let the window's own edge clip the tail of
	// the overlay. The caret's REPORTED cell (its first) is still inside.
	if scroll > caret_col {
		scroll = caret_col
	}
	if scroll < 0 {
		scroll = 0
	}

	prefix_full := ""
	if e.caret > 0 && e.caret <= e.len {
		prefix_full = string(e.buf[0:e.caret])
	}
	suffix_full := ""
	if e.caret+ov_bytes < e.len {
		suffix_full = string(e.buf[e.caret+ov_bytes : e.len])
	}

	v.scroll = scroll
	v.caret_x = caret_col - scroll
	v.prefix = window_cols(prefix_full, scroll, v.caret_x)
	rest := width - v.caret_x - ov_cols
	if rest < 0 {
		rest = 0
	}
	v.suffix = window_cols(suffix_full, 0, rest)
	return v
}

// edit_paint draws one line of editor as [prefix][caret overlay][suffix]. All
// three are ordinary Clay elements, so the caret obeys whatever scissor the
// enclosing section is under.
//
// The caret element's width is v.overlay_cols — the display width of the glyph
// it sits on — and the glyph it paints is that glyph (CARET_TEXT only at end of
// buffer). The overlaid character is drawn HERE and nowhere else, so the row
// never contains it twice and never loses it.
//
// The caret is its OWN element rather than bare text, for two reasons:
//
//  * it carries its own background. The caret is a PAIR — a `caret_fg` glyph
//    knocked out of a `caret_bg` block — and a bare text element has no
//    background of its own. The block has to be a container whose
//    backgroundColor is the caret's cell, and that container is what spans all
//    `overlay_cols` cells of a wide rune.
//  * the caller can find it. Clay records the box it gave the caret; once the
//    frame is laid out edit_caret_cell reads that box back and the real
//    terminal cursor is aimed at the cell Clay itself chose. Nothing predicts
//    the layout, so nothing can drift from it.
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
		// ID_LOCAL parents the id to the open editor, so the caret of
		// `hs.tui.name.edit` and the caret of `hs.tui.pick.filter` are two
		// different elements even though both are labelled "caret".
		cid := clay.ID_LOCAL(CARET_ID_LABEL)
		e.caret_id = cid
		e.caret_laid_out = true
		// The caret paints the character it sits on. At end of buffer there is
		// none, so it paints the block. Either way the glyph is IN the cell, so
		// it survives the blink in both states.
		caret_text := v.overlay
		if len(caret_text) == 0 {
			caret_text = CARET_TEXT
		}
		caret_cols := v.overlay_cols
		if caret_cols < 1 {
			caret_cols = 1
		}
		if clay.UI(cid)({
			layout = clay.LayoutConfig{
				sizing = clay.Sizing{
					width  = clay.SizingFixed(f32(caret_cols)),
					height = clay.SizingFixed(1),
				},
				layoutDirection = clay.LayoutDirection.LeftToRight,
			},
			backgroundColor = pal.caret_bg,
		}) {
			clay.Text(caret_text, clay.TextElementConfig{textColor = pal.caret_fg})
		}
		if len(v.suffix) > 0 {
			clay.Text(v.suffix, clay.TextElementConfig{textColor = pal.fg})
		}
	}
}

// edit_caret_cell returns the terminal CELL the caret occupies in the frame that
// was just laid out, as CLAY reported it — not as anything here recomputed.
//
// False means "this frame has no caret to point at": the editor was never
// painted, or Clay reported nothing for it. That is the caller's signal to HIDE
// the terminal cursor rather than leave it parked on a cell from an older frame.
edit_caret_cell :: proc(e: ^Edit) -> (x, y: i32, ok: bool) {
	if !e.caret_laid_out {
		return 0, 0, false
	}
	d := clay.GetElementData(e.caret_id)
	if !d.found {
		return 0, 0, false
	}
	r := render.snap_box(d.boundingBox)
	if r.w <= 0 || r.h <= 0 {
		return 0, 0, false
	}
	return r.x, r.y, true
}

// CARET_SHAPE_BLINK_BLOCK is DECSCUSR `ESC[3 q` — a BLINKING BLOCK cursor, the
// shape that matches the painted block caret.
//
// Raw bytes because tb_send takes a `rawptr` and Odin will NOT coerce a string
// literal into one (measured: `Cannot convert "\x1b[3 q" to 'rawptr'`).
CARET_SHAPE_BLINK_BLOCK := []u8{0x1b, '[', '3', ' ', 'q'}

// edit_place_cursor points the terminal's REAL cursor at the cell the caret was
// painted into, and asks the terminal for a blinking block to match. Both bytes
// go out on the frame's own flush — see the caller's note on ordering.
//
// This is the ONLY place the caret touches the terminal directly, and it moves
// the cursor without drawing anything: the caret's CELLS still arrive through
// Clay -> render.paint. Which editor owns the caret, and whether to hide the
// cursor instead, is the caller's decision.
edit_place_cursor :: proc(e: ^Edit) -> (x, y: i32, ok: bool) {
	x, y, ok = edit_caret_cell(e)
	if !ok {
		return
	}
	tb.tb_set_cursor(x, y)
	tb.tb_send(raw_data(CARET_SHAPE_BLINK_BLOCK), c.size_t(len(CARET_SHAPE_BLINK_BLOCK)))
	return x, y, true
}
