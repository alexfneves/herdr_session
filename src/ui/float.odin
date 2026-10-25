package ui

// ============================================================================
// ui.float — the floating error pane (T5.3)
//
// A pane that floats OVER everything else without disturbing the layout, built on
// exactly one Clay feature:
//
//     floating = clay.FloatingElementConfig{
//         attachTo = .Root,        // positioned against the root, not the sibling flow
//         zIndex   = FLOAT_Z,     // painted after (over) every non-floating element
//         ...
//     }
//
// Because it is attached to the ROOT rather than to the element declared after it,
// the pane can be painted from anywhere inside the tree — including from inside
// MAIN — and still land in the middle of the terminal. And because siblings that
// appear before or after it are laid out as if it were not there, opening the
// pane moves no other content: the session table under it stays exactly where it
// was, which is what "floats over everything" has to mean.
//
// ── NO OVERLAY TINT ─────────────────────────────────────────────────────────
// The pane is opaque: a solid background plus a border, both drawn by
// Clay -> render.paint. Phase 2 left Clay's overlay tint as a deliberate no-op in
// our renderer, so a pane that relied on tinting would render as nothing. Opaque
// is also the honest choice for an error: it covers, it does not smudge.
//
// ── HOW THE PANE MAPS ONTO THE COLOUR SCHEMA ────────────────────────────────
// The upstream `colors.*` schema has no "floating surface" key, and the role
// table does not invent one. So the pane is composed entirely of roles that DO
// exist: the page's own `background` as its fill, the `error` role for its
// frame and title, `text` for the body lines and `secondary` for the dismiss
// hint. A bordered box of the page's own colour is how a terminal has always
// delimited a panel; picking `selection.background` instead would have made the
// pane read as a selected row, which is a different thing entirely. The
// consequence — the pane is separated by its border rather than by a darker
// surface — is reported as a decision outside the role table rather than
// papered over with a colour the schema does not have.
//
// ── DISMISSAL ───────────────────────────────────────────────────────────────
// Enter or Escape closes it — see float_is_dismiss_key. That predicate lives HERE,
// with the pane, so the "Enter dismisses" rule cannot drift away from the widget
// it belongs to. The state machine (T5.4) asks the question; this file owns the
// answer.
// ============================================================================

import clay "../../clay-odin"
import tb "../../vendor/termbox2-odin"

FLOAT_ID :: "hs.float"
FLOAT_Z : i16 = 100 // above every non-floating element in the frame

FLOAT_PAD_X :: 2
FLOAT_BORDER :: 1

// Float is the pane's content. The caller (error ring -> T5.5) owns the strings.
Float :: struct {
	title : string,
	lines : []string,
	dismiss : string, // footer hint, e.g. "enter/esc dismiss"
}

// float_size computes the pane's box from its content, capped by the terminal.
float_size :: proc(f: ^Float, avail_cols: i32) -> (w, h: i32) {
	widest := text_cols(f.title)
	for l in f.lines {
		c := text_cols(l)
		if c > widest {
			widest = c
		}
	}
	dw := text_cols(f.dismiss)
	if dw > widest {
		widest = dw
	}
	w = widest + 2*FLOAT_PAD_X + 2*FLOAT_BORDER
	max_w := avail_cols - 2 // always leave a cell of the frame visible on each side
	if max_w < 10 {
		max_w = 10
	}
	if w > max_w {
		w = max_w
	}
	// 1 title + N body + 1 dismiss hint + top/bottom border + 1 breathing row.
	h = i32(len(f.lines)) + 3 + 2*FLOAT_BORDER
	if h > 20 {
		h = 20
	}
	return w, h
}

// float_paint draws the pane. Call it while the frame's root element is open; the
// floating config lifts it out of the sibling flow and pins it to the root.
float_paint :: proc(f: ^Float, avail_cols: i32, pal: ^Palette) {
	w, h := float_size(f, avail_cols)
	inner_w := w - 2*FLOAT_BORDER - 2*FLOAT_PAD_X
	if inner_w < 4 {
		inner_w = 4
	}
	if clay.UI(clay.ID(FLOAT_ID))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingFixed(f32(w)),
				height = clay.SizingFixed(f32(h)),
			},
			layoutDirection = clay.LayoutDirection.TopToBottom,
			padding = clay.PaddingAll(FLOAT_PAD_X),
			childGap = 1,
		},
		backgroundColor = pal.bg,
		border = clay.BorderElementConfig{color = pal.err_fg, width = clay.BorderAll(FLOAT_BORDER)},
		floating = clay.FloatingElementConfig{
			attachTo   = clay.FloatingAttachToElement.Root, // pinned to the root, not the flow
			zIndex     = FLOAT_Z,                          // painted over everything else
			attachment = clay.FloatingAttachPoints{
				element = clay.FloatingAttachPointType.CenterTop,
				parent  = clay.FloatingAttachPointType.CenterCenter,
			},
			offset = clay.Vector2{0, 0},
			pointerCaptureMode = clay.PointerCaptureMode.Passthrough,
		},
	}) {
		clay.Text(ellipsize(f.title, inner_w), clay.TextElementConfig{textColor = pal.err_fg})
		for l in f.lines {
			clay.Text(ellipsize(l, inner_w), clay.TextElementConfig{textColor = pal.fg})
		}
		if len(f.dismiss) > 0 {
			clay.Text(ellipsize(f.dismiss, inner_w), clay.TextElementConfig{textColor = pal.dim})
		}
	}
}

// ── dismissal ──────────────────────────────────────────────────────────────

// float_is_dismiss_key is THE rule: Enter or Escape closes the pane. It lives with
// the pane so the key binding and the widget cannot disagree.
//
// Escape arrives as TB_KEY_ESC (0x1b) and Enter as TB_KEY_ENTER (0x0d). Nothing
// else dismisses — a stray printable must not silently close an error the user
// was still reading.
float_is_dismiss_key :: proc(ev: ^tb.Event) -> bool {
	if ev == nil {
		return false
	}
	if ev.typ != tb.EVENT_KEY {
		return false
	}
	if ev.key == tb.KEY_ESC || ev.key == tb.KEY_ENTER {
		return true
	}
	// Some terminals deliver the raw byte without setting `key`; match the byte
	// too so Enter/Esc cannot sneak through as a "printable".
	return ev.ch == 0x0d || ev.ch == 0x1b || ev.ch == 0x0a
}

// float_dismiss_keys is the footer text, kept in sync with the predicate above.
float_dismiss_hint :: proc() -> string {
	return "enter / esc dismiss"
}
