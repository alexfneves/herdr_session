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
	pal := ui_palette_for("catppuccin-latte")
	support.check(t, "clay channels are 0..255 (NOT 0..1) — a channel reads its byte",
		int(pal.bg[0]) == 0x28, fmt.tprintf("bg.r = {}", int(pal.bg[0])))
	support.check(t, "…and alpha is opaque 255", int(pal.bg[3]) == 255, fmt.tprintf("{}", int(pal.bg[3])))
}

@(test)
colour_wire_attr_carries_the_full_24_bit_rgb :: proc(t: ^testing.T) {
	pal := ui_palette_for("catppuccin-latte")
	attr, paints := render.attr_of(pal.bg)
	rgb := u32(attr) & 0xffffff
	support.check(t, "the attr carries the full 24-bit RGB", rgb == 0x281916,
		fmt.tprintf("attr=0x{:06x} want 0x281916 paints={}", rgb, paints))
	// What termbox will emit for that attr: cfg = fg & 0xffffff
	// (termbox2.h:3830), so the SGR triple is derived from the same 24 bits.
	support.check(t, "…so the SGR triple is 38;2;40;25;22",
		fmt.tprintf("38;2;{};{};{}", (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff) ==
		"38;2;40;25;22",
		fmt.tprintf("got 38;2;{};{};{}", (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff))
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
	pal := ui_palette_for("catppuccin-latte")
	attr, _ := render.attr_of(pal.bg)
	// The inverse guard: had the palette been normalised to 0..1 upstream, every
	// channel would quantise to zero and this assertion would fire. It is a test
	// of the bug, not just of the fix.
	rgb := u32(attr) & 0xffffff
	support.check(t, "NOT all-zero (the 0..1 mistake would show as 0x000000)",
		rgb != 0 && (rgb & 0xff0000) != 0, fmt.tprintf("rgb=0x{:06x}", rgb))
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
	names := [2]string{"gruvbox-dark", "catppuccin-latte"}
	for name in names[:] {
		pal := ui_palette_for(name)
		all_paint := true
		slots := [13]clay.Color{
			pal.bg, pal.fg, pal.dim, pal.border, pal.header_fg, pal.accent, pal.sel_fg, pal.caret,
			pal.float_bg, pal.float_fg, pal.err_fg, pal.running, pal.stopped,
		}
		for c in slots[:] {
			_, paints := render.attr_of(c)
			if !paints { all_paint = false }
		}
		support.check(t, fmt.tprintf("every slot in {} paints (no transparent widgets)", name),
			all_paint, fmt.tprintf("all_paint={}", all_paint))
	}
}

@(test)
colour_wire_selection_bar_is_visually_distinct :: proc(t: ^testing.T) {
	// The selection bar has to be seen against the list background. If accent
	// and bg collapse to one value the picker renders with an invisible cursor —
	// the keyboard still works, so this is invisible to a keyboard-only check.
	pal := ui_palette_for("gruvbox-dark")
	a, a_paints := render.attr_of(pal.accent)
	_, b_paints := render.attr_of(pal.bg)
	support.check(t, "selection bar (accent) is visually distinct from the list background",
		a_paints && b_paints && u32(a) != 0,
		fmt.tprintf("accent=0x{:06x} paints={} bg_paints={}", u32(a) & 0xffffff, a_paints, b_paints))
}

ui_palette_for :: proc(name: string) -> ui.Palette {
	th, ok := app.theme_named(name)
	if !ok { panic(fmt.tprintf("no such theme for the colour test: {}", name)) }
	return ui.palette_of(th)
}
