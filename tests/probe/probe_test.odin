package probe

import "core:fmt"
import "core:testing"

import clay "../../clay-odin"
import tb "../../vendor/termbox2-odin"

import support "../support"

mark :: proc(s: string) {
	fmt.eprintln("[PROBE] {}", s)
}

paint_clip :: proc(t: ^testing.T, label: string, reset_front: bool) {
	if reset_front {
		// Present an EMPTY frame first so termbox's diff baseline is a blank
		// screen, then repaint. Without this the emit is a diff against
		// whatever an earlier session left in the front buffer.
		tb.tb_clear()
		tb.tb_present()
	}
	tb.tb_set_clear_attrs(RENDER_SENTINEL_FG, RENDER_SENTINEL_BG)
	tb.tb_clear()
	clay.BeginLayout()
	render_build_clip()
	cmds := clay.EndLayout(0)
	stats := render_paint_cmds(cmds)
	mark(fmt.tprintf("{} painted scissors={}", label, stats.scissors))
}

@(test)
probe_a_plain :: proc(t: ^testing.T) {
	mark("A enter")
	if !render_session(t, "A") { return }
	paint_clip(t, "A", false)
	wire_capture(t, "A")
	dump_wire("A")
}

@(test)
probe_b_plain_second :: proc(t: ^testing.T) {
	mark("B enter")
	if !render_session(t, "B") { return }
	paint_clip(t, "B", false)
	wire_capture(t, "B")
	dump_wire("B")
}

@(test)
probe_c_reset_third :: proc(t: ^testing.T) {
	mark("C enter")
	if !render_session(t, "C") { return }
	paint_clip(t, "C", true)
	wire_capture(t, "C")
	dump_wire("C")
}

@(test)
probe_d_reset_fourth :: proc(t: ^testing.T) {
	mark("D enter")
	if !render_session(t, "D") { return }
	paint_clip(t, "D", true)
	wire_capture(t, "D")
	dump_wire("D")
}
