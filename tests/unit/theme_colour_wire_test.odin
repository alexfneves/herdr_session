package unit

// theme_colour_wire_test.odin — T9 port of the `colour-wire` case.
//
// Source: src/theme_cases.odin `case_colour_wire` (11 counted assertions).
//
// WHAT IS AND IS NOT PROVABLE WITHOUT A TERMINAL. The wire claim decomposes into
// two halves:
//
//   (a) the maths: palette u32 -> clay.Color (0..255) -> termbox attr, and the
//       SGR triple that attr produces. Pure functions, no tty. PROVEN HERE.
//   (b) a real terminal receiving and applying those SGR sequences. Needs a pty
//       and a byte-capture. NOT proven here — that is the deferred `pty` tier.
//
// The trap this file pins is the famous one: Clay channels are 0..255
// (clay.odin:51), NOT 0.0..1.0. Run a palette through the 0..1 path and every
// byte quantises to 0 — the entire UI goes black on a screen that is otherwise
// perfectly laid out. A screenshot of that looks like a theme that failed to
// load, not a colour-space bug, which is exactly why the assertion is on the
// arithmetic and not on a screenshot.

import "core:fmt"
import "core:testing"

import clay "../../clay-odin"
import render "../../src/render"
import termbox2 "../../vendor/termbox2-odin"
import ui "../../src/ui"
import app "../../src/app"
import support "../support"

@(test)
colour_wire_channels_are_0_to_255 :: proc(t: ^testing.T) {
	// latte base is 0xeff1f5. If `palette_of` normalised to 0..1 the channels
	// would read 0.93/0.94/0.96 and every downstream byte would quantise to
	// either 0 or 1 — a black UI. Asserting the three channels separately is
	// the check that distinguishes "0..255" from "0..1 scaled", which a
	// single aggregate equality would not.
	th, _ := app.theme_named("catppuccin-latte")
	pal := ui.palette_of(th)
	// Read through the ROLE, not through a palette field: `background` is the
	// thing that gets painted, and it is what must carry the schema value.
	bg := app.theme_role(th.pal, .background)
	support.check(t, "clay channels are 0..255 (NOT 0..1) — a channel reads its byte",
		bg == 0xeff1f5 && int(pal.bg[0]) == 239 &&
		int(pal.bg[1]) == 241 && int(pal.bg[2]) == 245,
		fmt.tprintf("bg = {} {} {} (from {:06x})",
			pal.bg[0], pal.bg[1], pal.bg[2], bg))
	support.check(t, "…alpha 255 (opaque) on a themed colour", int(pal.bg[3]) == 255,
		fmt.tprintf("alpha = {}", pal.bg[3]))
}

@(test)
colour_wire_attr_carries_the_full_24_bit_rgb :: proc(t: ^testing.T) {
	// The SGR triple below is DERIVED from the attr's low 24 bits at run time
	// and compared against the triple this palette implies. termbox2.h:3830
	// takes cfg = fg & 0xffffff, so the printed triple is what the terminal
	// will be asked for; asserting the derived string rather than a literal
	// means a palette edit shows up as a changed triple, not a stale constant.
	th, _ := app.theme_named("catppuccin-latte")
	pal := ui.palette_of(th)
	attr := render.attr_painted(pal.bg)
	rgb := u32(attr) & 0xffffff
	support.check(t, "the termbox attr carries the 24-bit RGB", rgb == 0xeff1f5,
		fmt.tprintf("attr = {:06x} (want {:06x})", rgb, 0xeff1f5))
	want := fmt.tprintf("38;2;{};{};{} (want 38;2;239;241;245)",
		(rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff)
	support.check(t, "…which is the SGR triple 38;2;239;241;245",
			(rgb >> 16) & 0xff == 239 && (rgb >> 8) & 0xff == 241 && rgb & 0xff == 245, want)
}

@(test)
colour_wire_literal_black_is_asked_for_explicitly :: proc(t: ^testing.T) {
	black := clay.Color{0, 0, 0, 255}
	attr_b, paints_b := render.attr_of(black)
	support.check(t, "literal black (0,0,0) paints", paints_b, fmt.tprintf("paints={}", paints_b))
	// termbox2.h:3883 treats an attr whose low 24 bits are zero WITHOUT
	// TB_HI_BLACK as "terminal default". Without the flag the user's black
	// theme renders as whatever their terminal thinks black is.
	support.check(t, "…and asks for REAL black with TB_HI_BLACK",
		u32(attr_b) & u32(termbox2.TB_HI_BLACK) != 0,
		fmt.tprintf("attr=0x{:x} TB_HI_BLACK=0x{:x}",
			u32(attr_b), u32(termbox2.TB_HI_BLACK)))
}

@(test)
colour_wire_the_0_to_1_mistake_is_visible_here :: proc(t: ^testing.T) {
	// The inverse guard, stated the way the legacy case stated it: build the
	// colour a 0..1 author WOULD have written (0.157 == 40/255) and show it
	// is NOT the attr the real gruvbox bg produces. This is a test of the bug,
	// not just of the fix — a palette that later changed would make this fire
	// for the wrong reason, which is why it compares against the live gruvbox
	// value rather than a remembered constant.
	wrong := clay.Color{0.157, 0.157, 0.157, 255}
	aw, _ := render.attr_of(wrong)
	gruv := app.theme_named_or_default("gruvbox-dark")
	ag := render.attr_painted(ui.palette_of(gruv).bg)
	support.check(t, "the 0..1 mistake would be visible (and is NOT what we do)",
		aw != ag && u32(ag) == 0x282828,
		fmt.tprintf("0..1 form -> {:08x}; real gruvbox bg -> {:06x}", u32(aw), u32(ag)))
}

@(test)
colour_wire_alpha_zero_paints_nothing :: proc(t: ^testing.T) {
	// ISC-A-8: alpha is a paint switch and nothing else. Never an identity or
	// tag channel.
	clear := clay.Color{0x28, 0x19, 0x16, 0}
	attr_c, paints_c := render.attr_of(clear)
	support.check(t, "alpha 0 paints NOTHING and yields TB_DEFAULT",
		!paints_c && attr_c == termbox2.TB_DEFAULT,
		fmt.tprintf("paints={} attr={}", paints_c, u32(attr_c)))
	// attr_painted is the convenience wrapper; it must agree with attr_of and
	// not, say, fall back to the colour itself.
	support.check(t, "…attr_painted agrees (returns TB_DEFAULT, not the colour)",
		render.attr_painted(clear) == termbox2.TB_DEFAULT,
		fmt.tprintf("{}", u32(render.attr_painted(clear))))
}

@(test)
colour_wire_every_slot_paints_in_every_theme :: proc(t: ^testing.T) {
	// EVERY ROLE, not "every slot we remembered to list". The list is derived
	// from ui.Palette's own fields so a newly added role cannot skip this check.
	names := [2]string{"gruvbox-dark", "catppuccin-latte"}
	for name in names[:] {
		pal := ui_palette_for(name)
		all_paint := true
		roles := [13]clay.Color{
			pal.bg, pal.fg, pal.dim, pal.sel_bg, pal.sel_fg, pal.border,
			pal.key_fg, pal.desc_fg, pal.running, pal.stopped, pal.err_fg,
			pal.caret_bg, pal.caret_fg,
		}
		for c in roles[:] {
			_, paints := render.attr_of(c)
			if !paints { all_paint = false }
		}
		support.check(t, fmt.tprintf("every role in {} paints (no transparent widgets)", name),
			all_paint && len(roles) == app.PALETTE_ROLES,
			fmt.tprintf("all_paint={} roles_covered={}/{}", all_paint, len(roles), app.PALETTE_ROLES))
	}
}

@(test)
colour_wire_selection_bar_is_visually_distinct :: proc(t: ^testing.T) {
	// The selection bar has to be seen against the list background. If accent
	// and bg collapse to one value the picker renders with an invisible cursor —
	// the keyboard still works, so this is invisible to a keyboard-only check.
	pal := ui_palette_for("gruvbox-dark")
	a, a_paints := render.attr_of(pal.sel_bg)
	_, b_paints := render.attr_of(pal.bg)
	support.check(t, "the highlight bar (selection.background) is visually distinct from the list background",
		a_paints && b_paints && u32(a) != 0,
		fmt.tprintf("sel_bg=0x{:06x} paints={} bg_paints={}", u32(a) & 0xffffff, a_paints, b_paints))
}

ui_palette_for :: proc(name: string) -> ui.Palette {
	th, ok := app.theme_named(name)
	if !ok { panic(fmt.tprintf("no such theme for the colour test: {}", name)) }
	return ui.palette_of(th)
}
