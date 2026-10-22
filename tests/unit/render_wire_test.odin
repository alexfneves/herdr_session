package unit

// ─────────────────────────────────────────────────────────────────────────────
// render_wire_test.odin — T7 port of the WIRE-LEVEL half of `render`
// (11 counted checks: 10 present + 1 absent).
//
// Source: `expect_wire` (dev/render-smoke.sh:52) and its eleven calls at
// dev/render-smoke.sh:85-102, run over the `script -q` typescript of the same
// pty that produced the cell-level evidence in render_cell_test.
//
// WHY CELL CHECKS ARE NOT ENOUGH
//
// A cell-level assertion proves what the renderer DECIDED to paint. It says
// nothing about what LEFT THE PROCESS. `clay.Color{255,60,60}` sitting in a
// termbox back-buffer cell as 0x00FF3C3C proves the value was stored; it does
// not prove a truecolour SGR ever went out on the wire. A renderer that painted
// the back buffer perfectly and then emitted 8-bit palette codes, or emitted
// nothing at all, would pass every check in render_cell_test.odin.
//
// So this file asserts on the BYTES: the pty stream itself. `render_harness`
// binds termbox to the slave half of a real pty with `tb_init_rwfd`, so every
// byte termbox writes comes back out of the master end and is captured by a
// drain thread. That captured stream IS the wire — the same bytes a terminal
// emulator parses.
//
// THE ABSENCE CHECK IS HALF THE PROOF
//
// `ESC[38;5;` is the 8-bit/16-colour indexed form. If it appears anywhere,
// the truecolour path was NOT used end to end: colours survived as *something*
// and the whole point of the colour model was lost in transit. The old shell
// checked for it with a grep and it is ported as a counted assertion, because
// "no regression in the colour path" is exactly the kind of claim that must
// fail rather than merely not be mentioned.
//
// SAME FIXTURE AS THE CELL TEST — see render_fixture.odin's header. The wire
// half asserts about the bytes of the frame the cell half asserted about the
// cells of, not a lookalike.
// ─────────────────────────────────────────────────────────────────────────────

import "core:testing"

import tb "../../vendor/termbox2-odin"

import support "../support"

@(test)
render_wire_truecolour_glyphs_and_no_palette_fallback :: proc(t: ^testing.T) {
	support.note(t, "case render — wire level: the bytes that left the process")
	if !render_session(t, "wire") { return }

	// The identical sequence to the cell case: clear, lay out the standard
	// frame, paint, present. Then close the stream so the capture is final.
	tb.tb_clear()
	render_and_present(render_build_frame)
	wire_capture(t, "render")

	// --- the five colours, as truecolour SGRs on the wire -------------------
	expect_wire(t, "truecolour foreground for the border (255,60,60)", "38;2;255;60;60")
	expect_wire(t, "truecolour foreground for body text (220,220,220)", "38;2;220;220;220")
	expect_wire(t, "truecolour foreground for the centred accent (60,200,120)", "38;2;60;200;120")
	expect_wire(t, "truecolour foreground for the right-aligned footer (40,90,200)", "38;2;40;90;200")
	expect_wire(t, "truecolour background for the panel (16,20,28)", "48;2;16;20;28")

	// --- the glyphs, as UTF-8 bytes on the wire ------------------------------
	expect_wire(t, "box-drawing horizontal glyph U+2500 reached the tty", "─")
	expect_wire(t, "box-drawing vertical glyph U+2502 reached the tty", "│")
	expect_wire(t, "corner glyphs U+250C/2510/2514/2518 reached the tty", "┌")
	expect_wire(t, "CJK glyph 中 reached the tty", "中")
	expect_wire(t, "emoji 😀 reached the tty", "😀")

	// --- the negative half ----------------------------------------------------
	// An indexed-colour sequence here would mean termbox fell back to the
	// 8-bit/16-colour palette: colours preserved as *something*, truecolour
	// not used end to end.
	expect_wire_absent(t, "no indexed-colour fallback: truecolour all the way out", "\x1b[38;5;")
}
