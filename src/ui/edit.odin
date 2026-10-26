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
// The caret blinks in the APP now (UIP-5 refinement): the phase lives in this
// struct (see `blink_on` / `blink_at` / `blink_armed` below) and the loop wakes
// once per ~530 ms blink edge to step it. The glyph is painted into the caret
// cell by Clay and is visible in BOTH phase states: phase ON -> the glyph is in
// `caret_fg` on `caret_bg` (the highlighted pair); phase OFF -> the same glyph
// is in the normal pair (`fg` on `bg`). Swapping the two pairs needs no terminal
// inversion, no DECSCUSR, and never loses the character for half of a blink.
//
// The terminal cursor itself is never part of this any more: it is HIDDEN for
// editable fields (`tb_hide_cursor`, ESC[?25l) and never positioned or asked to
// blink.
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

import "core:time"
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

// CARET_BLINK_PERIOD is the app-driven caret blink: how long each phase (ON / OFF)
// lasts, ~530 ms. A phase flip is a blink edge; the loop sleeps until the next one.
CARET_BLINK_PERIOD :: time.Duration(530 * 1_000_000) // 530 ms, in nanoseconds

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

	// App-driven caret blink (UIP-5 refinement): the PHASE the caret is painted
	// in, and the deadline of the next phase flip, plus whether a caret currently
	// owns this editor. The phase lives here (not in the terminal) because the
	// blink must be visible in the frame the renderer paints — a terminal-owned
	// DECSCUSR blink cannot be seen through Clay's colour pairs and cannot be
	// asserted; the app can. `blink_armed` is set by the paint and read back by the
	// loop to decide whether to sleep on the blink at all.
	blink_on    : bool, // phase: true = highlighted (caret pair), false = normal pair
	blink_at    : time.Time, // deadline of the next phase flip
	blink_armed : bool, // a caret currently owns this editor (set by the paint)
}

// edit_init is the fresh-editor reset. The phase starts ON (the caret is
// highlighted) and `blink_armed` is false until a frame paints the caret — an
// editor that has not been painted has no caret to blink.
edit_init :: proc(e: ^Edit) {
	e.len = 0
	e.caret = 0
	e.caret_id = clay.ElementId{}
	e.caret_laid_out = false
	e.blink_on = true
	e.blink_at = time.time_add(time.now(), CARET_BLINK_PERIOD)
	e.blink_armed = false
}

// edit_clear is the buffer reset. It deliberately does NOT touch the blink phase
// or its deadline: clearing the buffer does not clear the caret's blink — the
// phase belongs to the CARET, and whoever re-arms re-arms on the move that
// followed. It only retires the arm, because with no buffer there is no caret.
edit_clear :: proc(e: ^Edit) {
	e.len = 0
	e.caret = 0
	e.caret_id = clay.ElementId{}
	e.caret_laid_out = false
	e.blink_armed = false
}

// edit_blink_reset is the "phase resets to ON" primitive: a caret move or a
// typed character arms the blink again, starting a fresh ON phase whose next
// flip is one CARET_BLINK_PERIOD away. Called by the caret movers and by the
// machine->view sync when the mirrored caret changed.
edit_blink_reset :: proc(e: ^Edit) {
	e.blink_on = true
	e.blink_at = time.time_add(time.now(), CARET_BLINK_PERIOD)
	e.blink_armed = true
}

// edit_blink_due reports whether the current phase's time is up: the phase has
// reached its end and the loop owes this editor a flip.
edit_blink_due :: proc(e: ^Edit) -> bool {
	if e == nil || !e.blink_armed { return false }
	return i64(time.since(e.blink_at)) >= 0
}

// edit_blink_step flips the phase at its deadline and returns whether it did.
// The caller repaints (the frame before the flip painted the older phase; the
// frame after flips paints the new one).
edit_blink_step :: proc(e: ^Edit) -> bool {
	if !edit_blink_due(e) { return false }
	e.blink_on = !e.blink_on
	e.blink_at = time.time_add(time.now(), CARET_BLINK_PERIOD)
	return true
}

// edit_blink_wait_ms is how long the loop should sleep before the next phase
// flip. It is the finite "time to the next blink edge" while a caret owns the
// editor, and -1 when the editor holds no caret the loop should blink (never
// armed — nothing was painted for it). The loop turns -1 into poll(-1), i.e. an
// indefinite block; a caret visible turns it into a finite timeout.
edit_blink_wait_ms :: proc(e: ^Edit) -> i32 {
	if e == nil || !e.blink_armed { return -1 }
	rem := time.time_to_unix_nano(e.blink_at) - time.time_to_unix_nano(time.now())
	ms := i32(time.duration_milliseconds(time.Duration(rem)))
	if ms < 0 { ms = 0 }
	return ms
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
	// The caret MOVED (a character landed at it) -> the blink phase resets to ON.
	edit_blink_reset(e)
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
		// The burst insert goes through insert_bytes directly (NOT edit_insert_rune):
		// a paste is one caret move and the CALLER (the sync layer) owns the blink
		// reset, so a per-frame paste cannot restart the blink deadline every frame.
		if edit_is_drawable(r) {
			tmp, n := utf8.encode_rune(r)
			if n > 0 {
				at := e.caret
				if at < 0 { at = 0 }
				if at > e.len { at = e.len }
				if insert_bytes(e, at, tmp[0:n]) {
					e.caret = at + n
					accepted += 1
				}
			}
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
	// The caret MOVED -> the blink phase resets to ON.
	edit_blink_reset(e)
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
	// The caret MOVED -> the blink phase resets to ON.
	edit_blink_reset(e)
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
	// The caret MOVED -> the blink phase resets to ON.
	edit_blink_reset(e)
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
	// The caret MOVED -> the blink phase resets to ON.
	edit_blink_reset(e)
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
		e.blink_armed = true
		// THE PAIR SWAP (UIP-5): phase ON -> the highlighted pair (glyph in
		// `caret_fg` knocked out of a `caret_bg` block); phase OFF -> the normal
		// pair (glyph in `fg`, cell fill `bg`). The glyph is the overlay — the real
		// character under the caret, or the solid block at end of buffer — and it
		// is in the cell in BOTH phases, so the blink swaps colours, never content,
		// and the character cannot vanish for half of every blink. No underline: the
		// two pairs are fg/bg swaps, never an underline style.
		caret_bg := pal.caret_bg
		caret_fg := pal.caret_fg
		if !e.blink_on {
			caret_bg = pal.bg
			caret_fg = pal.fg
		}
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
			backgroundColor = caret_bg,
		}) {
			clay.Text(caret_text, clay.TextElementConfig{textColor = caret_fg})
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

// THE TERMINAL CURSOR IS NOT THE CARET ANY MORE — AND THAT IS DELIBERATE.
//
// edit_place_cursor used to point the terminal's REAL cursor at the cell the
// caret was painted into and ask the terminal for a blinking block to match
// (DECSCUSR `ESC[3 q`). THE CARET IS NOW PAINTED BY CLAY THROUGH THE APP-DRIVEN
// PAIR SWAP (see edit_paint), so the real terminal cursor is HIDDEN for editable
// fields (`tb_hide_cursor`, ESC[?25l) and needs neither positioning nor a blink:
// positioning was only ever there to host a terminal-owned blink, and the blink
// is the app's now. So this proc keeps the ONE thing that is genuinely still
// needed from the old shape — reading the cell back for the caller — and takes no
// terminal bytes at all. Which editor owns the caret, and whether to hide the
// hardware cursor instead, is the caller's decision.
edit_place_cursor :: proc(e: ^Edit) -> (x, y: i32, ok: bool) {
	x, y, ok = edit_caret_cell(e)
	return x, y, ok
}
