package ui

// ============================================================================
// ui.sessions — the session table (T5.2)
//
// Four fixed-width columns — device · timestamp · state · name — under a live
// filter line, over an app-scrolled body.
//
// ── EVERY COLUMN IS SizingFixed(n) ──────────────────────────────────────────
// A cell's width is chosen here and handed to Clay as a constant. Clay's
// `textAlignment` is deliberately NOT used for fitting: it positions text inside
// a box that is already the wrong size, so a long name pushes into the next
// column instead of being cut. Fitting is app-owned — `fit_cols` / `pad_cols` cut
// on DISPLAY-CELL boundaries (a 2-cell CJK rune is all-or-nothing), and the
// column widths come from the terminal width at paint time so a shrink re-derives
// them.
//
// ── SCROLL IS APP STATE, NOT A CLAY FEATURE ─────────────────────────────────
// Clay's clip container is a scissor, nothing more. There is no scroll model, no
// momentum, no pixel offsets — pixel offsets are meaningless at cell granularity.
// `v.scroll` is an INTEGER count of rows, mapped onto Clay by
//
//     clip = {vertical = true, childOffset = (0, -scroll)}
//
// because one Clay unit is exactly one terminal cell here (measure returns
// LINE_HEIGHT_CELLS = 1). So childOffset is in rows, and the value the view
// carries is the value that ships.
//
// ── SELECTION IS IDENTITY, HIGHLIGHT IS OURS ────────────────────────────────
// The selection is the Phase 4 (device, name) identity, never an index: filtering,
// re-sorting and a shrinking terminal all change indices, and the plan's
// cancel/delete rule is "if it is still there, keep it selected". Resolving the
// identity against the current rows gives the row index at paint time, and the
// highlight is an explicit backgroundColor the view chose (pal.sel_bg, which
// is the theme's `selection.background`) with its matching foreground
// (pal.sel_fg). The renderer is NOT asked to blend a tint — Phase 2 left
// overlay blending as a no-op, so a highlight that relied on it would silently
// be nothing.
//
// THE STATE COLUMN KEEPS ITS OWN COLOUR OVER THE HIGHLIGHT (RCH-12).
// A row's device / timestamp / name cells all take `sel_fg` under selection;
// the state word does not. It paints `pal.running` or `pal.stopped` — the
// theme's `normal.green` / `normal.red` — ON TOP OF the highlight, in both
// selection states. A selected RUNNING row therefore does not look like a
// selected STOPPED row, which is the one thing that column exists to say.
//
// It used to be that the selected pair was DERIVED (a blend search that moved
// the state colour until it was legible on the bar). That derivation is gone:
// the theme supplies the distinctness of green-from-red and we do not
// manufacture it. `tests/unit/theme_roles_test.odin` verifies that these two
// colours clear the legibility floor over `selection.background` for all ten
// themes; where a theme's own values are weak, that is reported, not painted
// over.
//
// Under selection the state word therefore keeps `pal.running` / `pal.stopped`
// exactly as it does unselected. There is no second, highlighted version of the
// state colour: no derived pair, no per-theme "highlighted running" hex, no
// blend. A theme cannot get the selected case wrong because there is nothing
// separate to get wrong, and a new theme does not have to choose anything. The
// view's job stops at referencing the ROLES. See `sess_paint_row`.
//
// ── SHRINK NEVER LOSES THE SELECTION ────────────────────────────────────────
// sessions_clamp runs every frame with the current visible row count: scroll is
// clamped into [0, count-visible] and then the selection is pulled back into the
// window. Because the selection is an identity, a row that still exists can never
// be lost — only scrolled back into view. If the row really is gone, the view
// reports "gone" and keeps the old identity in hand rather than inventing a new
// selection.
// ============================================================================

import clay "../../clay-odin"
import app "../app"
import "core:fmt"

// ── column widths (cells) ──────────────────────────────────────────────────
// ts_display is "YYYY-MM-DD HH:MM:SS.mmm" = 23 cells; "—" for unknown.
SESS_W_DEVICE :: 12
SESS_W_TS :: 23
SESS_W_STATE :: 8
SESS_W_NAME_MIN :: 8
SESS_COL_GAP :: 1 // no borders inside a row, so a 1-cell gap is safe here
SESS_COLS_N :: 4

SESS_HEADER_FILTER_ID :: "hs.sessions.filter"
SESS_FILTER_RULE_ID :: "hs.sessions.filter.rule" // RCH-10 change 1
SESS_HEADER_ROW_ID :: "hs.sessions.head"
SESS_BODY_ID :: "hs.sessions.body"

// Sessions_Columns is the fitted width budget for one row.
Sessions_Columns :: struct {
	device : i32,
	ts : i32,
	state : i32,
	name : i32,
	gap : i32,
}

// sessions_columns spends the available width. The three fixed columns keep their
// widths; the name column takes what is left and is truncated rather than ever
// pushing a neighbour.
sessions_columns :: proc(avail: i32) -> Sessions_Columns {
	c : Sessions_Columns
	c.gap = SESS_COL_GAP
	c.device = SESS_W_DEVICE
	c.ts = SESS_W_TS
	c.state = SESS_W_STATE
	fixed : i32 = SESS_W_DEVICE + SESS_W_TS + SESS_W_STATE + SESS_COL_GAP*(SESS_COLS_N-1)
	c.name = avail - fixed
	if c.name < SESS_W_NAME_MIN {
		// Too narrow for the name to be useful: take cells off the timestamp,
		// which is the least dense column per cell, and give them to the name.
		need : i32 = SESS_W_NAME_MIN - c.name
		trim := need
		if trim > 7 {
			trim = 7
		}
		c.ts = SESS_W_TS - trim
		c.name = avail - (c.device + c.ts + c.state + SESS_COL_GAP*(SESS_COLS_N-1))
		if c.name < 1 {
			c.name = 1
		}
	}
	return c
}

// Sessions is the view state. Rows are passed in by the caller (already merged
// and ordered by fetch); the view owns only filter / selection / scroll.
//
// `show_filter` decides whether the filter LINE is drawn at all. It is a field
// rather than a parameter because the answer comes from
// `app.state_is_filter_view` — a rule that lives in the machine, not in the
// view — and `sessions_paint`'s signature belongs to every caller in the tree.
// `sessions_init` sets it to true, so a view that never says otherwise paints
// the table it always painted; {Mode selection} is the state that opts out.
Sessions :: struct {
	filter : Edit,
	sel : app.Selection,
	scroll : i32, // rows scrolled off the top
	show_filter : bool,
}

sessions_init :: proc(v: ^Sessions) {
	edit_init(&v.filter)
	v.sel = app.NO_SELECTION
	v.scroll = 0
	v.show_filter = true
}

// sessions_chrome is the number of MAIN rows the table spends ABOVE its
// scrolled body: the column header, plus the ruled filter surface (the filter
// line AND the rule under it) in the states that display one.
//
// This exists so no consumer hardcodes the 2 again. Before change 1 the filter
// cost one row and every caller wrote `- 2`; change 1 added a rule row under it,
// so a hardcoded 2 would now hand the table a row that the rule is standing on
// -- the phantom-row class of bug, just moved down one line.
sessions_chrome :: proc(show_filter: bool) -> i32 {
	chrome : i32 = 1 // the column header
	if show_filter {
		chrome += RULED_SURFACE_ROWS
	}
	return chrome
}

// sessions_first_row is the screen row of the table's first data row. The
// smoke cases assert against a row index read off the grid, so they must derive
// it the same way the view lays it out rather than adding their own constants.
sessions_first_row :: proc(l: Frame_Layout, show_filter: bool) -> i32 {
	return l.main_y + sessions_chrome(show_filter)
}

// ── filtering ──────────────────────────────────────────────────────────────

// sessions_match is a case-insensitive substring test over everything the user
// can see for a row. An empty filter matches every row, which is what keeps
// "filter starts empty" the same code path as "filter is in use".
sessions_match :: proc(s: app.Session, filter: string) -> bool {
	if len(filter) == 0 {
		return true
	}
	return str_contains_ci(s.name, filter) ||
		str_contains_ci(s.device, filter) ||
		str_contains_ci(s.label, filter)
}

// sessions_filter_rows returns the rows that pass the filter, in the caller's
// (already sorted) order. Allocates from the caller's context.
sessions_filter_rows :: proc(rows: []app.Session, filter: string) -> []app.Session {
	out: [dynamic]app.Session
	if len(filter) == 0 {
		for r in rows {
			append(&out, r)
		}
		return out[:]
	}
	for r in rows {
		if sessions_match(r, filter) {
			append(&out, r)
		}
	}
	return out[:]
}

// ── scroll / selection ─────────────────────────────────────────────────────

// sessions_selected_index resolves the held identity against the visible rows.
// -1 means "nothing selected" or "the selected session is not in this list".
sessions_selected_index :: proc(v: ^Sessions, rows: []app.Session) -> int {
	if !v.sel.valid {
		return -1
	}
	return app.selection_index(rows, v.sel)
}

// sessions_clamp forces scroll legal for `visible` rows and drags the selection
// back into the window. Call this every frame with the CURRENT visible row count:
// it is the whole shrink story in one function, and it delegates to the same
// keep_visible the picker list uses, so the two views cannot disagree.
sessions_clamp :: proc(v: ^Sessions, rows: []app.Session, visible: i32) {
	idx := i32(sessions_selected_index(v, rows))
	v.scroll = keep_visible(v.scroll, i32(len(rows)), visible, idx)
}

// sessions_reveal scrolls the minimum needed to bring `index` into view.
sessions_reveal :: proc(v: ^Sessions, index: i32, visible: i32) {
	if index < 0 || visible <= 0 {
		return
	}
	if index < v.scroll {
		v.scroll = index
	} else if index >= v.scroll+visible {
		v.scroll = index - visible + 1
	}
}

// ── painting ───────────────────────────────────────────────────────────────

// sessions_paint draws the filter line, the column header and the scrolled body
// into a box `avail` cells wide and `body_rows` cells tall. `rows` must already be
// filtered (see sessions_filter_rows) and ordered.
sessions_paint :: proc(v: ^Sessions, rows: []app.Session, avail: i32, body_rows: i32, pal: ^Palette) {
	cols := sessions_columns(avail)

	// ── the filter line (only in the states that display one) ──
	if v.show_filter {
		if clay.UI(clay.ID(SESS_HEADER_FILTER_ID))({
			layout = clay.LayoutConfig{
				sizing = clay.Sizing{
					width  = clay.SizingGrow(),
					height = clay.SizingFixed(1),
				},
				layoutDirection = clay.LayoutDirection.LeftToRight,
				childGap = 1,
			},
		}) {
			clay.Text("filter:", clay.TextElementConfig{textColor = pal.dim})
			// The filter is an editor: live caret, whole-rune backspace, sanitised
			// paste. It starts empty, which shows every row.
			edit_paint(&v.filter, "hs.sessions.filter.edit", avail-8, pal)
		}
		// RCH-10 CHANGE 1 -- the separation line below the filter.
		//
		// The rule is a dedicated element OUTSIDE the filter's own box, placed
		// immediately after it in MAIN's vertical stack. Two reasons it is done
		// this way rather than as a border on the filter row itself:
		//
		//  * The filter row is a LeftToRight container whose height is fixed at
		//    1. A bottom border on it would be drawn ON the filter's own last
		//    row, over the input, not under it.
		//  * A separate element is a row that the ROW ACCOUNTING can see. It is
		//    charged to RULED_SURFACE_ROWS, which `session_body` reads, so the
		//    table below shrinks by exactly one row and never paints over it.
		frame_rule(SESS_FILTER_RULE_ID, pal)
	}

	// ── column header ──
	if clay.UI(clay.ID(SESS_HEADER_ROW_ID))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingGrow(),
				height = clay.SizingFixed(1),
			},
			layoutDirection = clay.LayoutDirection.LeftToRight,
			childGap = SESS_COL_GAP,
		},
	}) {
		paint_cell("device", cols.device, pal.dim)
		paint_cell("timestamp", cols.ts, pal.dim)
		paint_cell("state", cols.state, pal.dim)
		paint_cell("name", cols.name, pal.dim)
	}

	// ── the scrolled body ──
	// The scissor is the only clip; `childOffset` is the app's row count, in
	// cells. Clay knows nothing about scrolling — it just obeys the offset.
	if clay.UI(clay.ID(SESS_BODY_ID))({
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
			childOffset = clay.Vector2{0, -f32(v.scroll)},
		},
	}) {
		if len(rows) == 0 {
			clay.Text("no sessions match", clay.TextElementConfig{textColor = pal.dim})
		}
		for &row in rows {
			is_sel := v.sel.valid && row.device == v.sel.device && row.name == v.sel.name
			sess_paint_row(row, cols, is_sel, pal)
		}
	}
}

sess_paint_row :: proc(row: app.Session, cols: Sessions_Columns, is_sel: bool, pal: ^Palette) {
	bg := clay.Color{} // alpha 0 == paint nothing; the frame's bg shows through
	fg := pal.fg
	if is_sel {
		bg = pal.sel_bg
		fg = pal.sel_fg
	}
	// Unique id per row: Clay requires unique ids within a frame.
	rid := fmt.tprintf("hs.sessions.row#{}{}", row.device, row.name)
	if clay.UI(clay.ID(rid))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingGrow(),
				height = clay.SizingFixed(1),
			},
			layoutDirection = clay.LayoutDirection.LeftToRight,
			childGap = SESS_COL_GAP,
		},
		backgroundColor = bg,
	}) {
		paint_cell(ellipsize(row.device, cols.device), cols.device, fg)
		paint_cell(ellipsize(app.ts_display(row.ts), cols.ts), cols.ts, fg)
		// ── the state word: its own colour, selected or not ────────────────
		// RCH-12. `running` / `stopped` are palette roles in BOTH selection
		// states, and selection does not change which one is used:
		//
		//                 not selected    selected
		//   running       pal.running     pal.running   (over pal.sel_bg)
		//   stopped       pal.stopped     pal.stopped   (over pal.sel_bg)
		//
		// The theme's `normal.green` / `normal.red` are what make the two rows
		// differ; the highlight bar is simply the surface they are painted on.
		// There is no derivation here any more, and no per-theme special case.
		//
		// This is a per-cell foreground decision on purpose. A blend/tint of the
		// highlight over the state colour is NOT available: overlay blending has
		// been a deliberate no-op since Phase 2 (this file's header), so a tint
		// approach paints nothing at all (D-Q).
		state_fg : clay.Color
		if row.running {
			state_fg = pal.running
		} else {
			state_fg = pal.stopped
		}
		paint_cell(state_text(row.running), cols.state, state_fg)
		paint_cell(ellipsize(row.name, cols.name), cols.name, fg)
	}
}

paint_cell :: proc(text: string, w: i32, fg: clay.Color) {
	// A cell is a fixed-width box whose content was already cut to fit, so Clay
	// never has to wrap and never spills into its neighbour.
	if clay.UI()({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingFixed(f32(w)),
				height = clay.SizingFixed(1),
			},
			layoutDirection = clay.LayoutDirection.LeftToRight,
		},
	}) {
		if len(text) > 0 {
			clay.Text(text, clay.TextElementConfig{textColor = fg})
		}
	}
}

state_text :: proc(running: bool) -> string {
	if running {
		return "running"
	}
	return "stopped"
}

// ── small string helper (kept local; core:strings has no CI contains) ────────
str_contains_ci :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	// ASCII-folded compare, rune-by-rune on the lower-cased forms. Session names
	// are ASCII by validation, but device labels needn't be, so fold by ASCII only
	// and leave other codepoints to exact equality.
	hi := 0
	for hi+len(needle) <= len(haystack) {
		ok := true
		i := 0
		for i < len(needle) {
			a := haystack[hi+i]
			b := needle[i]
			if a >= 'A' && a <= 'Z' {
				a = a - 'A' + 'a'
			}
			if b >= 'A' && b <= 'Z' {
				b = b - 'A' + 'a'
			}
			if a != b {
				ok = false
				break
			}
			i += 1
		}
		if ok {
			return true
		}
		hi += 1
	}
	return false
}
