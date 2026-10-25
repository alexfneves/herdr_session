package ui

// ============================================================================
// ui.frame — the outer layout, owned by Clay (T5.1)
//
// The frame is the top-to-bottom spine, FIVE elements stacked inside a root
// sized to exactly the terminal, with the root's childGap at 0 so nothing is
// inserted between them:
//
//   Header   HEADER_ROWS (2)  title + state word
//   rule     RULE_ROWS   (1)  RULE_TOP_ID   header -> main
//   Main     grows            the caller's surface
//   rule     RULE_ROWS   (1)  RULE_BOT_ID   main -> footer
//   Footer   FOOTER_ROWS (1)
//
// Nothing is hand-painted: each line is the bottom border of a dedicated
// RULE_ROWS-tall element (frame_rule), laid out by Clay like any other child,
// and render.paint turns a 1-cell-thick border side into a light glyph through
// tb_linestyle. "A rule between each section" is Clay geometry end to end and
// application code never emits a box glyph.
//
// ── RCH-1: NO OUTER BORDER (docs: 50-requirement-changes.md) ───────────────
// The app is bounded only by the terminal edges. `BorderAll(1)` is what drew
// the box, so it is gone rather than recoloured, and FRAME_PAD dropped to 0
// with it: the border allowance was 2 columns and 2 rows, and the content now
// uses them. ROOT still sets no left/right/top/bottom border width; the only
// border anywhere on ROOT is the bottom side of a rule element.
//
// ── THE RULE MECHANISM CHANGED (RCH-10 changes 1, 2, 6) ────────────────────
// Every rule used to come from ROOT's `border.width.betweenChildren`, which
// clay.c places at
//
//     rule_y = child_top - floor(childGap / 2) - floor(betweenChildren / 2)
//
// That formula is why FRAME_GAP had to be 2 (at childGap 1 the rule resolves
// onto the next section's first row and paints over its content) and it is why
// the frame wasted a blank row on each side of every line: the gap had to be
// big enough to park the rule in. Deriving a line's position from a knob that
// also moves content is also what put the main->footer divider far below a
// one-row edit field, since it followed MAIN's GROW box rather than the field.
//
// Dedicated rule elements carry their position in the layout instead of
// borrowing it from a gap: they land where the child list says, cannot be moved
// by a gap, cannot land on a glyph, and are one row wide so the row budget can
// see them. FRAME_GAP's own comment states the guard that replaced the old
// "DO NOT LOWER" one — read it before touching that constant.
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
//   "this is the header"; the header text says the title and the state, the
//   border says the boundary. `alpha` has exactly one meaning here: 0 == do not
//   paint.
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
FRAME_GAP :: 0 // ROOT childGap — 0 since RCH-10 change 6. REWRITE OF THE OLD
	           // "DO NOT LOWER" GUARD, and it must be read before touching this:
	           //
	           //  * THE OLD HAZARD WAS REAL. The spine's dividers used to come
	           //    from ROOT's `border.width.betweenChildren`, and Clay puts
	           //    such a rule at
	           //        rule_y = child_top - floor(childGap/2) - floor(between/2)
	           //    so at between=1, childGap=1 it resolves onto the FOLLOWING
	           //    section's FIRST ROW and `draw_rule` fills those cells with
	           //    the border colour -- painting over the content. childGap=2
	           //    parked it in the gap instead. That is the invariant the old
	           //    comment pinned, and lowering the gap used to corrupt content.
	           //
	           //  * WHY 0 IS SAFE NOW, AND ONLY NOW. Change 6 removed
	           //    `betweenChildren` from ROOT entirely and moved every divider
	           //    onto a dedicated RULE_ROWS-tall child element (frame_rule).
	           //    There is no longer a rule that lives in the gap, so there is
	           //    no gap for it to need. The rows the old mechanism wasted on
	           //    either side of the line are back in the content budget.
	           //
	           //  * THE GUARD, RESTATED FOR THE NEW ARRANGEMENT. This may stay 0
	           //    only while BOTH hold: (a) ROOT carries no
	           //    `border.width.betweenChildren`, and (b) every rule in the
	           //    frame is a dedicated RULE_ROWS element in ROOT's child list.
	           //    If you re-add `betweenChildren` to ROOT you MUST raise this
	           //    back to >= 2 in the same commit, or the re-added rule lands
	           //    on a content row. `no content shares a rule row` and
	           //    `the rule rows on screen are exactly the rule rows the frame
	           //    lays out` in ui-frame are what catch either half being
	           //    wrong -- keep them, they are the guard, not this comment.
// HEADER_ROWS is 2 since the state moved up out of the footer: row 1 is the
// title, row 2 the current state, both centred. Everything downstream of this
// constant (frame_layout's rule_top / main_y / main_rows / footer_y) follows it,
// which is why the smallest supported terminal (MIN_ROWS = 10, terminal/resize) leaves
// main_rows = 10 - (0 + 2 + 1 + 1 + 1 + 0) = 5 > 0 rather than underflowing.
HEADER_ROWS :: 2
FOOTER_ROWS :: 1
RULE_ROWS :: 1 // a dedicated rule element is exactly one cell row tall

ROOT_ID :: "hs.frame.root"
HEADER_ID :: "hs.frame.header"
MAIN_ID :: "hs.frame.main"
FOOTER_ID :: "hs.frame.footer"
FOOTER_HINTS_ID :: "hs.frame.footer.hints"

// The two spine boundaries, as dedicated elements rather than as a rule derived
// from a shared gap. RCH-10 change 6 requires BOTH ends handled the same way --
// a top boundary that closes its blank row while the bottom one keeps its is
// half a fix, and it is the half a screenshot of the top of the terminal would
// never show.
RULE_TOP_ID :: "hs.frame.rule.top" // header -> main
RULE_BOT_ID :: "hs.frame.rule.bot" // main -> footer

// RULED_SURFACE_ROWS is the price of a RULED SURFACE: one row of content with
// a dedicated rule element directly underneath it. The filter line and the
// single-line edit field are both ruled surfaces (RCH-10 changes 1 and 2), and
// every consumer that counts rows inside MAIN must price them the same way --
// a surface counted as one row is a row the table then paints OVER its rule.
RULED_SURFACE_ROWS :: 1 + RULE_ROWS

// frame_rule draws one dedicated rule: an element exactly RULE_ROWS tall whose
// ONLY decoration is a 1-cell bottom border in the palette's border colour.
//
// This is the mechanism RCH-10 replaces Clay's `betweenChildren` fill-rect
// with, and the reason it exists is placement. A betweenChildren rule is
// positioned by Clay from the gap it shares with its neighbours
// (`rule_y = child_top - floor(childGap/2) - floor(between/2)`), so its row
// is a function of a knob that also moves content -- which is why closing the
// blank row by lowering the gap makes the rule overwrite the next section.
// A dedicated element owns its own row: it is laid out by the same vertical
// stack as everything else, cannot be moved by a gap, and cannot land on a
// glyph. Its rule is the bottom side of its own box.
frame_rule :: proc(id: string, pal: ^Palette) {
	if clay.UI(clay.ID(id))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingGrow(),
				height = clay.SizingFixed(RULE_ROWS),
			},
		},
		border = clay.BorderElementConfig{
			color = pal.border,
			width = clay.BorderWidth{bottom = 1},
		},
	}) {
	}
}

// Frame_Layout is the cell box the frame hands to its sections. Every field is
// absolute (terminal coordinates) so a view can assert against a back-buffer
// position without re-deriving anything.
// Frame_Layout is the cell box the frame hands to its sections. Every field is
// absolute (terminal coordinates) so a view can assert against a back-buffer
// position without re-deriving anything.
//
// The spine is FIVE ROOT children stacked with ROOT childGap = 0 (RCH-10
// change 6), and each one occupies exactly the rows named here:
//
//   HEADER      HEADER_ROWS    rows 0..1              title + state word
//   RULE_TOP    RULE_ROWS      row  2                 header -> main
//   MAIN        main_rows      rows 3..(3+main_rows-1)
//   RULE_BOT    RULE_ROWS      row  3+main_rows       main -> footer
//   FOOTER      FOOTER_ROWS    last row
//
// The budget closes exactly, which is the identity the paper pass checked first:
//
//   HEADER_ROWS + RULE_ROWS + main_rows + RULE_ROWS + FOOTER_ROWS
//     = 2 + 1 + (rows-5) + 1 + 1 = rows                        (Q.E.D.)
//
// `rule_bot` is derived UPWARD (main_y + main_rows) and the footer is derived
// from the bottom of the screen, and the two are equal only because the budget
// closes. That is deliberate: if a future edit breaks the identity, the two
// derivations disagree and a rule/row assertion fails, instead of both silently
// moving together and eating a row nobody charged.
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
	// One upward chain, each link one constant wide. Read top to bottom the five
	// children's rows are visible as an accumulation; nothing here is a magic
	// offset and nothing here is derived from FRAME_GAP (change 6 removed the
	// gap's role in placing rules, so the row budget names RULE_ROWS directly).
	l.rule_top = FRAME_PAD + HEADER_ROWS
	l.main_y = l.rule_top + RULE_ROWS
	l.main_rows = rows - (FRAME_PAD + HEADER_ROWS + RULE_ROWS + RULE_ROWS + FOOTER_ROWS + FRAME_PAD)
	l.rule_bot = l.main_y + l.main_rows
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

// Palette is the view layer's semantic colour contract: the 13 ROLES, and
// nothing else. A widget references a role, never a hex value, and never a
// schema key either — the only path from a theme to a painted pixel is
// `app.theme_role(palette, ROLE)`, resolved through the role table in
// `src/app/theme.odin`.
//
// THE SHAPE IS NOT FREE — IT IS THE ROLE TABLE. One field per role, exactly
// `app.PALETTE_ROLES` (13) of them, and `roles_are_exactly_the_role_table`
// in tests/unit/theme_roles_test.odin asserts the field names against
// `app.theme_role_names()` one-for-one. That is what makes "no UI element can
// reach a colour without going through a role" a checked property rather than
// a house style: a new field that is not a role fails the build of evidence,
// and a role that no view uses is visible as an unused field rather than a
// silent gap.
//
// Deleted with the schema rework (see the app.theme header for why):
// `accent` (the schema has no accent — the highlight bar IS
// `selection.background`), `header_fg`, `float_bg`, `float_fg`, `caret`,
// `run_hl` and `stop_hl`.
Palette :: struct {
	bg     : clay.Color, // role: background             <- primary.background
	fg     : clay.Color, // role: primary text           <- primary.foreground
	dim    : clay.Color, // role: secondary text         <- bright.black
	sel_bg : clay.Color, // role: highlighted row bg     <- selection.background
	sel_fg : clay.Color, // role: highlighted row text   <- selection.text
	border : clay.Color, // role: border / between-children rules <- bright.white
	key_fg : clay.Color, // role: footer KEY token       <- primary.foreground (AD-1.2)
	desc_fg : clay.Color, // role: footer DESCRIPTION    <- bright.black
	running : clay.Color, // role: running               <- normal.green
	stopped : clay.Color, // role: stopped               <- normal.red
	err_fg : clay.Color, // role: error                  <- bright.red
	caret_bg : clay.Color, // role: caret background      <- cursor.cursor
	caret_fg : clay.Color, // role: caret glyph           <- cursor.text
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
// palette_of resolves the 13 roles of one theme into clay colours. EVERY field
// goes through `app.theme_role`, which is the role table; nothing here reads a
// `Palette` field directly and nothing here computes a colour.
palette_of :: proc(t: app.Theme) -> Palette {
	return Palette{
		bg       = clay_colour(app.theme_role(t.pal, .background)),
		fg       = clay_colour(app.theme_role(t.pal, .text)),
		dim      = clay_colour(app.theme_role(t.pal, .secondary)),
		sel_bg   = clay_colour(app.theme_role(t.pal, .hl_bg)),
		sel_fg   = clay_colour(app.theme_role(t.pal, .hl_text)),
		border   = clay_colour(app.theme_role(t.pal, .border)),
		key_fg   = clay_colour(app.theme_role(t.pal, .footer_key)),
		desc_fg  = clay_colour(app.theme_role(t.pal, .footer_desc)),
		running  = clay_colour(app.theme_role(t.pal, .running)),
		stopped  = clay_colour(app.theme_role(t.pal, .stopped)),
		err_fg   = clay_colour(app.theme_role(t.pal, .error)),
		caret_bg = clay_colour(app.theme_role(t.pal, .caret_bg)),
		caret_fg = clay_colour(app.theme_role(t.pal, .caret_glyph)),
	}
}

// default_palette is the stand-in for "there is no theme yet", and it is NOT a
// second palette: it IS `THEME_DEFAULT_NAME`, resolved through the same
// `palette_of` path every theme takes. The old `DEFAULT_PALETTE` was a
// hand-authored set of channels that no theme produced and no test could
// derive; a hand-authored fallback is exactly the kind of invented colour the
// schema rework removed. Because it is a lookup it also cannot drift from the
// table — and Odin forbids a contextful call in a global initialiser, which is
// why this is a proc and not a const.
default_palette :: proc() -> Palette {
	return palette_of(app.theme_default())
}

// clay_colour is the 0xRRGGBB -> 0..255x3 step. Kept separate so the comment
// about the channel range is attached to the code that could get it wrong.
clay_colour :: proc(hex: u32) -> clay.Color {
	r, g, b := app.theme_rgb(hex)
	return clay.Color{c.float(r), c.float(g), c.float(b), 255}
}

// ── footer vocabulary ──────────────────────────────────────────────────────

// Key_Hint is one footer hint: a key and what pressing it does. Under AD-1 the
// pair renders as `Description: key` — `action` is the DESCRIPTION half, the
// thing that reads as a sentence, and `key` is the token the eye hunts for.
// The field kept its name; its POSITION on the line flipped.
Key_Hint :: struct {
	key : string,
	action : string,
}

// Footer_Span_Kind says what a piece of the footer IS. The renderer takes its
// colour from the KIND and never from the string, which is the entire point of
// making the spans the source of truth: text and colour are produced together,
// from one value, so they cannot drift apart the way a coloured string built
// somewhere else can.
Footer_Span_Kind :: enum {
	desc, // the description half of a unit — "New remote"
	key,  // the key half — "r". The dominant token on the line (AD-1.2).
	sep,  // punctuation: ": ", " | ", and the "…" cut marker
}

// Footer_Span is one painted piece of the footer. A unit is three spans
// (desc, ": ", key); the line is units joined by " | " spans, optionally
// headed by the cut marker.
Footer_Span :: struct {
	text : string,
	kind : Footer_Span_Kind,
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
	if colors == nil {
		fb := default_palette()
		colors = &fb
	}
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
		fb := default_palette()
		pal = &fb
	}
	clay.BeginLayout()

	// ── ROOT: fixed to the terminal, NO border, NO childGap ──────────────
	// RCH-10 change 6: ROOT no longer carries `border.width.betweenChildren`
	// and its childGap is 0. The dividers are now dedicated RULE_ROWS children
	// (RULE_TOP_ID / RULE_BOT_ID, opened below), which own their own row
	// instead of borrowing one from a gap. That is what closes the blank line
	// that used to sit between the state word and the rule under it, at both
	// ends of the spine.
	//
	// ROOT still sets no left/right/top/bottom border: RCH-1 removed the outer
	// box and nothing here puts it back. `backgroundColor = pal.bg` is the only
	// decoration, and it is a flat fill behind everything, not a painted cell.
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
	clay.Text(ellipsize(f.title, inner), clay.TextElementConfig{textColor = pal.fg})
	clay.Text(ellipsize(f.state, inner), clay.TextElementConfig{textColor = pal.fg})
	clay._CloseElement()

	// ── THE HEADER -> MAIN RULE, a row of its own, immediately under the
	//    state word. There is deliberately nothing between the two: the blank
	//    line that used to sit here was the gap the betweenChildren rule needed,
	//    and change 6 removed the need for it. ──────────────────────────────
	frame_rule(RULE_TOP_ID, pal)

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
		fb := default_palette()
		pal = &fb
	}
	clay._CloseElement() // MAIN
	// ── THE MAIN -> FOOTER RULE. Same element, same helper, same position in
	//    the stack as RULE_TOP has below the header ── the bottom boundary is
	//    handled identically to the top one, which is the symmetry RCH-10
	//    change 6 demands. Before this the footer sat FRAME_GAP rows below MAIN's
	//    last row with a blank line in between, exactly mirroring (and equally
	//    wasting) the row this change removed at the top. ──────────────────────
	frame_rule(RULE_BOT_ID, pal)
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
//
// The hints are NOT one string in one colour any more. Each unit is painted as
// its own spans, so the key and its description carry the two roles they are
// supposed to carry (AD-1) rather than sharing `dim` with the whole line.
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
		clay.Text(ellipsize(f.rest, rest_w), clay.TextElementConfig{textColor = pal.fg})
		room := inner - rest_w - 1
		if room > 0 {
			footer_hints(f.keys, room, pal)
		}
	}
}

// footer_hints paints the hint units of `keys` into `room` cells, ONE Clay
// text element per span, each in the colour its KIND says it should be.
//
// The spans go in their own zero-gap container rather than directly into FOOTER,
// because FOOTER's childGap is 1 and is already priced into `room` as the
// single gap after `rest`. A per-span gap there would add cells that no
// truncation arithmetic ever accounted for — the line would overflow its own
// budget by one cell per span while every string length check still read green.
footer_hints :: proc(keys: []Key_Hint, room: i32, pal: ^Palette) {
	spans := footer_spans(keys, room)
	defer delete(spans)
	if len(spans) == 0 {
		return
	}
	if clay.UI(clay.ID(FOOTER_HINTS_ID))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingGrow(),
				height = clay.SizingFixed(FOOTER_ROWS),
			},
			layoutDirection = clay.LayoutDirection.LeftToRight,
			childGap = 0,
		},
	}) {
		for s in spans {
			clay.Text(s.text, clay.TextElementConfig{textColor = footer_span_fg(pal, s.kind)})
		}
	}
}

// footer_span_fg is the ONLY place footer colour is decided. Nothing else in
// this package maps a footer piece to a colour, so "the key is painted with
// the key role" cannot be true in one call site and false in another.
//
// The key is the dominant token (AD-1.2): `key_fg` is the role the palette
// tunes for huntability (measured, per theme, in tests/unit/theme_roles_uip2_test
// — key_fg clears WCAG 4.5 on the page background while desc_fg is held DOWN at
// 2.7 and at least 1.5x quieter than the key). No hex lives here; the roles
// come from the palette and a theme change moves the footer with it.
footer_span_fg :: proc(pal: ^Palette, kind: Footer_Span_Kind) -> clay.Color {
	switch kind {
	case .key:
		return pal.key_fg
	case .sep:
		return pal.dim // punctuation is the quietest thing on the line
	case .desc:
		return pal.desc_fg
	}
	return pal.desc_fg
}

// ── the footer unit: `Description: key` ───────────────────────────────────
//
// FORMAT INVERSION (AD-1). The unit used to be `key description` ("r new
// remote"); it is now `description: key` ("New remote: r"). Everything that
// consumes the footer — `keys_line`, the retention rule, the truncation proofs —
// goes through the spans below, so there is exactly one definition of a unit
// and a coloured line and a plain line can never describe different text.
//
// THE WIDTH PRICE (AD-3), stated so nobody re-derives it by surprise:
//
//	unit  = len(Description) + len(": ") + len(key)   cells
//	join  = len(SEP) = 3                            cells, per hint after the first
//	marker = len("…") + len(SEP) = 4                cells, once, when hints were cut
//
// Against the old format that is one extra cell per join and the same marker,
// and the units themselves changed length too because the descriptions are
// display strings now (AD-2), not the old lowercase verb. Every survival
// threshold moved. The tests sweep the widths again rather than trust any of
// the numbers below.
SEP :: " | "

// CUT_MARKER heads the line when hints to the left were dropped, so a short
// footer says "there was more" instead of looking like the whole truth.
CUT_MARKER :: "…"

// UNIT_COLON joins a unit's description to its key.
UNIT_COLON :: ": "

// NO_LIMIT is the `max` used when a caller wants everything. It is 1<<30
// rather than max_int so the width arithmetic inside footer_spans
// (`used + join + unit + marker`) cannot overflow however many hints arrive.
NO_LIMIT : i32 = 1 << 30

// footer_unit_cols is the cell width of one hint unit rendered whole.
footer_unit_cols :: proc(k: Key_Hint) -> i32 {
	return text_cols(k.action) + text_cols(UNIT_COLON) + text_cols(k.key)
}

// footer_unit_text is the plain-text projection of one whole unit.
footer_unit_text :: proc(k: Key_Hint) -> string {
	return cat(k.action, UNIT_COLON, k.key)
}

// footer_spans is THE footer: every hint becomes desc / ": " / key, units are
// joined by " | ", and truncation drops WHOLE UNITS from the FRONT under the
// retention rule (see below), marking the cut with "…".
//
// RETENTION (P3-12) IS UNCHANGED, AND DELIBERATELY SO. When the line cannot
// hold every unit, the cut is made from the FRONT, not the back, and it is
// marked. Every KEYS_* table lists its "how you get out" hints last
// (`t theme`, `esc quit`, `ctrl-c quit`), so filling from the exit side and
// cutting from the front keeps the exit visible and sheds the optional verbs
// first. The rule is positional — "keep the hints nearest the exit" — and
// inverting what each unit SAYS does not touch it. A footer that keeps
// `New local session: enter` while dropping `Quit: esc` tells the user how to
// start things and not how to stop, which at 80-120 columns — a perfectly
// ordinary terminal — is the difference between a UI and a trap.
//
// What IS new is only the size of the atoms the rule counts, which is why the
// sweep lives in tests/unit/keyhints_test.odin and is re-derived, not reused.
footer_spans :: proc(keys: []Key_Hint, max: i32) -> [dynamic]Footer_Span {
	out: [dynamic]Footer_Span = {}
	if max <= 0 || len(keys) == 0 {
		return out
	}

	// The exit unit alone decides whether anything can be shown at all.
	last := keys[len(keys)-1]
	last_w := footer_unit_cols(last)
	if last_w > max {
		// Not even the exit unit fits whole. Same degradation this line has
		// always had — the exit unit, ellipsised — and it is genuinely NOT a
		// whole unit any more, which is precisely why the width floors in the
		// tests sit at or above a unit's own width. `no_half_unit` fails such
		// a line, on purpose: there is no honest `Description: key` in fewer
		// cells than the unit needs.
		append(&out, Footer_Span{ellipsize(footer_unit_text(last), max), .desc})
		return out
	}

	// Walk backwards from the exit unit, prepending whatever still fits.
	kept := keys[len(keys)-1:]
	used := last_w
	for i := len(keys) - 2; i >= 0; i -= 1 {
		w := footer_unit_cols(keys[i])
		// Room for the unit, its separator, and — if we will still be dropping
		// something further left — the cut marker and its separator.
		marker: i32 = 0
		if i > 0 { marker = text_cols(CUT_MARKER) + text_cols(SEP) }
		if used + text_cols(SEP) + w + marker > max { break }
		kept = keys[i:len(keys)]
		used += text_cols(SEP) + w
	}

	for k in kept {
		if len(out) > 0 { append(&out, Footer_Span{SEP, .sep}) }
		append(&out, Footer_Span{k.action, .desc})
		append(&out, Footer_Span{UNIT_COLON, .sep})
		append(&out, Footer_Span{k.key, .key})
	}
	if len(kept) == len(keys) {
		return out // everything fit; no marker
	}

	// Mark the cut. If even the marker does not fit, the units alone are
	// shown — the exit unit is still there either way.
	marker_w := text_cols(CUT_MARKER) + text_cols(SEP)
	if used + marker_w > max {
		return out
	}
	head: [dynamic]Footer_Span = {}
	append(&head, Footer_Span{CUT_MARKER, .sep})
	append(&head, Footer_Span{SEP, .sep})
	for s in out { append(&head, s) }
	delete(out)
	return head
}

// keys_line renders the footer hint line as plain text, truncated to `max`
// cells, dropping whole units (never half a unit) so the footer never wraps.
//
// It is the TEXT PROJECTION of `footer_spans` and nothing else: it holds no
// format string and no separator of its own, so a plain line and the coloured
// line the user sees cannot disagree. The legacy suites and the width proofs
// call this; they read exactly what the footer paints.
keys_line :: proc(keys: []Key_Hint, max: i32) -> string {
	spans := footer_spans(keys, max)
	defer delete(spans)
	return join_spans(spans[:])
}

// join_spans concatenates already-chosen span text. No format string is
// involved, which is what keeps the `%!(EXTRA …)` class of bug out of the
// footer entirely.
join_spans :: proc(spans: []Footer_Span) -> string {
	buf: [dynamic]byte
	for s in spans { append_bytes(&buf, s.text) }
	return string(buf[:])
}

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
// the buffer's growth, never to drop anything). It goes through the SAME spans
// as the painted footer, so it is a projection rather than a second string
// somebody has to remember to keep in sync.
keys_joined :: proc(keys: []Key_Hint, max: i32) -> string {
	spans := footer_spans(keys, NO_LIMIT)
	defer delete(spans)
	return join_spans(spans[:])
}
