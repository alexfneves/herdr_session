package ui

// ============================================================================
// ui.frame — the outer layout, owned by Clay (T5.1)
//
// The frame is the top-to-bottom spine: Header (2 rows: title + state) / Main
// (grows) / Footer (1 row), inside a root element sized to exactly the terminal.
//
// ONE Clay feature draws every line the user sees, so nothing is hand-painted:
// the root carries `border.width.betweenChildren = 1` and NOTHING else —
// left/right/top/bottom stay 0. That emits exactly two RECTANGLE commands, the
// dividers Header|Main and Main|Footer, in the border colour, and no outer box.
// render.paint turns a 1-cell-thick rule into a light glyph through tb_linestyle,
// so "a rule between each section" is Clay geometry end to end and application
// code never emits a box glyph.
//
// ── RCH-1: NO OUTER BORDER (docs: 50-requirement-changes.md) ───────────────
// The app is bounded only by the terminal edges. `BorderAll(1)` is what drew the
// box, so it is gone rather than recoloured, and FRAME_PAD dropped to 0 with it:
// the border allowance was 2 columns and 2 rows, and the content now uses them.
// The dividers are unaffected because they were never part of the box — they come
// from the section container's own betweenChildren width.
//
// ── WHY childGap IS 2 AND MUST STAY 2 ───────────────────────────────────────
// clay.c places a betweenChildren rule at
//
//     rule_y = child_top - floor(childGap / 2) - floor(betweenChildren / 2)
//
// and BOTH halves are integer divisions in C. With childGap = 1 that resolves to
// `child_top - 0 - 0`: the rule lands ON the following section's first row and
// paints over its content. childGap = 2 puts the rule exactly one row above the
// next child — it hugs the section it introduces without ever touching a glyph.
// This is a hard invariant, not a style choice; the `ui-frame` case asserts that
// every rule row is free of content.
//
// ── GEOMETRY IS PREDICTED, THEN CHECKED AGAINST CLAY ────────────────────────
// A view needs its usable cell box BEFORE EndLayout (Clay only computes layout
// during EndLayout), so frame_layout() derives it from the constants below. The
// `ui-frame` case then asserts that prediction against Clay's own record of the
// laid-out element (clay.GetElementData(id).boundingBox), so drift between the
// prediction and Clay's layout fails the suite loudly instead of shifting pixels
// silently.
//
// ── WHAT THE FRAME DOES NOT DO ──────────────────────────────────────────────
// * No background-identity tags. Nothing reads or writes backgroundColor to MEAN
//   "this is the header"; the footer text says the state, the border says the
//   boundary. `alpha` has exactly one meaning here: 0 == do not paint.
// * No hand-painted glyphs outside Clay: every cell travels Clay -> render.paint.
//
// Colour is a value the caller supplies, never a constant baked into a widget:
// T6.2 (compiled-in palettes) builds a `ui.Palette` and no view file changes.
// ============================================================================

import clay "../../clay-odin"
import render "../render"
import app "../app"

import "core:c"
import "core:fmt"
import "core:unicode/utf8"

// ── frame geometry ─────────────────────────────────────────────────────────

FRAME_PAD :: 0 // RCH-1: there is no outer border to keep content clear of.
	           // This used to be 1 as the border allowance; with the box gone the
	           // freed 2x2 belongs to the content. Rules span the full width.
FRAME_GAP :: 2 // childGap — see the >= 2 invariant above. DO NOT LOWER.
// HEADER_ROWS is 2 since the state moved up out of the footer: row 1 is the
// title, row 2 the current state, both centred. Everything downstream of this
// constant (frame_layout's rule_top / main_y / main_rows / footer_y) follows it,
// which is why the smallest supported terminal (MIN_ROWS = 10, terminal/resize) leaves
// main_rows = 10 - (0 + 2 + 2 + 2 + 1 + 0) = 3 > 0 rather than underflowing.
HEADER_ROWS :: 2
FOOTER_ROWS :: 1
RULE_ROWS :: 1 // a betweenChildren rule occupies exactly one cell row

ROOT_ID :: "hs.frame.root"
HEADER_ID :: "hs.frame.header"
MAIN_ID :: "hs.frame.main"
FOOTER_ID :: "hs.frame.footer"

// Frame_Layout is the cell box the frame hands to its sections. Every field is
// absolute (terminal coordinates) so a view can assert against a back-buffer
// position without re-deriving anything.
Frame_Layout :: struct {
	cols : i32, // usable columns (full terminal width since RCH-1)
	header_y : i32,
	main_y : i32, // first row of MAIN
	main_rows : i32, // rows available to MAIN
	footer_y : i32,
	rule_top : i32, // Header|Main rule
	rule_bot : i32, // Main|Footer rule
}

frame_layout :: proc(cols, rows: i32) -> Frame_Layout {
	l := Frame_Layout{}
	l.cols = cols - 2*FRAME_PAD
	l.header_y = FRAME_PAD
	l.rule_top = FRAME_PAD + HEADER_ROWS + FRAME_GAP - 1
	l.main_y = FRAME_PAD + HEADER_ROWS + FRAME_GAP
	l.main_rows = rows - (FRAME_PAD + HEADER_ROWS + FRAME_GAP + FRAME_GAP + FOOTER_ROWS + FRAME_PAD)
	l.rule_bot = l.main_y + l.main_rows + FRAME_GAP - 1
	l.footer_y = rows - FRAME_PAD - FOOTER_ROWS
	if l.cols < 0 {
		l.cols = 0
	}
	if l.main_rows < 0 {
		l.main_rows = 0
	}
	return l
}

// ── palette ────────────────────────────────────────────────────────────────

// colour builds an OPAQUE clay.Color. Alpha 0 means "do not paint this cell" and
// is the only meaning alpha has in this codebase — never an identity marker.
// Palette is the colour contract between the app and the view layer.
// Palette is the view layer's semantic colour contract. A widget references a
// ROLE, never a hex value, so a theme swap changes this struct's contents and
// no widget file changes (that is the whole point of T6.2).
//
// Every field must be supplied by every theme. `app.PALETTE_SLOTS` counts them
// and the theme smoke case asserts the two counts agree, so adding a role here
// without filling it in every palette fails the build of evidence rather than
// painting one widget with a zero (transparent) colour.
Palette :: struct {
	bg : clay.Color, // terminal background
	fg : clay.Color, // default text
	dim : clay.Color, // secondary text: column headers, placeholders
	border : clay.Color, // outer border + betweenChildren rules
	header_fg : clay.Color,
	accent : clay.Color, // selection bar background
	sel_fg : clay.Color, // text drawn ON the selection bar
	caret : clay.Color,
	float_bg : clay.Color,
	float_fg : clay.Color,
	err_fg : clay.Color,
	running : clay.Color, // a session that is up
	stopped : clay.Color, // a session that is not
}

// ── the ONE place a theme becomes a palette ───────────────────────────────
//
// TRAP (plan, and clay-odin/clay.odin:51): Clay channels are 0..255, NOT
// 0.0..1.0. `clay.Color` is `[4]c.float` carrying 0..255, so a palette entry
// 0x282828 becomes {40, 40, 40, 255}. Feeding 0.16 here would paint the
// entire UI black. Every 0..255 conversion in this app happens in this one
// proc, which is why the theme module stores plain hex and never a Clay type.
//
// Alpha is 255 for every slot by construction: "alpha drives exactly one
// decision: paint, or don't" (render/renderer.odin:133) and a themed colour is
// always meant to paint.
palette_of :: proc(t: app.Theme) -> Palette {
	return Palette{
		bg        = clay_colour(t.pal.bg),
		fg        = clay_colour(t.pal.fg),
		dim       = clay_colour(t.pal.dim),
		border    = clay_colour(t.pal.border),
		header_fg = clay_colour(t.pal.header_fg),
		accent    = clay_colour(t.pal.accent),
		sel_fg    = clay_colour(t.pal.sel_fg),
		caret     = clay_colour(t.pal.caret),
		float_bg  = clay_colour(t.pal.float_bg),
		float_fg  = clay_colour(t.pal.float_fg),
		err_fg    = clay_colour(t.pal.err_fg),
		running   = clay_colour(t.pal.running),
		stopped   = clay_colour(t.pal.stopped),
	}
}

// clay_colour is the 0xRRGGBB -> 0..255x3 step. Kept separate so the comment
// about the channel range is attached to the code that could get it wrong.
clay_colour :: proc(hex: u32) -> clay.Color {
	r, g, b := app.theme_rgb(hex)
	return clay.Color{c.float(r), c.float(g), c.float(b), 255}
}

// DEFAULT_PALETTE is a plain dark stand-in so Phase 5 renders honestly before
// T6.2 supplies real terminalcolors.com palettes.
// DEFAULT_PALETTE is the pre-theme stand-in, kept for a nil/absent theme so no
// code path can paint with zeroed colours. It is NOT a theme and is not in the
// picker; app.theme.THEME_DEFAULT_NAME (gruvbox-dark) is what a fresh install
// gets.
DEFAULT_PALETTE : Palette = Palette{
	bg        = clay.Color{16, 20, 28, 255},
	fg        = clay.Color{204, 200, 184, 255},
	dim       = clay.Color{110, 114, 122, 255},
	border    = clay.Color{68, 74, 88, 255},
	header_fg = clay.Color{230, 226, 208, 255},
	accent    = clay.Color{40, 66, 110, 255},
	sel_fg    = clay.Color{236, 236, 236, 255},
	caret     = clay.Color{222, 172, 84, 255},
	float_bg  = clay.Color{26, 30, 40, 255},
	float_fg  = clay.Color{220, 216, 200, 255},
	err_fg    = clay.Color{222, 96, 88, 255},
	running   = clay.Color{120, 190, 120, 255},
	stopped   = clay.Color{110, 114, 122, 255},
}

// ── footer vocabulary ──────────────────────────────────────────────────────

// Key_Hint is one "key -> action" pair drawn in the footer.
Key_Hint :: struct {
	key : string,
	action : string,
}

// Frame is everything the spine needs to draw itself. The state machine (T5.4)
// fills it in per frame; the view never invents content.
//
// The state moved OUT of the footer and INTO the header, so `state` now feeds
// the header's second (centred) line and `rest` feeds the footer's leading
// cell. `rest` is deliberately a new field rather than a widening of `state`:
// the header says WHERE you are, the footer says WHAT the machine sees, and one
// string cannot be both.
Frame :: struct {
	cols : i32,
	rows : i32,
	title : string, // header line 1: program title, centred
	state : string, // header line 2: the current state, in words, centred
	rest : string, // footer: the notice / per-host verdict / provenance
	keys : []Key_Hint, // footer: every key the user can press right now
	pal : ^Palette,
}

// ── cell-width string tools (shared by every view in this package) ──────────
//
// Slicing by DISPLAY COLUMN must never cut a rune in half and must never leave the
// second half of a wide glyph behind. Both helpers walk rune by rune and stop on a
// cell boundary, so a 2-cell rune is all-or-nothing.

text_cols :: proc(s: string) -> i32 {
	return render.text_columns(transmute([]u8)(s))
}

cell_cols :: proc(r: rune) -> i32 {
	return render.glyph_columns(r)
}

// fit_cols returns the longest prefix of `s` occupying at most `max` cells.
fit_cols :: proc(s: string, max: i32) -> string {
	if max <= 0 || len(s) == 0 {
		return ""
	}
	used: i32 = 0
	idx := 0
	for r, b in s {
		w := cell_cols(r)
		if used+w > max {
			break
		}
		used += w
		idx = b + utf8.rune_size(r)
	}
	return s[0:idx]
}

// skip_cols returns the shortest suffix of `s` starting at or after cell `start`.
// (The edit field's horizontal scroll.)
skip_cols :: proc(s: string, start: i32) -> string {
	if start <= 0 {
		return s
	}
	used: i32 = 0
	for r, b in s {
		if used >= start {
			return s[b:]
		}
		used += cell_cols(r)
	}
	return ""
}

// window_cols returns the slice of `s` from cell `start`, `len` cells wide.
window_cols :: proc(s: string, start, width: i32) -> string {
	return fit_cols(skip_cols(s, start), width)
}

// pad_cols left-aligns `s` inside `w` cells, which is what keeps a fixed table
// column aligned.
pad_cols :: proc(s: string, w: i32) -> string {
	f := fit_cols(s, w)
	used := text_cols(f)
	if used >= w {
		return f
	}
	buf: [dynamic]byte
	append_bytes(&buf, f)
	for used < w {
		append(&buf, ' ')
		used += 1
	}
	return string(buf[:])
}

// join_hints concatenates hint strings with a fixed separator.
append_bytes :: proc(out: ^[dynamic]byte, s: string) {
	b := transmute([]u8)(s)
	for x in b {
		append(out, x)
	}
}

// ellipsize truncates to `max` cells, spending the last cell on `…` when it had
// to cut. Never splits a rune or a wide glyph.
ellipsize :: proc(s: string, max: i32) -> string {
	if max <= 0 {
		return ""
	}
	if text_cols(s) <= max {
		return s
	}
	if max == 1 {
		return "…"
	}
	return fmt.tprintf("{}…", fit_cols(s, max-1))
}

// ── the ONE scroll rule ────────────────────────────────────────────────────
//
// Every scrollable view in this package goes through keep_visible, so the sessions
// table and the picker list can never disagree about what "the selection is on
// screen" means. It returns the MINIMAL scroll that puts `index` inside the
// window, then clamps into [0, max(count - visible, 0)] — which is the whole
// story of surviving a terminal shrink: the window gets shorter, the clamp gets
// tighter, and the selection is pulled back inside instead of falling off the
// bottom.
keep_visible :: proc(scroll, count, visible, index: i32) -> i32 {
	s := scroll
	vis := visible
	if vis < 0 {
		vis = 0
	}
	max_scroll := count - vis
	if max_scroll < 0 {
		max_scroll = 0
	}
	if s < 0 {
		s = 0
	}
	if s > max_scroll {
		s = max_scroll
	}
	if index < 0 {
		return s
	}
	if index < s {
		s = index
	} else if index >= s+vis {
		s = index - vis + 1
	}
	if s > max_scroll {
		s = max_scroll
	}
	if s < 0 {
		s = 0
	}
	return s
}

// ── the painter ────────────────────────────────────────────────────────────
//
// The frame owns the Clay session and the renderer plumbing because it owns the
// root element. A caller gets `frame_paint`, which lays out one whole frame and
// returns render stats; the caller decides when to tb_present().
Painter :: struct {
	buf : []u8,
	rend : render.Renderer,
	cols : i32,
	rows : i32,
}

painter_start :: proc(p: ^Painter, cols, rows: i32) -> bool {
	p.cols = cols
	p.rows = rows
	p.buf = make([]u8, int(clay.MinMemorySize())+64*1024)
	arena := clay.CreateArenaWithCapacityAndMemory(c.size_t(len(p.buf)), raw_data(p.buf))
	ctx := clay.Initialize(arena, clay.Dimensions{width = f32(cols), height = f32(rows)}, render.errors_handler_for())
	if ctx == nil {
		delete(p.buf)
		p.buf = nil
		return false
	}
	clay.SetMeasureTextFunction(render.measure_text, nil)
	p.rend = render.Renderer{}
	return true
}

// painter_resize tells Clay the terminal changed shape. Clay keeps its own layout
// dimensions, so a resize that only updates termbox would keep laying out for the
// old size.
painter_resize :: proc(p: ^Painter, cols, rows: i32) {
	p.cols = cols
	p.rows = rows
	clay.SetLayoutDimensions(clay.Dimensions{width = f32(cols), height = f32(rows)})
}

// painter_stop releases the Clay arena.
painter_stop :: proc(p: ^Painter) {
	if len(p.buf) > 0 {
		delete(p.buf)
		p.buf = nil
	}
}

// ── THE "TOO SMALL" SCREEN ─────────────────────────────────────────────────
//
// paint_notice is the frame drawn when the terminal cannot hold the real UI
// (T6.5, `terminal.too_small`). Two constraints shape it:
//
//  1. It must REPLACE the spine, not join it. `frame_layout` clamps
//     `main_rows` at 0 for a tiny terminal, and a zero-row MAIN still sits
//     between the header rule and the footer rule — the rules then land on top
//     of each other and on top of the message. That is the garbling this path
//     exists to prevent, so no header/footer/rules are drawn here at all.
//
//  2. It must still be drawn BY Clay. "Every cell travels Clay -> render.paint"
//     is the rule the whole renderer rests on; hand-placing cells to dodge the
//     layout engine is the anti-pattern this project refused at Phase 2. So the
//     notice is a real one-child Clay tree, centred, that degrades gracefully
//     down to a 1x1 terminal.
//
// Recovery is automatic for the same reason the notice is cheap: the notice is
// chosen per frame from the CURRENT terminal size, so when the user enlarges the
// window the next frame takes the normal path again. There is no "too small
// mode" to exit, and therefore no way to get stuck in one.
paint_notice :: proc(p: ^Painter, cols, rows: i32, pal: ^Palette, msg: string) -> render.Stats {
	colors: ^Palette = pal
	if colors == nil { colors = &DEFAULT_PALETTE }
	// Keep the whole message on one line and inside the terminal: at these sizes
	// wrapping would push the tail off-screen and read as corruption.
	text := ellipsize(msg, cols)

	clay.BeginLayout()
	clay._OpenElementWithId(clay.ID("hs.notice.root"))
	clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingFixed(f32(cols)),
				height = clay.SizingFixed(f32(rows)),
			},
			layoutDirection = clay.LayoutDirection.TopToBottom,
			childAlignment = clay.ChildAlignment{x = .Center, y = .Center},
		},
		backgroundColor = colors.bg,
	})
	clay.Text(text, clay.TextElementConfig{textColor = colors.err_fg})
	clay._CloseElement()
	cmds := clay.EndLayout(0)
	return render.render_frame(&p.rend, cmds)
}

// ── THE SPINE IS OPEN/CLOSE, NOT A CLOSURE ──────────────────────────────────
//
// The natural shape is "open the spine, let the caller paint MAIN, then close it"
// — which crosses a function boundary. Odin procedure literals capture the
// *context* and nothing else: a `proc() { ... }` cannot reference the caller's
// local views, so a `body: proc()` callback would not compile the moment it
// needed real state. So the frame is opened and closed with Clay's explicit
// primitives, and the caller paints MAIN in its own scope between the two calls.
// One open, one matching close, no hidden deferred pairing to get wrong.

// frame_open begins the layout and opens ROOT + HEADER (closed) + MAIN (open).
// Every call MUST be paired with frame_close in the same frame.
frame_open :: proc(p: ^Painter, f: ^Frame) {
	pal := f.pal
	if pal == nil {
		pal = &DEFAULT_PALETTE
	}
	clay.BeginLayout()

	// ── ROOT: fixed to the terminal, bordered, rules between every section ──
	clay._OpenElementWithId(clay.ID(ROOT_ID))
	clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingFixed(f32(f.cols)),
				height = clay.SizingFixed(f32(f.rows)),
			},
			padding = clay.PaddingAll(FRAME_PAD),
			childGap = FRAME_GAP,
			layoutDirection = clay.LayoutDirection.TopToBottom,
		},
		backgroundColor = pal.bg,
		// ONLY betweenChildren is set. Any non-zero left/right/top/bottom here
		// would redraw the outer box that RCH-1 removed.
		border = clay.BorderElementConfig{
			color = pal.border,
			width = clay.BorderWidth{betweenChildren = 1},
		},
	})

	// ── HEADER: the title on row 1, the state on row 2, both centred ──────
	// TopToBottom (not LeftToRight) because the two lines are stacked, and
	// `childAlignment.x = .Center` is the CROSS-axis alignment for a vertical
	// container — clay.h aligns each child on the axis perpendicular to the
	// layout direction with childAlignment.x, so every line here is centred
	// without a hand-computed column. childGap stays 0 inside the header: the
	// two lines are adjacent rows, and the >= 2 rule that FRAME_GAP exists for
	// is about the ROOT's children, where a betweenChildren rule is drawn.
	// Both strings are ellipsised to the inner width so a long state line can
	// never push a glyph past the terminal edge.
	inner := frame_layout(f.cols, f.rows).cols
	clay._OpenElementWithId(clay.ID(HEADER_ID))
	clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingGrow(),
				height = clay.SizingFixed(HEADER_ROWS),
			},
			layoutDirection = clay.LayoutDirection.TopToBottom,
			childAlignment = clay.ChildAlignment{x = .Center},
		},
	})
	clay.Text(ellipsize(f.title, inner), clay.TextElementConfig{textColor = pal.header_fg})
	clay.Text(ellipsize(f.state, inner), clay.TextElementConfig{textColor = pal.header_fg})
	clay._CloseElement()

	// ── MAIN: left OPEN for the caller ──
	clay._OpenElementWithId(clay.ID(MAIN_ID))
	clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingGrow(),
				height = clay.SizingGrow(),
			},
			layoutDirection = clay.LayoutDirection.TopToBottom,
		},
	})
}

// frame_close closes MAIN, paints the FOOTER, closes ROOT and hands the command
// stream to the renderer. The caller decides when to tb_present().
frame_close :: proc(p: ^Painter, f: ^Frame) -> render.Stats {
	pal := f.pal
	if pal == nil {
		pal = &DEFAULT_PALETTE
	}
	clay._CloseElement() // MAIN
	frame_footer(f, pal)
	clay._CloseElement() // ROOT
	cmds := clay.EndLayout(0)
	return render.render_frame(&p.rend, cmds)
}

// frame_footer paints the footer row: the machine's own report (`f.rest`) first,
// then the key hints. The STATE is not here — it moved to the header, and the
// list-age token is gone from this line entirely. What is left in `rest` is the
// notice, the config warning, the per-host verdict and the provenance of the
// remote set, composed by the driver.
frame_footer :: proc(f: ^Frame, pal: ^Palette) {
	inner := frame_layout(f.cols, f.rows).cols
	if clay.UI(clay.ID(FOOTER_ID))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingGrow(),
				height = clay.SizingFixed(FOOTER_ROWS),
			},
			layoutDirection = clay.LayoutDirection.LeftToRight,
			childGap = 1,
		},
	}) {
		rest_w := text_cols(f.rest)
		if rest_w > inner {
			rest_w = inner
		}
		clay.Text(ellipsize(f.rest, rest_w), clay.TextElementConfig{textColor = pal.accent})
		room := inner - rest_w - 1
		if room > 0 {
			clay.Text(keys_line(f.keys, room), clay.TextElementConfig{textColor = pal.dim})
		}
	}
}

// keys_line renders "j move  k quit  enter open" truncated to `max` cells, dropping
// whole hints (never half a hint) so the footer never wraps.
//
// RETENTION (P3-12). When the line cannot hold every hint, the cut is made from
// the FRONT, not the back — and it is marked with `…`. This is deliberate:
// every KEYS_* table in main.odin lists its "how you get out" hints last
// (`t theme`, `esc quit`, `ctrl-c quit`), so filling from the front and cutting
// from the front keeps the exit visible and sheds the optional verbs first. A
// footer that keeps `enter new local session` while dropping `esc quit` tells
// the user how to start things and not how to stop, which at 80–120 columns — a
// perfectly ordinary terminal — is the difference between a UI and a trap.
//
// The rule is "keep the hints nearest the exit, drop the ones furthest from it",
// which is the same ordering the tables are written in and needs no second table
// of priorities to drift out of sync.
keys_line :: proc(keys: []Key_Hint, max: i32) -> string {
	if max <= 0 || len(keys) == 0 {
		return ""
	}

	// The exit hint alone decides whether anything can be shown at all.
	last := fmt.tprintf("{} {}", keys[len(keys)-1].key, keys[len(keys)-1].action)
	if text_cols(last) > max {
		return ellipsize(last, max)
	}

	// Walk backwards from the exit hint, prepending whatever still fits.
	kept: []Key_Hint = keys[len(keys)-1:]
	used := text_cols(last)
	for i := len(keys) - 2; i >= 0; i -= 1 {
		hint := fmt.tprintf("{} {}", keys[i].key, keys[i].action)
		// Room for the hint, its separator, and — if we will still be dropping
		// something further left — the `…` marker and its separator.
		marker: i32 = 0
		if i > 0 { marker = text_cols("…") + len(SEP) }
		if used + len(SEP) + text_cols(hint) + marker > max { break }
		kept = keys[i:len(keys)]
		used += len(SEP) + text_cols(hint)
	}

	line := keys_joined(kept, max)
	if len(kept) == len(keys) {
		return line // everything fit; no marker
	}
	// Mark the cut. If even the marker does not fit, the hints alone are shown —
	// the exit hint is still there either way.
	marked := cat("…", SEP, line)
	if text_cols(marked) <= max {
		return marked
	}
	return line
}

SEP :: "  "

// cat joins three pieces without any format string, so no user-supplied text can
// ever hit a format-specifier path (the `%!(EXTRA …)` class of bug).
cat :: proc(a, b, c: string) -> string {
	buf: [dynamic]byte
	append_bytes(&buf, a)
	append_bytes(&buf, b)
	append_bytes(&buf, c)
	return string(buf[:])
}

// keys_joined renders every hint, untruncated (the `max` is only used to size
// the buffer's growth, never to drop anything).
keys_joined :: proc(keys: []Key_Hint, max: i32) -> string {
	buf: [dynamic]byte
	for &k in keys {
		if len(buf) > 0 { append_bytes(&buf, SEP) }
		append_bytes(&buf, fmt.tprintf("{} {}", k.key, k.action))
	}
	return string(buf[:])
}
