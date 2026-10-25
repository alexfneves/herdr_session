package ui

// ============================================================================
// ui.list — the filtered picker list, shared by the theme and remote pickers
// (T5.3)
//
// One list type serves both pickers. The picker supplies its items through a
// generic projection (`picker_rows($T, ...)`) so nothing in the list knows
// whether it is showing theme names or ssh targets: both become a
// `Picker_Row{id, label, detail}` and every behaviour — filtering, movement,
// scroll, picking, rendering — is written exactly once.
//
// ── WHAT THE LIST OWNS ──────────────────────────────────────────────────────
// * `filter` — an Edit, so filtering gets the same whole-rune backspace and
//   sanitised paste as every other text field.
// * `shown`  — the filtered index set, recomputed from the filter. Movement and
//   picking operate on THIS, never on the caller's array, so "select the third
//   visible thing" survives a filter change.
// * `sel`    — index into `shown`, or -1 for "nothing selected".
// * `scroll` — rows scrolled off the top, in cells.
//
// ── NO SELECTION IS A REAL STATE ────────────────────────────────────────────
// `sel = -1` is legal and permanent until the user moves. Enter on an empty list,
// or on a list whose selection was cleared by filtering, resolves to "nothing" and
// must be a NO-OP rather than a crash or a pick of row 0. list_pick returns an
// optional for exactly that reason: a caller that ignores the `ok` gets caught by
// the type.
//
// Movement, scroll clamping and "keep the selection visible" all run through the
// same `keep_visible` helper the sessions table uses, so the two lists can never
// drift apart on how a selection behaves when the terminal shrinks.
// ============================================================================

import clay "../../clay-odin"


// Picker_Row is one selectable row of any picker.
Picker_Row :: struct {
	id : string, // what picking yields (theme name, ssh target)
	label : string, // what the row shows
	detail : string, // secondary text (right-aligned), may be empty
}

// picker_rows projects ANY item type into rows. This is the generic seam that lets
// the theme picker and the remote picker share one list implementation without a
// common base type or an interface.
picker_rows :: proc(items: []$T,
                  id_of: proc(T) -> string,
                  label_of: proc(T) -> string,
                  detail_of: proc(T) -> string) -> []Picker_Row {
	out: [dynamic]Picker_Row
	for it in items {
		append(&out, Picker_Row{
			id     = id_of(it),
			label  = label_of(it),
			detail = detail_of(it),
		})
	}
	return out[:]
}

// List is the shared picker view state.
List :: struct {
	filter : Edit,
	sel : int, // index into `shown`; -1 == no selection
	scroll : i32, // rows scrolled off the top
	shown : [dynamic]int, // indices into the caller's rows that pass the filter
}

list_init :: proc(l: ^List) {
	edit_init(&l.filter)
	l.sel = -1
	l.scroll = 0
}

list_free :: proc(l: ^List) {
	if len(l.shown) > 0 {
		delete(l.shown)
	}
	l.shown = nil
}

// ── filtering ──────────────────────────────────────────────────────────────

// list_row_matches a row against the filter: label or detail, case-insensitive.
list_row_matches :: proc(row: Picker_Row, filter: string) -> bool {
	if len(filter) == 0 {
		return true
	}
	return str_contains_ci(row.label, filter) || str_contains_ci(row.id, filter) ||
		str_contains_ci(row.detail, filter)
}

// list_apply rebuilds the shown index set from the current filter, keeping the
// caller's order. The selection is preserved by ROW IDENTITY (not index) where the
// row survives the filter, and dropped to -1 otherwise — so typing a character can
// never silently move the selection onto a different item.
list_apply :: proc(l: ^List, rows: []Picker_Row) {
	held: string = ""
	held_id_ok := false
	if l.sel >= 0 && l.sel < len(l.shown) {
		idx := l.shown[l.sel]
		if idx >= 0 && idx < len(rows) {
			held = rows[idx].id
			held_id_ok = true
		}
	}
	clear(&l.shown)
	for row, i in rows {
		if list_row_matches(row, edit_text(&l.filter)) {
			append(&l.shown, i)
		}
	}
	// Re-place the selection on the same id if it survived.
	if held_id_ok {
		for idx, j in l.shown {
			if rows[idx].id == held {
				l.sel = j
				break
			}
		}
		// If the loop fell through without a match, sel stays as it was and is
		// clamped below; never leave it pointing past the end.
		if l.sel >= len(l.shown) {
			l.sel = -1
		}
	}
	if l.sel >= len(l.shown) {
		l.sel = -1
	}
}

list_count :: proc(l: ^List) -> int {
	return len(l.shown)
}

// ── movement ───────────────────────────────────────────────────────────────

// list_move shifts the selection by `delta` within the shown set and scrolls the
// minimum needed to keep it visible. Empty list -> stays at -1 (no crash, no
// phantom selection).
list_move :: proc(l: ^List, delta: int, visible: i32) {
	n := i32(len(l.shown))
	if n == 0 {
		l.sel = -1
		return
	}
	cur := i32(l.sel)
	if cur < 0 {
		// Nothing selected: down selects the first row, up the last.
		cur = 0
		if delta < 0 {
			cur = n - 1
		}
	} else {
		cur += i32(delta)
		if cur < 0 {
			cur = 0
		}
		if cur > n-1 {
			cur = n - 1
		}
	}
	l.sel = int(cur)
	l.scroll = keep_visible(l.scroll, n, visible, cur)
}

// list_select_to jumps to a specific shown index.
list_select_to :: proc(l: ^List, index: int, visible: i32) {
	if index < 0 || index >= len(l.shown) {
		return
	}
	l.sel = index
	l.scroll = keep_visible(l.scroll, i32(len(l.shown)), visible, i32(index))
}

// list_pick resolves the current selection. ok == false means "no selection", and
// the caller MUST treat that as a no-op.
list_pick :: proc(l: ^List, rows: []Picker_Row) -> (Picker_Row, bool) {
	if l.sel < 0 || l.sel >= len(l.shown) {
		return Picker_Row{}, false
	}
	idx := l.shown[l.sel]
	if idx < 0 || idx >= len(rows) {
		return Picker_Row{}, false
	}
	return rows[idx], true
}

// ── painting ───────────────────────────────────────────────────────────────

// list_paint draws the picker: a filter line plus a scrolled list of rows inside
// a box `avail` wide and `body_rows` tall.
list_paint :: proc(l: ^List, rows: []Picker_Row, avail: i32, body_rows: i32, pal: ^Palette) {
	if clay.UI(clay.ID("hs.list"))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingGrow(),
				height = clay.SizingFixed(f32(body_rows)),
			},
			layoutDirection = clay.LayoutDirection.TopToBottom,
		},
		clip = clay.ClipElementConfig{
			horizontal = true,
			vertical = true,
			childOffset = clay.Vector2{0, -f32(l.scroll)},
		},
	}) {
		if len(l.shown) == 0 {
			clay.Text("nothing matches", clay.TextElementConfig{textColor = pal.dim})
		}
		for idx, j in l.shown {
			if idx < 0 || idx >= len(rows) {
				continue
			}
			is_sel := j == l.sel
			list_paint_row(rows[idx], avail, is_sel, pal, j)
		}
	}
}

list_paint_row :: proc(row: Picker_Row, avail: i32, is_sel: bool, pal: ^Palette, order: int) {
	bg := clay.Color{}
	fg := pal.fg
	if is_sel {
		bg = pal.sel_bg
		fg = pal.sel_fg
	}
	// label takes the left, detail the right; together they must fit `avail`.
	detail_w := text_cols(row.detail)
	if detail_w > 0 {
		detail_w += 2
	}
	label_w := avail - detail_w
	if label_w < 1 {
		label_w = 1
	}
	if clay.UI()({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingGrow(),
				height = clay.SizingFixed(1),
			},
			layoutDirection = clay.LayoutDirection.LeftToRight,
		},
		backgroundColor = bg,
	}) {
		// A full-width filler carries the label so `detail` can be pushed right by
		// the remaining space without a second layout pass.
		if clay.UI()({
			layout = clay.LayoutConfig{
				sizing = clay.Sizing{
					width  = clay.SizingFixed(f32(label_w)),
					height = clay.SizingFixed(1),
				},
				layoutDirection = clay.LayoutDirection.LeftToRight,
			},
		}) {
			clay.Text(ellipsize(row.label, label_w), clay.TextElementConfig{textColor = fg})
		}
		if len(row.detail) > 0 {
			clay.Text(ellipsize(row.detail, avail-label_w), clay.TextElementConfig{textColor = pal.dim})
		}
	}
	_ = order
}
