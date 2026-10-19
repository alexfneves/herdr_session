package render

// Clay render commands -> termbox2 cells.
//
// # Shape of the problem
//
// Clay computes layout and hands back a flat, already-paint-ordered stream of
// `RenderCommand`s. This file is the only place that knows how to turn that
// stream into terminal cells. Three rules hold it together:
//
//  1. **Total dispatch.** `render_command` switches on every command type Clay
//     can emit — no `#partial switch`. A new Clay version that adds a type is a
//     compile error here, not a command that silently vanishes.
//  2. **One funnel for pixels.** Every cell write goes through `paint()`, which
//     enforces the active scissor. "Nothing paints outside a clipped container"
//     is then a property of the renderer, not a rule each draw path has to
//     remember.
//  3. **Place, never re-flow.** Clay already wrapped text and baked alignment
//     into the box. One TEXT command is one terminal row.
//
// # What the dumped command stream actually looks like
//
// From dev/probe (a 40x9 bordered column, childGap 1, three text children):
//
//	Rectangle      (0,0)   40x9   bg=blue         <- container background
//	Text           (0,0)   6x1    "HEADER"
//	Text           (0,2)   15x1   "Body 中文😀 mix"
//	Text           (0,4)   6x1    "FOOTER"
//	Border         (0,0)   40x9   L=1 R=1 T=1 B=1 betweenChildren=1
//	Rectangle      (0,2)   40x1   bg=RED          <- betweenChildren divider
//	Rectangle      (0,4)   40x1   bg=RED          <- betweenChildren divider
//
// Two things fall out of that, and both are load-bearing:
//
//   * `betweenChildren` is **not** present in the Border command as geometry.
//     Clay emits each divider later as its own thin `Rectangle` in the
//     *border's* colour (clay.h:2852-2890). So the Border handler registers the
//     rule style (colour + thickness) and the Rectangle handler recognises those
//     thin rects and draws a ruled glyph instead of a solid band — see
//     `Rule_Source`.
//   * Alignment arrives as x: a 9-column string centred in 30 columns comes back
//     at x=10.5, a right-aligned one at x=22. The renderer rounds, never
//     computes.

import clay "../../clay-odin"
import termbox2 "../../vendor/termbox2-odin"

import "core:math"
import "core:mem"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

// Rect is a cell-aligned rectangle: inclusive origin, size in cells.
Rect :: struct {
	x : i32,
	y : i32,
	w : i32,
	h : i32,
}

rect_of :: proc(x, y, w, h: i32) -> Rect {
	return Rect{x = x, y = y, w = w, h = h}
}

is_empty :: proc(r: Rect) -> bool {
	return r.w <= 0 || r.h <= 0
}

// intersect returns the overlap of two rectangles.
intersect :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x+a.w, b.x+b.w)
	y1 := min(a.y+a.h, b.y+b.h)
	if x1 <= x0 || y1 <= y0 {
		return Rect{}
	}
	return rect_of(x0, y0, x1-x0, y1-y0)
}

// round_cell snaps a Clay float onto the cell grid, halves rounding up
// (floor(x + 0.5)). Clay emits x=10.5 for centred text; one consistent rule
// everywhere is what stops borders and text disagreeing about where a cell edge
// is.
round_cell :: proc(v: f32) -> i32 {
	return i32(math.floor(f64(v) + 0.5))
}

// snap_box converts a Clay BoundingBox into a cell-aligned Rect.
//
// A box with non-zero size never collapses: a 0.4-cell divider still has to
// occupy a row, or it silently disappears from the screen.
snap_box :: proc(box: clay.BoundingBox) -> Rect {
	x0 := round_cell(box.x)
	y0 := round_cell(box.y)
	x1 := round_cell(box.x + box.width)
	y1 := round_cell(box.y + box.height)

	if x1 == x0 && box.width > 0 { x1 = x0 + 1 }
	if y1 == y0 && box.height > 0 { y1 = y0 + 1 }

	return rect_of(x0, y0, x1-x0, y1-y0)
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

// ALPHA_PAINT is the alpha at or below which a Clay colour is not drawn.
//
// Clay alpha is 0..255 like its channels, so this is "fully transparent", not
// "1% opaque". There is no blending yet: any colour you can see here you see at
// full strength. That is deliberate — see the OverlayColor note in
// `render_command` for why a half-transparent terminal is Phase 5's decision,
// not this renderer's.
ALPHA_PAINT :: f32(0)

// attr_of converts a Clay colour into a termbox2 truecolour attribute.
//
// Two facts make this non-obvious:
//
//  1. `Clay_Color` is `[4]c.float` in **0..255**, not normalised 0..1. Running
//     it through a 0..1 path paints the whole UI black.
//  2. termbox2 keeps the 24-bit RGB in the low bits of the attr word
//     (termbox2.h:3830 `cfg = fg & 0xffffff`) and treats an attr whose low 24
//     bits are zero *without* TB_HI_BLACK as "use the terminal default"
//     (termbox2.h:3883). So literal black (0,0,0) would render as the terminal
//     default rather than black; TB_HI_BLACK is what asks for real black.
//
// Alpha drives exactly one decision: paint, or don't. It is never an identity or
// tag channel (ISC-A-8) — geometry comes from the bounding box, never from a
// colour's alpha.
attr_of :: proc(c: clay.Color) -> (termbox2.Attr, bool) {
	if c[3] <= ALPHA_PAINT {
		return termbox2.TB_DEFAULT, false
	}
	rgb := (u32(clamp_byte(c[0])) << 16) | (u32(clamp_byte(c[1])) << 8) | u32(clamp_byte(c[2]))
	if rgb == 0 {
		rgb = termbox2.TB_HI_BLACK // real black, not "default"
	}
	return rgb, true
}

// attr_painted returns the colour's attribute, or TB_DEFAULT when it is not drawn.
attr_painted :: proc(c: clay.Color) -> termbox2.Attr {
	result, paints := attr_of(c)
	if !paints {
		return termbox2.TB_DEFAULT
	}
	return result
}

clamp_byte :: proc(v: f32) -> u8 {
	if !(v > 0) { // also catches NaN
		return 0
	}
	if v > 255 {
		return 255
	}
	return u8(v + 0.5)
}

// ---------------------------------------------------------------------------
// Box-drawing glyphs
// ---------------------------------------------------------------------------

// Glyphs is a box-drawing set: two straight strokes and four corners.
Glyphs :: struct {
	h  : rune, // horizontal stroke ─ ═
	v  : rune, // vertical stroke   │ ║
	tl : rune, // top-left     ┌ ╔
	tr : rune, // top-right    ┐ ╗
	bl : rune, // bottom-left  └ ╚
	br : rune, // bottom-right ┘ ╝
}

GLYPHS_LIGHT :: Glyphs{h = '─', v = '│', tl = '┌', tr = '┐', bl = '└', br = '┘'}
GLYPHS_HEAVY :: Glyphs{h = '═', v = '║', tl = '╔', tr = '╗', bl = '╚', br = '╝'}

// glyphs_for_weight picks a glyph set for a border/rule thickness.
//
// A terminal offers one glyph per cell, so a 3-cell-wide border cannot be drawn
// literally as three lines. Glyph *weight* carries the thickness instead: one
// cell is light, two or more is heavy.
glyphs_for_weight :: proc(thickness: i32) -> Glyphs {
	if thickness >= 2 {
		return GLYPHS_HEAVY
	}
	return GLYPHS_LIGHT
}

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

// CLIP_STACK_MAX bounds how deep Clay's scissor nesting may go. The frame plus a
// couple of scroll containers uses a fraction of this; overflow is counted rather
// than silently mis-clipping.
CLIP_STACK_MAX :: 32

// RULE_SOURCES_MAX bounds how many `betweenChildren` rule styles may be live in
// one frame — one per bordered container.
RULE_SOURCES_MAX :: 32

// Rule_Source records that some bordered container emits dividers of a given
// thickness and colour.
//
// `BorderRenderData.width.betweenChildren` says a container *has* dividers and
// how thick they are, but not where they go: Clay delivers each divider's
// position as a separate thin `Rectangle` command that reuses the border's
// colour, emitted right after the Border command (clay.h:2852-2890). So the
// Border handler records the style here, and the Rectangle handler draws it as a
// ruled line rather than a solid band.
Rule_Source :: struct {
	attr      : termbox2.Attr,
	thickness : i32,
	// interior is the container's box *inside* its own border lines.
	//
	// Clay's divider rectangle spans the container's full width, so painting it
	// as-is wipes the `│` glyphs the border drew on the container's own edges
	// (found by rendering: the left and right sides came back as `─` at every
	// divider row). The divider belongs to the interior, so the rule stops where
	// the border starts.
	interior  : Rect,
}

// Stats reports what the last frame drew. Cheap, and decisive when a screen looks
// wrong: it says whether a command arrived at all, and whether the clip ate it.
Stats :: struct {
	commands   : int,
	rects      : int,
	rules      : int,
	borders    : int,
	text_rows  : int,
	glyphs     : int,
	claimed    : int, // trailing cells claimed for wide glyphs
	skipped    : int, // glyphs dropped (zero-width: combining marks, no EGC)
	none       : int,
	images     : int,
	overlays   : int,
	customs    : int,
	scissors   : int,
	hidden     : int, // draw calls fully swallowed by the active clip
	overflow   : int, // clip / rule-stack capacity exceeded
	cell_error : int, // tb_set_cell failures
}

// Renderer paints Clay's command stream into termbox2's back buffer.
Renderer :: struct {
	screen : Rect, // the whole terminal, intersected into every clip
	clip   : Rect, // the active scissor region
	stack  : [CLIP_STACK_MAX]Rect, // saved clips
	depth  : int,
	rules  : [RULE_SOURCES_MAX]Rule_Source,
	rule_n : int,
	stats  : Stats,
}

// reset forgets transient state. Called at the top of every frame: Clay's rule
// styles and clips are per-frame, and nothing here may survive into the next one.
reset :: proc(r: ^Renderer) {
	r.clip = r.screen
	r.depth = 0
	r.rule_n = 0
	r.stats = {}
}

// render_frame paints an entire Clay command stream and returns frame stats.
render_frame :: proc(r: ^Renderer, commands: clay.ClayArray(clay.RenderCommand)) -> Stats {
	r.screen = rect_of(0, 0, termbox2.tb_width(), termbox2.tb_height())
	reset(r)

	i: int = 0
	for i < int(commands.length) {
		r.stats.commands += 1
		render_command(r, commands.internalArray[i])
		i += 1
	}
	return r.stats
}

// render_command dispatches one Clay render command.
//
// The switch is total on purpose. Every case is listed, including the ones that
// deliberately do nothing, so that an upgrade to a Clay that adds a command type
// fails the build here instead of quietly dropping commands on screen.
render_command :: proc(r: ^Renderer, cmd: clay.RenderCommand) {
	box := snap_box(cmd.boundingBox)

	switch cmd.commandType {
	case .Rectangle:
		render_rectangle(r, box, cmd.renderData.rectangle.backgroundColor)

	case .Border:
		render_border(r, box, cmd.renderData.border)

	case .Text:
		render_text_row(r, box, cmd.renderData.text)

	case .Image:
		// A cell grid has no pixels, so an image cannot be drawn. The box is
		// still reserved so the layout keeps the space it was given, and the
		// command is counted rather than ignored.
		r.stats.images += 1
		fill(r, box, termbox2.TB_DEFAULT, attr_painted(cmd.renderData.image.backgroundColor))

	case .ScissorStart:
		push_clip(r, box)
		r.stats.scissors += 1

	case .ScissorEnd:
		pop_clip(r)
		r.stats.scissors += 1

	case .OverlayColorStart:
		// Clay brackets a group of commands that should be blended with a colour
		// (hover highlight, modal dim). Deliberate no-op in T2.2 rather than a
		// dropped command: the per-cell painter has no blend policy yet, and
		// inventing one here (tint every background underneath) would fight
		// Phase 5, which owns hover/selection styling. When it lands, it lands
		// in `paint()` — the single funnel every cell passes through — with this
		// pair maintaining the blend state.
		r.stats.overlays += 1

	case .OverlayColorEnd:
		r.stats.overlays += 1

	case .Custom:
		// No custom-element painter is registered yet. The space is still
		// reserved; Phase 5 registers painters against this case.
		r.stats.customs += 1

	case .None:
		r.stats.none += 1
	}
}

// ---------------------------------------------------------------------------
// Scissor / clip state
// ---------------------------------------------------------------------------

// push_clip narrows the drawable region to `region`.
push_clip :: proc(r: ^Renderer, region: Rect) {
	if r.depth >= CLIP_STACK_MAX {
		r.stats.overflow += 1
		return
	}
	r.stack[r.depth] = r.clip
	r.depth += 1
	r.clip = intersect(r.clip, region)
}

// pop_clip restores the previous clip.
pop_clip :: proc(r: ^Renderer) {
	if r.depth == 0 {
		// Clay pairs ScissorStart/End in its DFS, so an underflow means an
		// unbalanced stream. Fall back to the whole screen rather than leaving a
		// stale narrow clip, and count it so the imbalance is visible.
		r.stats.overflow += 1
		r.clip = r.screen
		return
	}
	r.depth -= 1
	r.clip = r.stack[r.depth]
}

// ---------------------------------------------------------------------------
// Cell painting — the single funnel
// ---------------------------------------------------------------------------

// paint writes one cell if it is inside the active clip and on screen, and
// reports whether it wrote.
//
// Every glyph, fill and border stroke in this renderer goes through here. That is
// what makes "nothing paints outside a clipped container" a property of the
// renderer as a whole, instead of a rule each draw path must remember.
paint :: proc(r: ^Renderer, x, y: i32, ch: rune, fg, bg: termbox2.Attr) -> bool {
	if x < r.clip.x || y < r.clip.y || x >= r.clip.x+r.clip.w || y >= r.clip.y+r.clip.h {
		r.stats.hidden += 1
		return false
	}
	if x < 0 || y < 0 || x >= r.screen.w || y >= r.screen.h {
		return false
	}
	if rc := termbox2.tb_set_cell(x, y, cast(u32)(ch), fg, bg); rc != termbox2.TB_OK {
		r.stats.cell_error += 1
		return false
	}
	return true
}

// paint_overlay writes a glyph but keeps the background already in that cell.
// A border or ruled line laid over a coloured panel must not punch a hole in it.
paint_overlay :: proc(r: ^Renderer, x, y: i32, ch: rune, fg: termbox2.Attr) -> bool {
	return paint(r, x, y, ch, fg, bg_of(x, y))
}

// bg_of reads the current back-buffer background at (x, y).
bg_of :: proc(x, y: i32) -> termbox2.Attr {
	cell: ^termbox2.Cell = nil
	if termbox2.tb_get_cell(x, y, 1, &cell) == termbox2.TB_OK && cell != nil {
		return cell.bg
	}
	return termbox2.TB_DEFAULT
}

// fill paints a solid block: blank glyphs over `bg`.
fill :: proc(r: ^Renderer, area: Rect, fg, bg: termbox2.Attr) {
	view := intersect(area, r.clip)
	if is_empty(view) {
		r.stats.hidden += 1
		return
	}
	y: i32 = 0
	for y < view.h {
		x: i32 = 0
		for x < view.w {
			paint(r, view.x+x, view.y+y, ' ', fg, bg)
			x += 1
		}
		y += 1
	}
}

// ---------------------------------------------------------------------------
// Rectangle — a fill, unless it is a `betweenChildren` divider
// ---------------------------------------------------------------------------

render_rectangle :: proc(r: ^Renderer, area: Rect, color: clay.Color) {
	attr, paints := attr_of(color)
	if !paints {
		return
	}

	if rule, ok := lookup_rule(r, attr, area); ok {
		// Clip the divider to the container's interior so it cannot erase the
		// border's own side glyphs.
		draw_area := intersect(area, rule.interior)
		if is_empty(draw_area) {
			draw_area = area // no interior match; draw rather than drop silently
		}
		draw_rule(r, draw_area, glyphs_for_weight(rule.thickness), attr)
		return
	}

	r.stats.rects += 1
	fill(r, area, termbox2.TB_DEFAULT, attr)
}

// lookup_rule decides whether a rectangle is a `betweenChildren` divider rather
// than an ordinary background fill, and returns the glyph set to draw it with.
//
// The match is deliberately narrow so an ordinary fill cannot be mistaken for a
// rule:
//   * its colour equals a border's own colour (Clay emits the divider with
//     `borderConfig->color`, clay.h:2875)
//   * its thickness equals that border's `betweenChildren`, in cells
//   * the other axis runs >= 2 cells (a 1x1 patch is not a rule)
//   * it arrives *after* that Border command — which is exactly the order Clay
//     uses, and why the container's own background rectangle (emitted earlier,
//     and never of the border's thickness) is unaffected
lookup_rule :: proc(r: ^Renderer, attr: termbox2.Attr, area: Rect) -> (Rule_Source, bool) {
	if r.rule_n == 0 || attr == termbox2.TB_DEFAULT {
		return Rule_Source{}, false
	}
	fallback := Rule_Source{}
	have_fallback := false

	i: int = 0
	for i < r.rule_n {
		rule := r.rules[i]
		if rule.attr == attr && rule.thickness > 0 {
			thin := (area.h == rule.thickness && area.w >= 2) || (area.w == rule.thickness && area.h >= 2)
			if thin {
				// Prefer the rule whose container actually owns this rectangle.
				if contains(rule.interior, area) {
					return rule, true
				}
				if !have_fallback {
					fallback = rule
					have_fallback = true
				}
			}
		}
		i += 1
	}
	return fallback, have_fallback
}

// contains reports whether `outer` fully covers `inner`.
contains :: proc(outer, inner: Rect) -> bool {
	if is_empty(inner) { return false }
	return inner.x >= outer.x && inner.y >= outer.y &&
		inner.x+inner.w <= outer.x+outer.w && inner.y+inner.h <= outer.y+outer.h
}

// draw_rule paints a ruled line across `area`, preserving the background so a
// rule over a coloured panel reads as a line, not a stripe.
draw_rule :: proc(r: ^Renderer, area: Rect, glyphs: Glyphs, fg: termbox2.Attr) {
	r.stats.rules += 1
	view := intersect(area, r.clip)
	if is_empty(view) {
		r.stats.hidden += 1
		return
	}

	// The longer axis is the direction the rule runs.
	if view.w >= view.h {
		y: i32 = 0
		for y < view.h {
			x: i32 = 0
			for x < view.w {
				paint_overlay(r, view.x+x, view.y+y, glyphs.h, fg)
				x += 1
			}
			y += 1
		}
		return
	}

	x: i32 = 0
	for x < view.w {
		y: i32 = 0
		for y < view.h {
			paint_overlay(r, view.x+x, view.y+y, glyphs.v, fg)
			y += 1
		}
		x += 1
	}
}

// ---------------------------------------------------------------------------
// Border — four sides of box glyphs, driven by BorderRenderData.width
// ---------------------------------------------------------------------------

// render_border draws the four sides of a bordered element.
//
// `betweenChildren` is *registered* here rather than drawn: this command carries
// the border's colour and thickness but not the dividers' positions (see
// Rule_Source).
render_border :: proc(r: ^Renderer, area: Rect, b: clay.BorderRenderData) {
	r.stats.borders += 1

	if b.width.betweenChildren > 0 {
		if r.rule_n < RULE_SOURCES_MAX {
			// The border's own lines own the container's edges, one cell each side.
			inset_left := i32(0)
			inset_right := i32(0)
			inset_top := i32(0)
			inset_bottom := i32(0)
			if b.width.left > 0 { inset_left = 1 }
			if b.width.right > 0 { inset_right = 1 }
			if b.width.top > 0 { inset_top = 1 }
			if b.width.bottom > 0 { inset_bottom = 1 }

			r.rules[r.rule_n] = Rule_Source{
				attr      = attr_painted(b.color),
				thickness = max(i32(1), i32(b.width.betweenChildren)),
				interior = rect_of(area.x+inset_left, area.y+inset_top,
					area.w-inset_left-inset_right, area.h-inset_top-inset_bottom),
			}
			r.rule_n += 1
		} else {
			r.stats.overflow += 1
		}
	}

	fg, paints := attr_of(b.color)
	if !paints {
		return
	}

	view := intersect(area, r.clip)
	if is_empty(view) {
		r.stats.hidden += 1
		return
	}

	thickest := max(max(i32(b.width.top), i32(b.width.bottom)), max(i32(b.width.left), i32(b.width.right)))
	g := glyphs_for_weight(thickest)

	has_top := b.width.top > 0
	has_bottom := b.width.bottom > 0
	has_left := b.width.left > 0
	has_right := b.width.right > 0

	x0 := view.x
	y0 := view.y
	x1 := view.x + view.w - 1
	y1 := view.y + view.h - 1

	// Sides first, corners last: the corner glyph overwrites the cell that two
	// sides would otherwise both claim, which is what makes ┌┐└┘ join.
	if has_top {
		x: i32 = 0
		for x < view.w {
			paint_overlay(r, x0+x, y0, g.h, fg)
			x += 1
		}
	}
	if has_bottom {
		x: i32 = 0
		for x < view.w {
			paint_overlay(r, x0+x, y1, g.h, fg)
			x += 1
		}
	}
	if has_left {
		y: i32 = 0
		for y < view.h {
			paint_overlay(r, x0, y0+y, g.v, fg)
			y += 1
		}
	}
	if has_right {
		y: i32 = 0
		for y < view.h {
			paint_overlay(r, x1, y0+y, g.v, fg)
			y += 1
		}
	}

	if has_top && has_left { paint_overlay(r, x0, y0, g.tl, fg) }
	if has_top && has_right { paint_overlay(r, x1, y0, g.tr, fg) }
	if has_bottom && has_left { paint_overlay(r, x0, y1, g.bl, fg) }
	if has_bottom && has_right { paint_overlay(r, x1, y1, g.br, fg) }
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

// render_text_row paints one TEXT command.
//
// One TEXT command == one already-wrapped terminal row. Clay wrapped it in
// `Clay__CalculateWrappedText` and baked alignment into `boundingBox.x`
// (measured: 9 columns centred in 30 arrives at x=10.5; right-aligned at x=22).
// So this places, and must not re-flow or re-measure.
render_text_row :: proc(r: ^Renderer, area: Rect, t: clay.TextRenderData) {
	r.stats.text_rows += 1

	fg, paints := attr_of(t.textColor)
	if !paints {
		return
	}
	bg := bg_of(area.x, area.y)

	bytes := mem.byte_slice(t.stringContents.chars, int(t.stringContents.length))
	clip_right := r.clip.x + r.clip.w

	col := area.x
	i: int = 0
	for i < len(bytes) {
		ch, n := utf8.decode_rune(bytes[i:])
		if n <= 0 {
			ch, n = '?', 1
		}
		i += n

		width := glyph_columns(ch)
		if width == 0 {
			// A combining mark on its own is not drawable: termbox2 was built
			// without TB_OPT_EGC, so a base+mark grapheme cannot live in one
			// cell. Dropping it keeps the column arithmetic honest — it measured
			// 0, so nothing downstream shifts.
			r.stats.skipped += 1
			continue
		}

		if col >= clip_right {
			break
		}
		// A 2-cell glyph must not straddle the clip's right edge: claiming one of
		// its two cells would let it bleed past the scissor.
		if width > 1 && col+width > clip_right {
			break
		}

		if paint(r, col, area.y, ch, fg, bg) {
			r.stats.glyphs += 1
			if width > 1 {
				// Claim the trailing cell. termbox2 also skips it at present
				// time, but claiming it keeps *our* view of the buffer
				// deterministic: otherwise that cell still holds whatever an
				// earlier command painted there, and anything that reads the
				// buffer back (probes, hit-testing, tests) desyncs from the
				// screen.
				if paint(r, col+1, area.y, ' ', fg, bg) {
					r.stats.claimed += 1
				}
			}
		}

		col += width
	}
}
