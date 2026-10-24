package main

// ============================================================================
// Phase 5a UI smoke — T5.1 frame, T5.2 sessions, T5.3 edit / list / float.
//
// Every case runs INSIDE a real pty (dev/ui-smoke.sh wraps each one in `script
// -q -e`), paints through the real Clay -> render.paint -> termbox back-buffer
// path, and asserts against the cells that were actually written. Where a case
// needs keystrokes it reads real tb_events off the pty: the harness pipes a byte
// script into the master, termbox decodes it (UTF-8 included) and the view
// reacts. Nothing here fakes a terminal, and nothing asserts on a string that was
// not read back out of the grid.
//
//   ui-frame     the spine: outer border, section rules, title, footer, geometry
//   ui-sessions  four fixed columns, live filter, selection, ordering
//   ui-shrink    a real TIOCSWINSZ resize: selection survives, re-clamped
//   ui-edit      CJK/emoji typed AND pasted; the caret is a display column
//   ui-list      one list for both pickers; move / filter / enter / no-op
//   ui-float     the error pane floats over everything, Enter/Esc dismiss
//
// The scene lives in module state on purpose: Odin procedure literals capture the
// *context* and nothing else, so a `proc() { ... }` cannot close over a caller's
// locals. A single scene struct plus top-level paint/handler procs is what the
// language actually allows, and it keeps every repaint identical.
// ============================================================================

import ui "./ui"
import app "./app"
import render "./render"
import clay "../clay-odin"
import termbox2 "../vendor/termbox2-odin"

import "core:c"
import "core:fmt"
import "core:sort"
import "core:strings"

Scene_Mode :: enum {
	sessions,
	edit,
	list,
	sessions_float,
}

Scene :: struct {
	p : ^ui.Painter,
	f : ^ui.Frame,
	l : ui.Frame_Layout,
	pal : ^ui.Palette,
	mode : Scene_Mode,

	// sessions
	v : ^ui.Sessions,
	rows : []app.Session,
	body : i32, // rows available to the scrolled table
	first : i32, // screen row of the first table row

	// edit
	e : ^ui.Edit,
	edit_w : i32,

	// list
	list : ^ui.List,
	list_rows : []ui.Picker_Row,

	// float
	flt : ^ui.Float,
	fw : i32,
	fh : i32,
	last : render.Stats,
}

scene : Scene

// visible_rows applies the live filter to the scene's full row set. The view
// paints whatever it is given, so narrowing is done here, in front of the paint,
// exactly as the state machine will do it later.
visible_rows : [dynamic]app.Session

visible_rows_now :: proc() -> []app.Session {
	clear(&visible_rows)
	filter := ui.edit_text(&scene.v.filter)
	for r in scene.rows {
		if ui.sessions_match(r, filter) {
			append(&visible_rows, r)
		}
	}
	return visible_rows[:]
}

// paint repoints the whole frame for whatever the scene currently holds.
paint_scene :: proc() {
	ui.frame_open(scene.p, scene.f)
	switch scene.mode {
	case .sessions:
		shown := visible_rows_now()
		ui.sessions_clamp(scene.v, shown, scene.body)
		ui.sessions_paint(scene.v, shown, scene.l.cols, scene.body, scene.pal)
	case .edit:
		ui.edit_paint(scene.e, "hs.case.edit", scene.edit_w, scene.pal)
	case .list:
		ui.list_paint(scene.list, scene.list_rows, scene.l.cols, scene.l.main_rows, scene.pal)
	case .sessions_float:
		ui.sessions_clamp(scene.v, scene.rows, scene.body)
		ui.sessions_paint(scene.v, scene.rows, scene.l.cols, scene.body, scene.pal)
		ui.float_paint(scene.flt, scene.l.cols, scene.pal)
	}
	scene.last = ui.frame_close(scene.p, scene.f)
	termbox2.tb_present()
}

// ── fixtures ───────────────────────────────────────────────────────────────

// pad_n zero-pads to a fixed width. Odin's fmt has no `{:02}`, and the session
// name's timestamp suffix is positional (`%Y-%m-%d-%H-%M-%S-%3N`), so the
// padding has to be explicit for the name to parse back into a Ts.
pad_n :: proc(n, width: int) -> string {
	out := fmt.tprintf("{}", n)
	for len(out) < width {
		out = fmt.tprintf("0{}", out)
	}
	return out
}

fixture_session :: proc(device, prefix: string, h, m, s, ms: int, running: bool) -> app.Session {
	name := fmt.tprintf("{}-2026-10-18-{}-{}-{}-{}",
		prefix, pad_n(h, 2), pad_n(m, 2), pad_n(s, 2), pad_n(ms, 3))
	return app.Session{
		device  = device,
		label   = device,
		name    = name,
		running = running,
		ts      = app.ts_from_name(name),
	}
}

// fixture_rows is deliberately OUT of order: a view that never sorted would show
// beta's row first and fail the ordering assertion.
fixture_rows :: proc() -> []app.Session {
	all: [dynamic]app.Session
	append(&all, fixture_session("beta.example", "worker", 9, 5, 1, 100, true))
	append(&all, fixture_session("local", "api", 10, 0, 0, 0, true))
	append(&all, fixture_session("alpha.example", "db", 8, 30, 0, 500, false))
	append(&all, fixture_session("local", "web", 7, 15, 30, 250, false))
	append(&all, fixture_session("local", "cache", 11, 45, 12, 900, true))
	append(&all, fixture_session("alpha.example", "queue", 12, 0, 0, 0, true))
	append(&all, fixture_session("zeta.example", "bulk", 6, 0, 0, 0, false))
	return all[:]
}

sorted_rows :: proc(rows: []app.Session) -> []app.Session {
	out := make([]app.Session, len(rows))
	copy(out, rows)
	sort.quick_sort_proc(out, app.compare_session)
	return out
}

NARROW_WIDTHS : []i32 = {120, 100, 80, 60, 40, 30, 20, 10}

UI_KEYS : []ui.Key_Hint = {
	ui.Key_Hint{"enter", "new"},
	ui.Key_Hint{"r", "remote"},
	ui.Key_Hint{"d", "delete"},
	ui.Key_Hint{"a", "attach"},
	ui.Key_Hint{"t", "theme"},
	ui.Key_Hint{"q", "quit"},
}

make_frame :: proc(cols, rows: i32, pal: ^ui.Palette) -> ui.Frame {
	return ui.Frame{
		cols  = cols,
		rows  = rows,
		title = "herdr-session",
		state = "select",
		keys  = UI_KEYS,
		pal   = pal,
	}
}

// bring_up initialises the terminal + painter and fills the shared scene.
bring_up :: proc() -> bool {
	if !enter_terminal() {
		return false
	}
	cols, rows := termbox2.tb_width(), termbox2.tb_height()
	say(fmt.tprintf("  terminal: {}x{}", cols, rows))
	if !ui.painter_start(&g_painter, cols, rows) {
		check("painter_start", false, "clay init failed")
		return false
	}
	g_pal = ui.DEFAULT_PALETTE
	scene.p = &g_painter
	scene.pal = &g_pal
	scene.f = &g_frame
	scene.f.cols = cols
	scene.f.rows = rows
	scene.f.title = "herdr-session"
	scene.f.state = "select"
	scene.f.keys = UI_KEYS
	scene.f.pal = &g_pal
	scene.l = ui.frame_layout(cols, rows)
	return true
}

g_painter : ui.Painter
g_pal     : ui.Palette
g_frame   : ui.Frame

// ── grid helpers ───────────────────────────────────────────────────────────

paint_attr :: proc(c: clay.Color) -> termbox2.Attr {
	return render.attr_painted(c)
}

cols_of :: proc(r: rune) -> i32 {
	return render.glyph_columns(r)
}

line_of :: proc(y: i32, w: i32) -> string {
	buf: [dynamic]byte
	x: i32 = 0
	for x < w {
		r := rune(glyph_at(x, y))
		if r == 0 {
			r = ' '
		}
		push_str(&buf, fmt.tprintf("{}", r))
		x += 1
	}
	// NOTE: no delete here. `string(buf[:])` shares the buffer's memory, so
	// freeing it would leave the returned string dangling (which is exactly the
	// mojibake this helper produced the first time). The driver allocates from the
	// context allocator and exits right after the report, so these live for the
	// run on purpose.
	return string(buf[:])
}

count_glyph_in_row :: proc(y: i32, w: i32, want: rune) -> int {
	n := 0
	x: i32 = 0
	for x < w {
		if glyph_at(x, y) == want {
			n += 1
		}
		x += 1
	}
	return n
}

is_rule_glyph :: proc(ch: rune) -> bool {
	return ch == '─' || ch == '━' || ch == '╌'
}

// grid_snapshot grabs the visible grid so a later frame can be diffed against
// "what was on the screen before".
grid_snapshot :: proc(cols, rows: i32) -> []rune {
	g := make([]rune, int(cols)*int(rows))
	i := 0
	y: i32 = 0
	for y < rows {
		x: i32 = 0
		for x < cols {
			g[i] = glyph_at(x, y)
			i += 1
			x += 1
		}
		y += 1
	}
	return g
}

grid_at :: proc(g: []rune, cols: i32, x, y: i32) -> rune {
	idx := int(y)*int(cols) + int(x)
	if idx < 0 || idx >= len(g) {
		return 0
	}
	return g[idx]
}

// ── pty input ─────────────────────────────────────────────────────────────
//
// feed reads tb_events off the pty until the byte script runs dry (two idle
// polls back to back) or `max` events arrived, handing each key to `apply`.
// Resizes are counted separately: the shrink case needs proof a real SIGWINCH
// landed.
Feed_Stat :: struct {
	keys : int,
	resizes : int,
	timed_out : bool,
}

// feed reads tb_events off the pty and hands each key to `apply`.
//
// The quiet rule matters: input piped into the pty arrives asynchronously, and
// during tb_init termbox consumes whatever is already pending as terminal
// responses. So the harness delays its keystrokes and this keeps polling
// FEED_QUIET_POLLS consecutive idle 100 ms polls before declaring the script
// done. max_keys bounds the whole read.
FEED_QUIET_POLLS :: 40 // 4 s of silence ends the read

feed :: proc(apply: proc(ev: ^termbox2.Event), max: int) -> Feed_Stat {
	st : Feed_Stat
	idle := 0
	for st.keys+st.resizes < max {
		ev := termbox2.Event{}
		rv := termbox2.tb_peek_event(&ev, 100)
		if rv == termbox2.TB_ERR_NO_EVENT || rv == termbox2.TB_ERR_POLL {
			idle += 1
			if idle >= FEED_QUIET_POLLS {
				st.timed_out = true
				break
			}
			continue
		}
		if rv != termbox2.TB_OK {
			say(fmt.tprintf("  feed: peek_event -> {} ({})", rv, termbox2.tb_strerror(rv)))
			break
		}
		idle = 0
		if ev.typ == termbox2.EVENT_RESIZE {
			st.resizes += 1
			continue
		}
		if ev.typ == termbox2.EVENT_KEY {
			say(fmt.tprintf("    ev: key={} ch={}", ev.key, ev.ch))
			apply(&ev)
			st.keys += 1
		}
	}
	return st
}

key_is :: proc(ev: ^termbox2.Event, code: u16) -> bool {
	return ev != nil && ev.typ == termbox2.EVENT_KEY && ev.key == code
}

// Win_Size mirrors struct winsize. Setting it on our own tty fd is the SAME
// kernel operation a user drag performs: the pty window changes and the kernel
// delivers SIGWINCH to the tty's foreground process group — which is us.
Win_Size :: struct {
	rows : u16,
	cols : u16,
	xpixel : u16,
	ypixel : u16,
}

TIOCSWINSZ : c.ulong = 0x5414

foreign import odin_c "system:c"

@(default_calling_convention = "c")
foreign odin_c {
	ioctl :: proc(fd: c.int, request: c.ulong, arg: ^Win_Size) -> c.int ---
}

// shrink_pty resizes the terminal and waits for termbox to report it.
shrink_pty :: proc(rows, cols: i32) -> bool {
	say(fmt.tprintf("  TIOCSWINSZ -> {}x{}", rows, cols))
	ws := Win_Size{rows = u16(rows), cols = u16(cols), xpixel = 0, ypixel = 0}
	rv := ioctl(0, TIOCSWINSZ, &ws)
	if rv != 0 {
		say(fmt.tprintf("  [warn] TIOCSWINSZ returned {}", rv))
	}
	tries := 0
	for tries < 30 {
		ev := termbox2.Event{}
		prv := termbox2.tb_peek_event(&ev, 500)
		if prv == termbox2.TB_ERR_NO_EVENT || prv == termbox2.TB_ERR_POLL {
			tries += 1
			continue
		}
		if prv != termbox2.TB_OK {
			return false
		}
		if ev.typ == termbox2.EVENT_RESIZE {
			return true
		}
	}
	return false
}

// ═══════════════════════════════════════════════════════════════════════════
// T5.1 — the frame
// ═══════════════════════════════════════════════════════════════════════════
body_empty :: proc(ev: ^termbox2.Event) {
	_ = ev
}

case_ui_frame :: proc() -> bool {
	say("case ui-frame — T5.1: spine, outer border, section rules, title, footer")
	if !bring_up() {
		return false
	}
	defer leave_terminal()

	cols := scene.f.cols
	rows := scene.f.rows
	l := scene.l

	// The main section is empty here on purpose: every glyph on screen comes from
	// the spine itself, so a rule/content collision cannot be blamed on a view.
	scene.mode = .sessions
	scene.v = &g_sessions
	scene.rows = nil
	scene.body = 1
	ui.sessions_init(&g_sessions)
	ui.edit_insert_rune(&g_sessions.filter, 'x')
	paint_scene()

	// 1. NO OUTER BORDER (RCH-1). Every box-drawing glyph must be absent from
	//    the screen edges: no corners, no verticals, and no horizontal rule on
	//    the first or last row. The dividers live one row in from the edges, so
	//    a box glyph anywhere on the perimeter means the border came back.
	edge_box := 0
	edge_where := "perimeter is clean"
	BOX_GLYPHS : [14]rune = {'┌', '┐', '└', '┘', '│', '├', '┤', '┬', '┴', '┼', '╭', '╮', '╰', '╯'}
	for ey := i32(0); ey < rows; ey += 1 {
		for ex := i32(0); ex < cols; ex += 1 {
			on_edge := ey == 0 || ey == rows-1 || ex == 0 || ex == cols-1
			if !on_edge {
				continue
			}
			ch := glyph_at(ex, ey)
			for bi := 0; bi < len(BOX_GLYPHS); bi += 1 {
				if ch == BOX_GLYPHS[bi] {
					edge_box += 1
					edge_where = fmt.tprintf("({},{}) holds {}", ex, ey, glyph_name(ch))
				}
			}
		}
	}
	// 2. THE DIVIDERS ARE STILL THERE, and since there is no border and no pad,
	//    they span the FULL terminal width.
	rule_top_n := count_glyph_in_row(l.rule_top, cols, '─')
	rule_bot_n := count_glyph_in_row(l.rule_bot, cols, '─')
	check("divider between HEADER and MAIN spans the full width",
		rule_top_n == int(cols),
		fmt.tprintf("row {} holds {} horizontal glyphs (need {})", l.rule_top, rule_top_n, cols))
	check("divider between MAIN and FOOTER spans the full width",
		rule_bot_n == int(cols),
		fmt.tprintf("row {} holds {} horizontal glyphs (need {})", l.rule_bot, rule_bot_n, cols))
	check("the two dividers are on different rows",
		l.rule_bot != l.rule_top, fmt.tprintf("rule rows {} and {}", l.rule_top, l.rule_bot))

	// 5. THE childGap >= 2 INVARIANT. With childGap = 1 the betweenChildren rule
	//    resolves onto the FOLLOWING section's first row and paints over its
	//    content. This is the assertion that fails loudly if FRAME_GAP is lowered.
	clean := true
	clean_why := "both rule rows are pure rule"
	i := 0
	for i < 2 {
		ry := l.rule_top
		if i == 1 {
			ry = l.rule_bot
		}
		cx := i32(1)
		for cx < cols-1 {
			ch := glyph_at(cx, ry)
			if ch != 0 && ch != ' ' && !is_rule_glyph(ch) {
				clean = false
				clean_why = fmt.tprintf("rule row {} col {} holds {} — content collided with the rule",
					ry, cx, glyph_name(ch))
				break
			}
			cx += 1
		}
		i += 1
	}
	check("no content shares a rule row (childGap >= 2 invariant)", clean, clean_why)

	// 6. Header shows the program title.
	hdr := line_of(l.header_y, cols)
	check("header shows the program title", str_contains_ignore_case(hdr, "herdr-session"),
		fmt.tprintf("row {} = '{}'", l.header_y, hdr))

	// 6b. THE STATE IS ON HEADER LINE 2 (RCH-9).
	//
	// This assertion used to read the FOOTER for the state word — "footer shows
	// the current state". RCH-9 (.pi/plans/2026-10-18-herdr-session-tui/
	// 50-requirement-changes.md, item 3) moved the state out of the footer and
	// into the header, so that check was looking in the wrong place, not
	// describing a broken product. Deleting it would have lost the coverage;
	// re-homing it keeps it, and keeps it pointed at the row that now carries
	// the requirement.
	//
	// The frame paints the header as exactly two lines (ui.HEADER_ROWS == 2):
	// row `header_y` is the title and row `header_y + 1` is the state. Both
	// come from Frame, both are centred, and the scene's state is "select".
	state_row := l.header_y + 1
	stl := line_of(state_row, cols)
	check("header line 2 shows the current state", str_contains_ignore_case(stl, "select"),
		fmt.tprintf("row {} = '{}'", state_row, stl))
	// …and the two header rows are DISTINCT rows: a one-row header would satisfy
	// both of the checks above with a single line, which is not the contract.
	check("the title and the state are on two different header rows",
		state_row > l.header_y && state_row < l.rule_top,
		fmt.tprintf("title row={} state row={} first rule row={}", l.header_y, state_row, l.rule_top))
	// The state must NOT have leaked back into the footer. The footer's job is now
	// `rest` (the notice / host verdict / provenance) and the key hints; if the
	// state reappeared there, this pair of checks would be asserting the same
	// string twice and the header assertion would be alone in the suite.
	ftr_state_leak := line_of(l.footer_y, cols)
	check("the footer no longer carries the state (it moved to the header — RCH-9)",
		!str_contains_ignore_case(ftr_state_leak, "select"),
		fmt.tprintf("footer row {} = '{}' must not contain the state word 'select'", l.footer_y, ftr_state_leak))

	// 7. Footer shows every usable key.
	ftr := line_of(l.footer_y, cols)
	seen := 0
	for k := 0; k < len(UI_KEYS); k += 1 {
		if str_contains_ignore_case(ftr, UI_KEYS[k].key) && str_contains_ignore_case(ftr, UI_KEYS[k].action) {
			seen += 1
		}
	}
	check("footer lists every usable key with its action", seen == len(UI_KEYS),
		fmt.tprintf("{}/{} hints visible", seen, len(UI_KEYS)))

	// 7b. RETENTION AT NARROW WIDTHS (P3-12). The requirement is that the footer
	// shows every USABLE key; at 80–120 columns a mode with 8 hints cannot show
	// all of them. What must never happen is the truncation cutting the "how do I
	// get out" hints while keeping the "what can I start" hints — a footer that
	// says `enter new local session` and not `esc quit` is a trap. These run
	// against keys_line directly (no terminal needed) at the widths a real user
	// has, and they fail if the escape hatch is the thing that got cut.
	// 7b. RETENTION AT NARROW WIDTHS (P3-12), using the REAL mode-selection
	// footer rather than a toy list, because that is the footer the requirement is
	// about. KEYS_MODE is 8 hints / ~102 columns, so at 80 or 100 columns the
	// truncation policy is exercised for real. What must never happen is the cut
	// taking the "how do I get out" hints while keeping the "what can I start"
	// ones: a footer that says `enter new local session` and not `esc quit` is a
	// trap. These checks fail if that happens.
	// Real mode-selection footer: 8 hints, ~102 columns, so 80/100 forces a cut.
	for w in NARROW_WIDTHS {
		ks := KEYS_MODE[:]
		line := ui.keys_line(ks, w)
		last := ks[len(ks)-1]
		check(fmt.tprintf("KEYS_MODE at {} cols still shows the exit hint `{} {}`", w, last.key, last.action),
			str_contains_ignore_case(line, last.key) && str_contains_ignore_case(line, last.action),
			fmt.tprintf("footer = '{}'", line))
		// `t theme` must survive whenever the width could physically hold it next
		// to the exit hint. Below that it is arithmetic, not policy, so it is not
		// asserted — the point of the check is that theme and quit are the LAST
		// things to go, not that they fit in ten columns.
		theme_w := ui.text_cols("t theme")
		quit_w := ui.text_cols("esc quit")
		if w >= theme_w + 2 + quit_w {
			check(fmt.tprintf("KEYS_MODE at {} cols still shows `t theme`", w),
				str_contains_ignore_case(line, "theme"),
				fmt.tprintf("need={} got='{}'", theme_w + 2 + quit_w, line))
		}
		check(fmt.tprintf("KEYS_MODE at {} cols never overflows", w),
			ui.text_cols(line) <= w, fmt.tprintf("cols={} line='{}'", ui.text_cols(line), line))
		parts, _ := strings.split(line, "  ")
		partial := 0
		for p in parts {
			if p == "" || p == "…" { continue }
			if !strings.contains(p, " ") { partial += 1 }
		}
		check(fmt.tprintf("KEYS_MODE at {} cols cuts no hint in half", w),
			partial == 0, fmt.tprintf("partial={} line='{}'", partial, line))
		check(fmt.tprintf("KEYS_MODE at {} cols is not blank", w), line != "", "footer = ''")
	}
	for w in NARROW_WIDTHS {
		line := ui.keys_line(UI_KEYS, w)
		last := UI_KEYS[len(UI_KEYS)-1]
		check(fmt.tprintf("UI_KEYS at {} cols still shows the exit hint `{} {}`", w, last.key, last.action),
			str_contains_ignore_case(line, last.key) && str_contains_ignore_case(line, last.action),
			fmt.tprintf("footer = '{}'", line))

		// The second-to-last hint (`t theme`) must be there whenever the width
		// could physically hold it next to the exit hint. Below that it is a
		// layout impossibility, not a policy failure, so it is not asserted.
		two := UI_KEYS[len(UI_KEYS)-2]
		need := ui.text_cols(fmt.tprintf("{} {}", two.key, two.action)) + 2 +
			ui.text_cols(fmt.tprintf("{} {}", last.key, last.action))
		if w >= need {
			check(fmt.tprintf("UI_KEYS at {} cols also shows `{} {}`", w, two.key, two.action),
				str_contains_ignore_case(line, two.key) && str_contains_ignore_case(line, two.action),
				fmt.tprintf("need={} got='{}'", need, line))
		}

		check(fmt.tprintf("UI_KEYS at {} cols never overflows the width", w),
			ui.text_cols(line) <= w, fmt.tprintf("cols={} line='{}'", ui.text_cols(line), line))
		// Never half a hint: every visible hint must carry BOTH its key and its
		// action, so a cut can never leave a key that does nothing.
		parts, _ := strings.split(line, "  ")
		partial := 0
		for p in parts {
			if p == "" || p == "…" { continue }
			if !strings.contains(p, " ") { partial += 1 }
		}
		check(fmt.tprintf("UI_KEYS at {} cols cuts no hint in half", w),
			partial == 0, fmt.tprintf("partial pieces={} line='{}'", partial, line))
		// And the line is never empty while hints exist.
		check(fmt.tprintf("UI_KEYS at {} cols is not blank", w), line != "",
			fmt.tprintf("footer = ''"))
	}

	// 8. PREDICTED GEOMETRY == CLAY'S GEOMETRY. The view computes its cell box
	//    before EndLayout; this proves the prediction matches Clay's own record,
	//    so no view is laying itself out on a guessed row.
	md := clay.GetElementData(clay.ID(ui.MAIN_ID))
	check("Clay knows the MAIN element", md.found, fmt.tprintf("found={}", md.found))
	check("predicted MAIN box == Clay's MAIN box",
		i32(md.boundingBox.x) == ui.FRAME_PAD &&
			i32(md.boundingBox.y) == l.main_y &&
			i32(md.boundingBox.width) == l.cols &&
			i32(md.boundingBox.height) == l.main_rows,
		fmt.tprintf("clay=({},{},{}x{}) predicted=({},{},{}x{})",
			i32(md.boundingBox.x), i32(md.boundingBox.y),
			i32(md.boundingBox.width), i32(md.boundingBox.height),
			ui.FRAME_PAD, l.main_y, l.cols, l.main_rows))

	hd := clay.GetElementData(clay.ID(ui.HEADER_ID))
	fd := clay.GetElementData(clay.ID(ui.FOOTER_ID))
	check("header and footer sit on their predicted rows",
		i32(hd.boundingBox.y) == l.header_y && i32(fd.boundingBox.y) == l.footer_y &&
			i32(hd.boundingBox.height) == ui.HEADER_ROWS && i32(fd.boundingBox.height) == ui.FOOTER_ROWS,
		fmt.tprintf("header y={} footer y={}", i32(hd.boundingBox.y), i32(fd.boundingBox.y)))

	// 9. The lines arrived as Clay geometry, not as hand-drawn glyphs. Exactly
	//    one border render call exists, and it is the container's betweenChildren
	//    registration (the dividers' source), not a box: the perimeter assertion
	//    above is what proves no outer edge was painted.
	st := scene.last
	check("the two dividers came from Clay's command stream", st.rules >= 2,
		fmt.tprintf("rules={} rects={}", st.rules, st.rects))
	check("exactly one border call, registered as the divider source (RCH-1)",
		st.borders == 1, fmt.tprintf("borders={} (0 would mean no divider source)", st.borders))
	check("no cell errors while painting the frame", st.cell_error == 0,
		fmt.tprintf("cell_error={}", st.cell_error))

	// 10. Alpha is never an identity tag: every palette colour is opaque, so the
	//     only thing alpha can mean in this renderer is "don't paint".
	all_opaque := true
	colours := [11]clay.Color{g_pal.bg, g_pal.fg, g_pal.dim, g_pal.border, g_pal.header_fg,
		g_pal.accent, g_pal.sel_fg, g_pal.caret, g_pal.float_bg, g_pal.float_fg, g_pal.err_fg}
	for j := 0; j < len(colours); j += 1 {
		if colours[j][3] != 255 {
			all_opaque = false
		}
	}
	check("every palette colour is fully opaque (alpha is not an identity tag)", all_opaque,
		fmt.tprintf("all alpha == 255: {}", all_opaque))

	dump_rows("frame: header / rule / main", 0, 0, cols, 6)
	dump_rows("frame: rule / footer", 0, rows-6, cols, 6)
	return !any_failed
}

g_sessions : ui.Sessions

// ═══════════════════════════════════════════════════════════════════════════
// T5.2 — the sessions table
// ═══════════════════════════════════════════════════════════════════════════
sessions_type_key :: proc(ev: ^termbox2.Event) {
	if ev.typ != termbox2.EVENT_KEY || ev.ch == 0 {
		return
	}
	ui.edit_insert_rune(&g_sessions.filter, rune(ev.ch))
	paint_scene()
}

case_ui_sessions :: proc() -> bool {
	say("case ui-sessions — T5.2: four fixed columns, live filter, selection, order")
	if !bring_up() {
		return false
	}
	defer leave_terminal()

	fixture := fixture_rows()
	ordered := sorted_rows(fixture)
	defer delete(fixture)
	defer delete(ordered)

	ui.sessions_init(&g_sessions)
	for i0 := 0; i0 < len(ordered); i0 += 1 {
		say(fmt.tprintf("  fixture[{}]: name='{}' ts='{}' device='{}'",
			i0, ordered[i0].name, app.ts_display(ordered[i0].ts), ordered[i0].device))
	}
	cols := scene.f.cols
	l := scene.l
	body := l.main_rows - 2 // filter line + column header line
	first := l.main_y + 2

	scene.mode = .sessions
	scene.v = &g_sessions
	scene.rows = ordered
	scene.body = body
	scene.first = first
	paint_scene()

	// 1. The filter starts EMPTY, which is the same code path as "filter in use".
	check("filter starts empty", ui.edit_is_empty(&g_sessions.filter),
		fmt.tprintf("filter='{}'", ui.edit_text(&g_sessions.filter)))

	head_row := l.main_y + 1
	head := line_of(head_row, cols)
	check("column header lists device / timestamp / state / name",
		str_contains_ignore_case(head, "device") && str_contains_ignore_case(head, "timestamp") &&
			str_contains_ignore_case(head, "state") && str_contains_ignore_case(head, "name"),
		fmt.tprintf("row {} = '{}'", head_row, head))

	// 2. Column offsets are FIXED by the view. Clay's textAlignment is never used
	//    to make text fit; the widths are, and they add up inside the interior.
	c := ui.sessions_columns(l.cols)
	dev_x := i32(ui.FRAME_PAD)
	ts_x := dev_x + c.device + ui.SESS_COL_GAP
	state_x := ts_x + c.ts + ui.SESS_COL_GAP
	name_x := state_x + c.state + ui.SESS_COL_GAP
	check("columns keep their fixed widths and fit the interior",
		c.device == ui.SESS_W_DEVICE && c.ts == ui.SESS_W_TS &&
			c.state == ui.SESS_W_STATE && name_x+c.name <= cols-ui.FRAME_PAD,
		fmt.tprintf("device={} ts={} state={} name={} interior={}", c.device, c.ts, c.state, c.name, l.cols))

	check("row 1 device cell starts at the device column",
		glyph_at(dev_x, first) == 'l',
		fmt.tprintf("cell({},{}) = {}", dev_x, first, glyph_name(glyph_at(dev_x, first))))
	check("row 1 timestamp cell starts at the timestamp column",
		glyph_at(ts_x, first) == '2',
		fmt.tprintf("cell({},{}) = {}", ts_x, first, glyph_name(glyph_at(ts_x, first))))
	check("row 1 state cell starts at the state column",
		glyph_at(state_x, first) == 'r' || glyph_at(state_x, first) == 's',
		fmt.tprintf("cell({},{}) = {}", state_x, first, glyph_name(glyph_at(state_x, first))))
	check("row 1 name cell starts at the name column",
		rune(ordered[0].name[0]) == rune(glyph_at(name_x, first)),
		fmt.tprintf("cell({},{}) = {}, first session name starts '{}'",
			name_x, first, glyph_name(glyph_at(name_x, first)), ordered[0].name[0]))

	// 3. THE DISPLAY MIRRORS THE MODEL, IN ORDER. Row i must show exactly what
	//    the model's row i says, built through the same column widths the view
	//    used. A view that forgot to sort, sorted differently, or shifted a row
	//    breaks here -- and the fixture is deliberately scrambled, so an
	//    unsorted view would fail rather than get lucky.
	check("the fixture really is out of order (so the sort is doing work)",
		app.compare_session(fixture[0], fixture[3]) > 0 ||
			fixture[0].device != ordered[0].device,
		fmt.tprintf("fixture[0]='{}'/'{}' vs sorted[0]='{}'/'{}'",
			fixture[0].device, fixture[0].name, ordered[0].device, ordered[0].name))
	check("the sorted array satisfies the model comparator", order_satisfied(ordered), "every adjacent pair is <= 0")

	mirror_ok := true
	mirror_why := fmt.tprintf("{} rows mirror the model", len(ordered))
	for i := 0; i < len(ordered); i += 1 {
		got_dev := trim(interior_of(first+i32(i), cols)) // whole interior of the row
		want_dev := ui.ellipsize(ordered[i].device, c.device)
		want_ts := ui.ellipsize(app.ts_display(ordered[i].ts), c.ts)
		want_name := ui.ellipsize(ordered[i].name, c.name)
		got_dev_only := trim(slice_cols(line_of(first+i32(i), cols), dev_x, c.device))
		got_ts_only := trim(slice_cols(line_of(first+i32(i), cols), ts_x, c.ts))
		got_state := trim(slice_cols(line_of(first+i32(i), cols), state_x, c.state))
		got_name := trim(slice_cols(line_of(first+i32(i), cols), name_x, c.name))
		if got_dev_only != trim(want_dev) || got_ts_only != trim(want_ts) || got_name != trim(want_name) {
			mirror_ok = false
			mirror_why = fmt.tprintf("row {}: cells [{}, {}, {}, {}] but the model says [{}, {}, {}, {}]",
				i, got_dev_only, got_ts_only, got_state, got_name,
				trim(want_dev), trim(want_ts), got_state, trim(want_name))
			break
		}
		_ = got_dev
	}
	check("every displayed row mirrors the model row at the same index", mirror_ok, mirror_why)

	// 4. Empty filter shows every row.
	shown := rows_with_text(first, int(body), cols)
	check("empty filter shows every session", shown == len(ordered),
		fmt.tprintf("{} non-empty rows in a {}-row window, {} sessions", shown, body, len(ordered)))

	// 5. THE SELECTION HIGHLIGHT IS APP STATE, RENDERED, NOT ASSUMED.
	g_sessions.sel = app.selection_of(&ordered[1])
	g_sessions.scroll = 0
	paint_scene()
	sel_bg := paint_attr(g_pal.accent)
	sel_row := first + 1
	chosen := cell_at(name_x, sel_row).bg
	other := cell_at(name_x, first).bg
	check("selection highlight is the app's chosen colour, on the selected row only",
		chosen == sel_bg && other != sel_bg,
		fmt.tprintf("selected row bg={} neighbour row bg={} want {}", chosen, other, sel_bg))
	check("selection resolved from the (device,name) identity, not an index",
		g_sessions.sel.valid && g_sessions.sel.device == ordered[1].device &&
			g_sessions.sel.name == ordered[1].name,
		fmt.tprintf("sel='{}'/'{}'", g_sessions.sel.device, g_sessions.sel.name))

	// 6. A HELD IDENTITY against a row set that does not contain it resolves
	//    to "gone" (-1) rather than silently jumping onto another row.
	zrows := ui_filtered(ordered, "zeta")
	li := ui.sessions_selected_index(&g_sessions, zrows)
	check("a held identity against a different row set resolves to -1", li == -1,
		fmt.tprintf("index against zeta-only rows = {} (held '{}')", li, ordered[1].name))
	delete(zrows)

	// 7. LIVE FILTER, TYPED THROUGH THE PTY: every byte arrives as a real tb_event.
	before := shown
	st := feed(sessions_type_key, 64)
	ft := ui.edit_text(&g_sessions.filter)
	say(fmt.tprintf("  typed {} keys over the pty; filter is now '{}'", st.keys, ft))
	after := rows_with_text(first, int(body), cols)
	check("filter is live: the window narrowed as it was typed",
		len(ft) > 0 && after > 0 && after < before,
		fmt.tprintf("{} rows before -> {} rows after '{}'", before, after, ft))
	leaked := first_row_not_matching(first, int(body), cols, name_x, c.name, ft)
	check("every row still visible contains the filter text", leaked == "",
		fmt.tprintf("filter='{}' leaked: {}", ft, leaked))

	dump_rows("sessions: filter + header + rows", 0, l.main_y-1, cols, 8)
	return !any_failed
}

ui_filtered :: proc(rows: []app.Session, filter: string) -> []app.Session {
	out: [dynamic]app.Session
	for i := 0; i < len(rows); i += 1 {
		if ui.sessions_match(rows[i], filter) {
			append(&out, rows[i])
		}
	}
	return out[:]
}

// order_satisfied checks the display ordering property directly against the
// model comparator: adjacent rows must never go backwards.
order_satisfied :: proc(rows: []app.Session) -> bool {
	for i := 1; i < len(rows); i += 1 {
		if app.compare_session(rows[i-1], rows[i]) > 0 {
			return false
		}
	}
	return true
}

dev_group :: proc(device: string) -> int {
	if device == app.DEVICE_LOCAL {
		return 0
	}
	return 1
}

trim_left :: proc(s: string) -> string {
	i := 0
	for i < len(s) {
		if s[i] != ' ' {
			break
		}
		i += 1
	}
	return s[i:]
}

// interior_of returns only the cells the view owns (between the border
// columns). Counting raw lines instead counted the frame itself, which made
// every row on screen look like a populated session row.
interior_of :: proc(y: i32, cols: i32) -> string {
	return slice_cols(line_of(y, cols), i32(ui.FRAME_PAD), cols-2*i32(ui.FRAME_PAD))
}

trim :: proc(s: string) -> string {
	return strings.trim(strings.trim_left(s, " "), " ")
}

rows_with_text :: proc(first: i32, n: int, cols: i32) -> int {
	k := 0
	for i := 0; i < n; i += 1 {
		if len(trim(interior_of(first+i32(i), cols))) > 0 {
			k += 1
		}
	}
	return k
}

// first_row_not_matching returns the first visible row whose name column does NOT
// contain the filter, so a failure names the row that leaked through rather than
// just saying "false". "" means every visible row matched.
first_row_not_matching :: proc(first: i32, n: int, cols: i32, name_x, name_w: i32, needle: string) -> string {
	if len(needle) == 0 {
		return ""
	}
	for i := 0; i < n; i += 1 {
		name := trim(slice_cols(line_of(first+i32(i), cols), name_x, name_w))
		if len(name) > 0 && !str_contains_ignore_case(name, needle) {
			return fmt.tprintf("row {}: '{}'", i, name)
		}
	}
	return ""
}

// slice_cols cuts a DISPLAY-COLUMN range out of an already-rendered line, so the
// helpers read the grid the way a terminal would.
slice_cols :: proc(line: string, start, count: i32) -> string {
	b: [dynamic]byte
	used: i32 = 0
	for r in line {
		w := cols_of(r)
		if w <= 0 {
			w = 1
		}
		if used >= start && used < start+count {
			push_str(&b, fmt.tprintf("{}", r))
		}
		used += w
		if used >= start+count {
			break
		}
	}
	return string(b[:]) // shares the buffer; the driver exits after the report
}

// ═══════════════════════════════════════════════════════════════════════════
// T5.2 — a real terminal shrink re-clamps the selection
// ═══════════════════════════════════════════════════════════════════════════
case_ui_shrink :: proc() -> bool {
	say("case ui-shrink — T5.2: a real resize re-clamps the selection; nothing is lost")
	if !bring_up() {
		return false
	}
	defer leave_terminal()

	ordered := sorted_rows(fixture_rows())
	defer delete(ordered)

	ui.sessions_init(&g_sessions)
	last := len(ordered) - 1
	g_sessions.sel = app.selection_of(&ordered[last])

	l := scene.l
	body := l.main_rows - 2
	scene.mode = .sessions
	scene.v = &g_sessions
	scene.rows = ordered
	scene.body = body
	scene.first = l.main_y + 2

	ui.sessions_clamp(&g_sessions, ordered, body)
	say(fmt.tprintf("  before: {}x{} body={} sel='{}'/'{}' scroll={}",
		scene.f.cols, scene.f.rows, body, g_sessions.sel.device, g_sessions.sel.name, g_sessions.scroll))
	check("selection is on screen before the shrink",
		i32(last) >= g_sessions.scroll && i32(last) < g_sessions.scroll+body,
		fmt.tprintf("sel idx {} inside [{},{})", last, g_sessions.scroll, g_sessions.scroll+body))
	paint_scene()

	// --- shrink 1: a real TIOCSWINSZ on our own tty -> SIGWINCH -> tb resize --
	got := shrink_pty(16, 80)
	check("TB_EVENT_RESIZE arrived after a real resize", got, fmt.tprintf("seen={}", got))
	cc, rr := termbox2.tb_width(), termbox2.tb_height()
	say(fmt.tprintf("  after shrink 1: {}x{}", cc, rr))
	old_cols, old_rows := scene.p.cols, scene.p.rows
	ui.painter_resize(scene.p, cc, rr)
	scene.f.cols = cc
	scene.f.rows = rr
	l2 := ui.frame_layout(cc, rr)
	scene.l = l2
	body2 := l2.main_rows - 2
	first2 := l2.main_y + 2
	check("the window really got smaller", body2 < body && cc < old_cols && rr < old_rows,
		fmt.tprintf("cols {} -> {}, rows {} -> {}, body {} -> {}",
			old_cols, cc, old_rows, rr, body, body2))

	ui.sessions_clamp(&g_sessions, ordered, body2)
	idx := ui.sessions_selected_index(&g_sessions, ordered)
	check("the selection SURVIVED the shrink", idx == last,
		fmt.tprintf("identity resolves to row {} (was {})", idx, last))
	check("the selection is VISIBLE after the shrink",
		i32(idx) >= g_sessions.scroll && i32(idx) < g_sessions.scroll+body2,
		fmt.tprintf("sel idx {} inside [{},{})", idx, g_sessions.scroll, g_sessions.scroll+body2))
	check("scroll is clamped to the new window",
		g_sessions.scroll >= 0 && g_sessions.scroll <= i32(max(0, len(ordered)-int(body2))),
		fmt.tprintf("scroll={} max_allowed={}", g_sessions.scroll, i32(max(0, len(ordered)-int(body2)))))
	scene.body = body2
	scene.first = first2
	paint_scene()

	// Read the highlight back at its NEW screen row and confirm the selected
	// session's own name is sitting under it.
	sel_bg := paint_attr(g_pal.accent)
	row_y := first2 + i32(idx) - g_sessions.scroll
	cell := cell_at(60, row_y)
	check("the selected row is highlighted at its new screen row",
		cell.bg == sel_bg,
		fmt.tprintf("y={} bg={} want {}", row_y, cell.bg, sel_bg))
	why := line_of(row_y, cc)
	check("the row under the highlight is still the selected session",
		strings.contains(why, ordered[idx].name),
		fmt.tprintf("row {} = '{}'", row_y, why))

	// --- shrink 2: brutal. A handful of visible rows, selection still the last --
	got2 := shrink_pty(12, 60)
	check("second real resize arrived", got2, fmt.tprintf("seen={}", got2))
	cc2, rr2 := termbox2.tb_width(), termbox2.tb_height()
	ui.painter_resize(scene.p, cc2, rr2)
	scene.f.cols = cc2
	scene.f.rows = rr2
	l3 := ui.frame_layout(cc2, rr2)
	scene.l = l3
	body3 := l3.main_rows - 2
	ui.sessions_clamp(&g_sessions, ordered, body3)
	check("after a second shrink the selection is still the SAME session",
		g_sessions.sel.name == ordered[last].name && g_sessions.sel.device == ordered[last].device,
		fmt.tprintf("sel='{}'/'{}' body={}", g_sessions.sel.device, g_sessions.sel.name, body3))
	check("and it is still on screen",
		i32(idx) >= g_sessions.scroll && i32(idx) < g_sessions.scroll+body3,
		fmt.tprintf("sel idx {} inside [{},{})", idx, g_sessions.scroll, g_sessions.scroll+body3))
	check("the new window is genuinely tiny (so the clamp is doing real work)",
		body3 <= 4, fmt.tprintf("body3={}", body3))
	scene.body = body3
	scene.first = l3.main_y + 2
	paint_scene()
	dump_rows("shrunk frame", 0, 0, min(60, cc2), min(12, rr2))
	return !any_failed
}

// ═══════════════════════════════════════════════════════════════════════════
// T5.3 — the edit field
// ═══════════════════════════════════════════════════════════════════════════
g_edit : ui.Edit

edit_type_key :: proc(ev: ^termbox2.Event) {
	if ev.typ != termbox2.EVENT_KEY || ev.ch == 0 {
		return
	}
	ui.edit_insert_rune(&g_edit, rune(ev.ch))
	paint_scene()
}

case_ui_edit :: proc() -> bool {
	say("case ui-edit — T5.3: caret is a DISPLAY column; CJK/emoji typed+pasted never desync")
	if !bring_up() {
		return false
	}
	defer leave_terminal()

	l := scene.l
	cols := scene.f.cols
	ui.edit_init(&g_edit)
	scene.mode = .edit
	scene.e = &g_edit
	scene.edit_w = l.cols - 4
	edit_y := l.main_y
	edit_x0 := i32(ui.FRAME_PAD)
	paint_scene()

	// 1. TYPE mixed-width runes THROUGH THE PTY: "a世b😀c".
	expect := "a世b😀c"
	st := feed(edit_type_key, 64)
	say(fmt.tprintf("  {} key events read from the pty", st.keys))
	got := ui.edit_text(&g_edit)
	check("what the pty delivered is what the buffer holds", got == expect,
		fmt.tprintf("buffer='{}' want='{}'", got, expect))

	want_caret := ui.text_cols(expect)
	check("caret column == display width of the prefix, never the byte length",
		ui.edit_caret_col(&g_edit) == want_caret,
		fmt.tprintf("caret_col={} display={} bytes={}", ui.edit_caret_col(&g_edit), want_caret, len(expect)))
	check("the byte/display gap is real (a byte caret would drift by {} cells)",
		i32(len(expect)) != want_caret,
		fmt.tprintf("bytes={} cells={} gap={}", len(expect), want_caret, i32(len(expect))-want_caret))

	// 2. Find the caret's ACTUAL cell and prove it sits at the derived column.
	//    The caret is a PAIR (RCH-10 change 3): the block cell must carry BOTH
	//    caret_fg (the glyph) and caret_bg (the cell it is knocked out of).
	//    Matching on fg alone would let a caret painted over the wrong
	//    background pass, which is not the requirement.
	caret_fg_attr := paint_attr(g_pal.caret_fg)
	caret_bg_attr := paint_attr(g_pal.caret_bg)
	check("the caret glyph is the fat block U+2588, not the old thin bar U+258F",
		ui.CARET_GLYPH == '█',
		fmt.tprintf("CARET_GLYPH={}", glyph_name(ui.CARET_GLYPH)))
	found := i32(-1)
	x: i32 = 0
	for x < cols {
		c := cell_at(x, edit_y)
		if c.ch == u32(ui.CARET_GLYPH) && c.fg == caret_fg_attr && c.bg == caret_bg_attr {
			found = x
			break
		}
		x += 1
	}
	check("caret glyph is painted exactly at the derived display column",
		found == edit_x0+want_caret,
		fmt.tprintf("caret cell x={} expected {} (pad {} + {} cells)", found, edit_x0+want_caret, ui.FRAME_PAD, want_caret))
	check("the cell immediately left of the caret is the last rune typed",
		glyph_at(found-1, edit_y) == 'c',
		fmt.tprintf("left of caret = {}", glyph_name(glyph_at(found-1, edit_y))))

	// Walk every cell from the start of the field to the caret: the glyphs must
	// have consumed EXACTLY caret_col cells. Zero drift, no half glyph.
	walked: i32 = 0
	x = edit_x0
	for x < found {
		r := rune(cell_at(x, edit_y).ch)
		w := cols_of(r)
		if w <= 0 {
			w = 1
		}
		walked += w
		x += w
	}
	check("cells consumed by the typed glyphs == caret column (zero drift)",
		walked == want_caret, fmt.tprintf("walked {} cells to reach the caret at {}", walked, want_caret))

	// 2b. THE CARET REPORTS ITS OWN CELL. edit_caret_cell asks Clay for the box
	//     it gave the caret element — that is the coordinate the real terminal
	//     cursor is aimed at, so it must equal the cell the block was painted
	//     into. If the two ever disagree, the cursor points somewhere the caret
	//     is not.
	ccx, ccy, ccok := ui.edit_caret_cell(&g_edit)
	check("the caret element reported a cell of its own", ccok,
		fmt.tprintf("ok={}", ccok))
	check("…and that cell IS the painted caret cell (the cursor aims where the block is)",
		ccx == found && ccy == edit_y,
		fmt.tprintf("clay cell=({},{}) painted cell=({},{})", ccx, ccy, found, edit_y))

	// 3. WHOLE-RUNE BACKSPACE.
	ui.edit_backspace(&g_edit)
	check("backspace removed the whole 'c'", ui.edit_text(&g_edit) == "a世b😀",
		fmt.tprintf("buffer='{}'", ui.edit_text(&g_edit)))
	ui.edit_backspace(&g_edit)
	check("backspace removed the whole emoji (4 bytes / 2 cells) in one go",
		ui.edit_text(&g_edit) == "a世b",
		fmt.tprintf("buffer='{}' caret_col={}", ui.edit_text(&g_edit), ui.edit_caret_col(&g_edit)))
	ui.edit_backspace(&g_edit)
	ui.edit_backspace(&g_edit)
	check("backspace removed 'b' then the whole 3-byte CJK rune cleanly",
		ui.edit_text(&g_edit) == "a",
		fmt.tprintf("buffer='{}' caret_col={}", ui.edit_text(&g_edit), ui.edit_caret_col(&g_edit)))
	no_stray := true
	bb := transmute([]u8)(ui.edit_text(&g_edit))
	for i := 0; i < len(bb); i += 1 {
		if bb[i] >= 0x80 && bb[i] <= 0xBF {
			no_stray = false
		}
	}
	check("wide-rune backspace left no stray continuation byte", no_stray,
		fmt.tprintf("bytes: {}", byte_list(ui.edit_text(&g_edit))))

	// 4. PASTE IS SANITISED: control chars and embedded escapes never enter.
	ui.edit_clear(&g_edit)
	nasty := "hi\x1b[200~世\t\r\n\x07😀\x7f\x00"
	accepted := ui.edit_paste(&g_edit, nasty)
	say(fmt.tprintf("  pasted {} bytes -> {} runes survived", len(nasty), accepted))
	check("only drawable runes survived the paste (ESC sequence, control chars and NUL all dropped)",
		ui.edit_text(&g_edit) == "hi世😀",
		fmt.tprintf("buffer='{}'", ui.edit_text(&g_edit)))
	check("no ESC / CSI / CR / LF / BEL / DEL byte survived",
		!has_any_byte(ui.edit_text(&g_edit), "\x1b\t\r\n\x07\x7f"),
		fmt.tprintf("buffer bytes: {}", byte_list(ui.edit_text(&g_edit))))
	check("pasted CJK+emoji width is right: 2 + 2 + 2 = 6 cells",
		ui.edit_caret_col(&g_edit) == 6,
		fmt.tprintf("caret_col={}", ui.edit_caret_col(&g_edit)))
	paint_scene()
	check("after the paste the caret still lands on its derived cell",
		glyph_at(edit_x0+ui.edit_caret_col(&g_edit), edit_y) == ui.CARET_GLYPH,
		fmt.tprintf("cell({},{}) = {}", edit_x0+ui.edit_caret_col(&g_edit), edit_y,
			glyph_name(glyph_at(edit_x0+ui.edit_caret_col(&g_edit), edit_y))))

	// 5. A narrow window keeps the caret inside, in DISPLAY COLUMNS.
	small : i32 = 6
	sv := ui.edit_view(&g_edit, small)
	check("a narrow window keeps the caret inside it",
		sv.caret_x >= 0 && sv.caret_x < small,
		fmt.tprintf("caret_x={} window={} scroll={}", sv.caret_x, small, sv.scroll))
	ui.edit_insert_rune(&g_edit, '尾')
	sv2 := ui.edit_view(&g_edit, small)
	check("typing past the edge scrolls the window; caret still inside",
		sv2.caret_x < small && sv2.scroll > 0,
		fmt.tprintf("caret_x={} scroll={} text='{}'", sv2.caret_x, sv2.scroll, ui.edit_text(&g_edit)))
	vis := ui.text_cols(sv2.prefix) + 1 + ui.text_cols(sv2.suffix)
	check("the visible slice never exceeds the window width",
		vis <= small, fmt.tprintf("visible cells {} <= window {}", vis, small))

	// 6. Rune-wise caret movement: left/right land on rune boundaries, so a
	//    display column always exists for the caret.
	ui.edit_clear(&g_edit)
	ui.edit_paste(&g_edit, "世a界")
	ui.edit_left(&g_edit)
	check("caret left of the trailing wide rune sits at column 3",
		ui.edit_caret_col(&g_edit) == 3,
		fmt.tprintf("caret_col={} text='{}'", ui.edit_caret_col(&g_edit), ui.edit_text(&g_edit)))
	ui.edit_left(&g_edit)
	ui.edit_left(&g_edit)
	check("two more whole-rune steps back to column 0",
		ui.edit_caret_col(&g_edit) == 0, fmt.tprintf("caret_col={}", ui.edit_caret_col(&g_edit)))
	ui.edit_right(&g_edit)
	check("one whole-rune step right lands on column 2 (the CJK rune's width)",
		ui.edit_caret_col(&g_edit) == 2, fmt.tprintf("caret_col={}", ui.edit_caret_col(&g_edit)))

	// 7. RIGHT-then-LEFT is an exact round trip at EVERY boundary, across a
	//    string that mixes all three width classes: ASCII (1 cell), CJK (2
	//    cells) and an astral emoji (2 cells). A byte-stepping caret would come
	//    back on a different column every time it crossed a multi-byte rune; a
	//    cell-blind caret would step one cell across a two-cell glyph.
	ui.edit_clear(&g_edit)
	ui.edit_paste(&g_edit, expect)
	// a=1 世=2 b=1 😀=2 c=1 -> the caret column after each whole-rune step right
	want_steps := [5]i32{1, 3, 4, 6, 7}
	back := 0
	for ui.edit_left(&g_edit) {
		back += 1
	}
	check("five whole-rune steps LEFT reach column 0 and then stop",
		back == 5 && ui.edit_caret_col(&g_edit) == 0,
		fmt.tprintf("steps={} caret_col={}", back, ui.edit_caret_col(&g_edit)))

	// Walk RIGHT rune by rune. At each boundary: step right, step left back over
	// the same rune (must restore the column exactly), then step right again and
	// confirm the caret is back on the column it had. Every boundary in the
	// string gets the round trip, and the sequence of columns reached is itself
	// the whole-rune-width evidence.
	seen: [dynamic]i32
	rt_ok := true
	rt_detail := ""
	for i := 0; i < 5; i += 1 {
		from := ui.edit_caret_col(&g_edit)
		ui.edit_right(&g_edit)
		to := ui.edit_caret_col(&g_edit)
		append(&seen, to)
		ui.edit_left(&g_edit)
		if ui.edit_caret_col(&g_edit) != from {
			rt_ok = false
			rt_detail = fmt.tprintf("{} step{}: right->{} then left->{} not {}", rt_detail, i+1,
				to, ui.edit_caret_col(&g_edit), from)
		}
		ui.edit_right(&g_edit)
		if ui.edit_caret_col(&g_edit) != to {
			rt_ok = false
			rt_detail = fmt.tprintf("{} step{}: re-right->{} not {}", rt_detail, i+1,
				ui.edit_caret_col(&g_edit), to)
		}
	}
	check("the forward walk crosses exactly the rune boundaries [1,3,4,6,7]",
		len(seen) == 5 && seen[0] == want_steps[0] && seen[1] == want_steps[1] &&
			seen[2] == want_steps[2] && seen[3] == want_steps[3] && seen[4] == want_steps[4],
		fmt.tprintf("seen={} want={}", seen, want_steps[:]))
	check("right-then-left at EVERY boundary restores the caret's derived column",
		rt_ok, fmt.tprintf("{}buffer='{}'", rt_detail, ui.edit_text(&g_edit)))
	check("…and the walk ends on the derived end column (display width, not bytes)",
		ui.edit_caret_col(&g_edit) == want_caret,
		fmt.tprintf("caret_col={} want={}", ui.edit_caret_col(&g_edit), want_caret))
	// The caret DRIVES insertion: parked one rune from the end (col 6, just
	// before the 'c'), a typed rune lands BEFORE the last rune.
	ui.edit_left(&g_edit)
	ui.edit_insert_rune(&g_edit, 'X')
	check("typing at a caret parked mid-field inserts AT the caret",
		ui.edit_text(&g_edit) == "a世b😀Xc",
		fmt.tprintf("buffer='{}' caret_col={}", ui.edit_text(&g_edit), ui.edit_caret_col(&g_edit)))

	dump_rows("edit field", 0, edit_y, cols, 1)
	return !any_failed
}

has_any_byte :: proc(s: string, bad: string) -> bool {
	for i := 0; i < len(s); {
		j := 0
		for j < len(bad) {
			if s[i] == bad[j] {
				return true
			}
			j += 1
		}
		i += 1
	}
	return false
}

byte_list :: proc(s: string) -> string {
	buf: [dynamic]byte
	b := transmute([]u8)(s)
	for i := 0; i < len(b); i += 1 {
		push_str(&buf, fmt.tprintf("{:02x} ", b[i]))
	}
	// NOTE: no delete here. `string(buf[:])` shares the buffer's memory, so
	// freeing it would leave the returned string dangling (which is exactly the
	// mojibake this helper produced the first time). The driver allocates from the
	// context allocator and exits right after the report, so these live for the
	// run on purpose.
	return string(buf[:])
}

// ═══════════════════════════════════════════════════════════════════════════
// T5.3 — the shared filtered list (theme picker + remote picker)
// ═══════════════════════════════════════════════════════════════════════════
g_list : ui.List

list_key :: proc(ev: ^termbox2.Event) {
	if ev.typ != termbox2.EVENT_KEY {
		return
	}
	moved := false
	if key_is(ev, termbox2.KEY_ARROW_DOWN) || key_is(ev, termbox2.KEY_TAB) {
		ui.list_move(&g_list, 1, scene.l.main_rows)
		list_down += 1
		moved = true
	} else if key_is(ev, termbox2.KEY_ARROW_UP) || key_is(ev, termbox2.KEY_BACK_TAB) {
		ui.list_move(&g_list, -1, scene.l.main_rows)
		moved = true
	} else if ev.ch != 0 && ui.edit_is_drawable(rune(ev.ch)) {
		// A printable key is a keystroke into the filter: live narrowing goes
		// through the same apply() the state machine will call.
		ui.edit_insert_rune(&g_list.filter, rune(ev.ch))
		ui.list_apply(&g_list, scene.list_rows)
		list_typed += 1
		moved = true // the filtered set changed: repaint so the screen matches state
	}
	if moved {
		paint_scene()
	}
}

list_down : int = 0 // down-arrow AND tab: they drive the same movement op
list_typed : int = 0

theme_id :: proc(t: string) -> string {
	return t
}
theme_detail :: proc(t: string) -> string {
	return "palette"
}
remote_id :: proc(r: app.Remote) -> string {
	return r.device
}
remote_label_of :: proc(r: app.Remote) -> string {
	return app.remote_label(r)
}
remote_detail_of :: proc(r: app.Remote) -> string {
	if r.label != "" {
		return r.label
	}
	return ""
}

case_ui_list :: proc() -> bool {
	say("case ui-list — T5.3: ONE list for both pickers; move / filter / enter / no-op")
	if !bring_up() {
		return false
	}
	defer leave_terminal()

	l := scene.l

	// Two DIFFERENT item types through ONE list, which is the whole point of the
	// shared implementation: the theme picker and the remote picker are the same
	// code over different projections.
	themes := make([]string, 4)
	themes[0] = "gruvbox-dark"
	themes[1] = "solarized-light"
	themes[2] = "tokyo-night"
	themes[3] = "catppuccin"
	remotes := make([]app.Remote, 3)
	remotes[0] = app.Remote{device = "prod.example", label = "prod"}
	remotes[1] = app.Remote{device = "dev.example", label = "dev-box"}
	remotes[2] = app.Remote{device = app.DEVICE_LOCAL, label = ""}

	theme_rows := ui.picker_rows(themes, theme_id, theme_id, theme_detail)
	defer delete(theme_rows)
	remote_rows := ui.picker_rows(remotes, remote_id, remote_label_of, remote_detail_of)
	defer delete(remote_rows)

	// ── theme picker ──
	ui.list_init(&g_list)
	ui.list_apply(&g_list, theme_rows)
	scene.mode = .list
	scene.list = &g_list
	scene.list_rows = theme_rows
	paint_scene()
	check("theme list shows every item with an empty filter",
		ui.list_count(&g_list) == len(themes),
		fmt.tprintf("{} shown of {}", ui.list_count(&g_list), len(themes)))
	check("nothing is selected at the start", g_list.sel == -1, fmt.tprintf("sel={}", g_list.sel))

	before := g_list.sel
	_, picked := ui.list_pick(&g_list, theme_rows)
	check("enter with no selection picks nothing and changes nothing",
		!picked && g_list.sel == before,
		fmt.tprintf("picked={} sel={} (unchanged)", picked, g_list.sel))

	// Everything piped into the pty arrives in one go: down, down, tab, then the
	// two characters "to". So this single read covers movement AND filtering.
	st := feed(list_key, 64)
	say(fmt.tprintf("  list keys off the pty: {} total ({} movement, {} typed)",
		st.keys, list_down, list_typed))
	check("the movement keys and the typed characters both arrived",
		list_down == 3 && list_typed == 2,
		fmt.tprintf("movement={} typed={}", list_down, list_typed))
	check("typing narrowed the list to the one surviving theme",
		ui.list_count(&g_list) == 1, fmt.tprintf("after 'to' -> {} shown", ui.list_count(&g_list)))
	one, ok1 := ui.list_pick(&g_list, theme_rows)
	check("the surviving theme is tokyo-night", ok1 && one.id == "tokyo-night",
		fmt.tprintf("id='{}'", one.id))
	check("the selection followed the SAME identity through the filter", g_list.sel == 0,
		fmt.tprintf("sel={} (list has {} row)", g_list.sel, ui.list_count(&g_list)))

	sel_bg := paint_attr(g_pal.accent)
	row_y := l.main_y + i32(g_list.sel) - g_list.scroll
	check("the selected list row carries the highlight in the cells",
		cell_at(6, row_y).bg == sel_bg,
		fmt.tprintf("y={} bg={} want {}", row_y, cell_at(6, row_y).bg, sel_bg))
	check("the unselected rows below it are NOT highlighted",
		cell_at(6, row_y+1).bg != sel_bg,
		fmt.tprintf("y={} bg={}", row_y+1, cell_at(6, row_y+1).bg))

	// Filter to nothing: no selection, so enter must be a no-op again.
	ui.edit_insert_rune(&g_list.filter, 'z')
	ui.list_apply(&g_list, theme_rows)
	paint_scene()
	check("a filter matching nothing empties the list",
		ui.list_count(&g_list) == 0, fmt.tprintf("shown={}", ui.list_count(&g_list)))
	_, none1 := ui.list_pick(&g_list, theme_rows)
	check("enter on an empty list is a no-op", !none1, fmt.tprintf("picked={}", none1))
	emptied := trim(interior_of(l.main_y, scene.f.cols))
	check("the empty list says so instead of drawing a phantom row",
		str_contains_ignore_case(emptied, "nothing matches"),
		fmt.tprintf("row = '{}'", emptied))

	// ── remote picker: SAME code, different item type ──
	ui.list_init(&g_list)
	ui.list_apply(&g_list, remote_rows)
	// The scene must point at the NEW row set or the repaint would keep painting
	// the theme picker over the remote one.
	scene.list_rows = remote_rows
	ui.list_select_to(&g_list, 1, l.main_rows)
	paint_scene()
	r1, ok2 := ui.list_pick(&g_list, remote_rows)
	check("the same list serves the remote picker", ok2 && r1.id == "dev.example",
		fmt.tprintf("picked device='{}'", r1.id))
	check("the remote picker's rows are labelled by the model's label, not the device",
		str_contains_ignore_case(trim(interior_of(l.main_y+1, scene.f.cols)), "dev-box"),
		fmt.tprintf("row 1 = '{}'", trim(interior_of(l.main_y+1, scene.f.cols))))
	for ch in "loc" {
		ui.edit_insert_rune(&g_list.filter, ch)
	}
	ui.list_apply(&g_list, remote_rows)
	paint_scene()
	check("remote filter on the device substring works",
		ui.list_count(&g_list) == 1, fmt.tprintf("after 'loc' -> {}", ui.list_count(&g_list)))
	check("when the held row is filtered out the selection is dropped, not moved onto a neighbour",
		g_list.sel == -1, fmt.tprintf("sel={} (held 'dev.example' is gone)", g_list.sel))
	ui.list_move(&g_list, 1, l.main_rows)
	r2, ok3 := ui.list_pick(&g_list, remote_rows)
	check("selecting the surviving remote gives local", ok3 && r2.id == app.DEVICE_LOCAL,
		fmt.tprintf("id='{}'", r2.id))
	dump_rows("picker", 0, l.main_y, scene.f.cols, 4)
	return !any_failed
}

// ═══════════════════════════════════════════════════════════════════════════
// T5.3 — the floating error pane
// ═══════════════════════════════════════════════════════════════════════════
g_float : ui.Float

case_ui_float :: proc() -> bool {
	say("case ui-float — T5.3: the pane floats over everything; Enter/Esc dismiss")
	if !bring_up() {
		return false
	}
	defer leave_terminal()

	cols := scene.f.cols
	rows := scene.f.rows
	l := scene.l
	body := l.main_rows - 2

	ordered := sorted_rows(fixture_rows())
	defer delete(ordered)
	ui.sessions_init(&g_sessions)

	scene.mode = .sessions
	scene.v = &g_sessions
	scene.rows = ordered
	scene.body = body
	scene.first = l.main_y + 2
	paint_scene()
	snap := grid_snapshot(cols, rows)
	defer delete(snap)

	g_float = ui.Float{
		title   = "ssh failed: dev.example",
		lines   = []string{"exit 255 — connection refused", "could not read the remote session list"},
		dismiss = ui.float_dismiss_hint(),
	}
	fw, fh := ui.float_size(&g_float, l.cols)
	say(fmt.tprintf("  the pane is {}x{} inside a {}x{} terminal", fw, fh, cols, rows))

	scene.mode = .sessions_float
	scene.flt = &g_float
	paint_scene()

	// Find the pane by its title, then check the box Clay laid out around it.
	title_row := i32(-1)
	y: i32 = 0
	for y < rows && title_row < 0 {
		if str_contains_ignore_case(line_of(y, cols), "ssh failed") {
			title_row = y
		}
		y += 1
	}
	check("the pane is on screen with its error title", title_row > 0,
		fmt.tprintf("title on row {}", title_row))
	if title_row < 0 {
		return false
	}

	// The pane covers title_row-1 .. title_row-1+fh. Every one of those rows
	// differs from the no-pane snapshot: it paints OVER the table.
	covered := 0
	ry: i32 = title_row - 1
	for ry < title_row-1+fh && ry < rows {
		differs := false
		x: i32 = 0
		for x < cols {
			if glyph_at(x, ry) != grid_at(snap, cols, x, ry) {
				differs = true
				break
			}
			x += 1
		}
		if differs {
			covered += 1
		}
		ry += 1
	}
	check("the pane paints over the table underneath it",
		covered >= int(fh)-1,
		fmt.tprintf("{} of {} pane rows differ from the no-pane screen", covered, fh))

	// FLOATING: opening the pane moved NOTHING outside it — the rows above the
	// pane are byte-identical to the snapshot.
	above_ok := true
	changed_col := i32(-1)
	x := i32(0)
	for x < cols {
		if glyph_at(x, l.main_y) != grid_at(snap, cols, x, l.main_y) {
			above_ok = false
			changed_col = x
			break
		}
		x += 1
	}
	check("content ABOVE the pane did not move when it opened", above_ok,
		fmt.tprintf("first changed column: {}", changed_col))

	// CENTERED on the root, measured from the pane's own corner glyphs. The outer
	// frame's corners sit at x=0 / x=cols-1, so any interior corner belongs to
	// the pane.
	pane_tl := i32(-1)
	pane_tr := i32(-1)
	pane_top := i32(-1)
	for cy := i32(1); cy < rows; cy += 1 {
		for cx := i32(1); cx < cols-1; cx += 1 {
			if glyph_at(cx, cy) == '┌' {
				pane_tl = cx
				pane_top = cy
			}
			if glyph_at(cx, cy) == '┐' {
				pane_tr = cx
			}
		}
	}
	left_inset := pane_tl
	right_inset := cols - 1 - pane_tr
	check("the pane's own corners were found inside the frame",
		pane_tl > 0 && pane_tr > pane_tl && pane_top > 0,
		fmt.tprintf("left x={} right x={} top row={}", pane_tl, pane_tr, pane_top))
	check("the pane is centred on the root (insets equal within one cell)",
		left_inset > 0 && abs_int(left_inset-right_inset) <= 1,
		fmt.tprintf("left inset={} right inset={}", left_inset, right_inset))

	err_attr := paint_attr(g_pal.err_fg)
	border_cell := cell_at(pane_tl, pane_top)
	check("the pane's border is drawn in the error colour",
		border_cell.fg == err_attr && glyph_at(pane_tl, pane_top) == '┌',
		fmt.tprintf("cell({},{}) fg={} ch={} want fg={}", pane_tl, pane_top,
			border_cell.fg, glyph_name(glyph_at(pane_tl, pane_top)), err_attr))

	// Dismissal lives HERE, next to the pane.
	enter_ev := termbox2.Event{typ = termbox2.EVENT_KEY, key = termbox2.KEY_ENTER, ch = 0x0d}
	esc_ev := termbox2.Event{typ = termbox2.EVENT_KEY, key = termbox2.KEY_ESC, ch = 0x1b}
	x_ev := termbox2.Event{typ = termbox2.EVENT_KEY, key = 0, ch = 'x'}
	check("Enter dismisses the pane", ui.float_is_dismiss_key(&enter_ev), "enter event")
	check("Escape dismisses the pane", ui.float_is_dismiss_key(&esc_ev), "esc event")
	check("a printable key does NOT dismiss the pane", !ui.float_is_dismiss_key(&x_ev), "'x' event")

	// Live: type the dismiss key into the pty and watch the pane go away.
	float_shown = true
	st := feed(float_dismiss_only, 32)
	check("the dismiss key typed into the pty closed the pane",
		!float_shown && st.keys > 0, fmt.tprintf("keys={} shown={}", st.keys, float_shown))

	scene.mode = .sessions
	paint_scene()
	gone := true
	y = 0
	for y < rows {
		if str_contains_ignore_case(line_of(y, cols), "ssh failed") {
			gone = false
		}
		y += 1
	}
	check("after dismissal nothing of the pane is left on screen", gone, "title absent on every row")
	dump_rows("pane over the table", 0, max(0, title_row-3), cols, min(9, rows))
	return !any_failed
}

float_shown : bool = true

float_dismiss_only :: proc(ev: ^termbox2.Event) {
	if ui.float_is_dismiss_key(ev) {
		float_shown = false
	}
}

str_col_of :: proc(line: string, needle: string) -> i32 {
	bi := strings.index(line, needle)
	if bi < 0 {
		return -1
	}
	w: i32 = 0
	i := 0
	for r in line {
		if i >= bi {
			break
		}
		w += cols_of(r)
		i += 1
	}
	return w
}

abs_int :: proc(v: i32) -> i32 {
	if v < 0 {
		return -v
	}
	return v
}
