package main

// PHASE 1 DRIVER — terminal binding + handoff smoke test.
//
// Phase 2's Clay->cell renderer cases live in `render_cases.odin` (same package);
// this file keeps the Phase 1 cases and the shared report plumbing.
//
// Its purpose is to retire plan risk A1 (`tb_shutdown()` → child → `tb_init()` is
// a clean handoff, verified by reading source but never *run*) with a dummy child,
// long before herdr is anywhere involved. The real poll loop replaces this file in
// Phase 3; every case below is driven by dev/handoff-smoke.sh, which runs each one
// inside a real pty and captures the evidence.
//
// Run inside a pty — there is no other way to own a terminal:
//   script -q -e -c "stty rows 40 cols 120; ./herdr-session handoff" /tmp/ts.log
//
// Cases (default: probe — safe with no controlling terminal):
//   probe            ABI checks (tb_wcwidth / attr width / truecolor / clay linked)
//   double         two tb_init/tb_shutdown round-trips + TB_ERR_INIT_ALREADY guard
//   handoff        sleep 2 in between; proves repaint + input survive the handoff
//   child <cwd> <argv...>  generic handoff with any child (used for the env/pgid,
//                          exit-code and group-signal probes)
//   sig-term       sits in the alt screen so the harness can SIGTERM us

import clay "../clay-odin"
import termbox2 "../vendor/termbox2-odin"
import terminal "./terminal"

import "core:fmt"
import "core:os"
import "core:sys/posix"

// ---------------------------------------------------------------------------
// Report plumbing — everything is buffered and printed once we are off the alt
// screen, so a human can actually read it and grep can match it.
// ---------------------------------------------------------------------------

report     : [dynamic]string
any_failed : bool

// say streams immediately as well as recording. Buffering the whole report and
// printing it at exit means a mid-case crash swallows every assertion — including
// the ones that passed, which is exactly the evidence you need to find the crash.
say :: proc(msg: string) {
	if len(report) == 0 {
		fmt.println("")
		fmt.println("=== herdr-session smoke report ===")
	}
	append(&report, msg)
	fmt.println(msg)
}

check :: proc(name: string, cond: bool, detail: string) {
	tag := "[PASS]"
	if !cond { tag = "[FAIL]" }
	say(fmt.tprintf("  {} {}   {}", tag, name, detail))
	if !cond { any_failed = true }
}

// The lines are already on stdout (see say); only the verdict is printed here.
print_report :: proc() {
	if any_failed {
		fmt.println("=== RESULT: FAIL ===")
	} else {
		fmt.println("=== RESULT: PASS ===")
	}
}

// ---------------------------------------------------------------------------
// Painting (deliberately minimal — the real Clay→cell renderer is Phase 2)
// ---------------------------------------------------------------------------

FRAMES_PAINTED : int = 0

FG : termbox2.Attr = termbox2.TB_GREEN
BG : termbox2.Attr = termbox2.TB_DEFAULT

draw_text :: proc(x, y: i32, s: string) {
	col := x
	for r in s {
		w := termbox2.tb_wcwidth(u32(r))
		if w < 1 { w = 1 }
		termbox2.tb_set_cell(col, y, u32(r), FG, BG)
		col += w
	}
}

draw_box :: proc(x0, y0, x1, y1: i32) {
	termbox2.tb_set_cell(x0, y0, u32('┌'), FG, BG)
	termbox2.tb_set_cell(x1, y0, u32('┐'), FG, BG)
	termbox2.tb_set_cell(x0, y1, u32('└'), FG, BG)
	termbox2.tb_set_cell(x1, y1, u32('┘'), FG, BG)
	for x in x0 + 1..<x1 { termbox2.tb_set_cell(x, y0, u32('─'), FG, BG) }
	for x in x0 + 1..<x1 { termbox2.tb_set_cell(x, y1, u32('─'), FG, BG) }
	for y in y0 + 1..<y1 { termbox2.tb_set_cell(x0, y, u32('│'), FG, BG) }
	for y in y0 + 1..<y1 { termbox2.tb_set_cell(x1, y, u32('│'), FG, BG) }
}

paint :: proc(title: string) {
	termbox2.tb_clear()
	cols, rows := termbox2.tb_width(), termbox2.tb_height()
	draw_box(0, 0, cols - 1, rows - 1)
	draw_text(2, 1, title)
	draw_text(2, 3, fmt.tprintf("{}x{} alt screen · truecolor · child runs between frames", cols, rows))
	termbox2.tb_present()
}

// force_repaint is the hook the handoff calls after re-acquiring the terminal
// (plan §Terminal handoff step 6). Counting the calls is how the smoke test proves
// the rule is actually enforced and not merely documented.
force_repaint :: proc() {
	FRAMES_PAINTED += 1
	paint(fmt.tprintf("frame {} — FORCED full repaint after handoff", FRAMES_PAINTED))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

enter_terminal :: proc() -> bool {
	rv := termbox2.tb_init()
	if rv != termbox2.TB_OK {
		say(fmt.tprintf("  [FAIL] tb_init -> {} ({})", rv, termbox2.tb_strerror(rv)))
		any_failed = true
		return false
	}
	termbox2.tb_set_output_mode(termbox2.OUTPUT_TRUECOLOR)
	termbox2.tb_hide_cursor()
	return true
}

leave_terminal :: proc() {
	termbox2.tb_shutdown()
}

write_pidfile :: proc() {
	path := os.get_env_alloc("HS_PIDFILE", context.allocator)
	if path == "" { return }
	f, err := os.open(path, os.File_Flags{.Write, .Create, .Trunc})
	if err != nil {
		say(fmt.tprintf("  [FAIL] cannot write pidfile {}: {}", path, err))
		any_failed = true
		return
	}
	defer os.close(f)
	// "<pid> <pgid> <sid>" — the harness group-kills the pgid to emulate what the
	// tty driver does with Ctrl-C.
	os.write_string(f, fmt.tprintf("{} {} {}\n",
		int(posix.getpid()), int(posix.getpgrp()), int(posix.getsid(0))))
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

// case_probe proves the foreign ABI is not garbled: tb_wcwidth is a real call into
// the archive with a real return value, and the width/truecolor queries report the
// TB_OPT_ATTR_W the archive was actually compiled with.
case_probe :: proc() -> bool {
	say("case probe — termbox2 ABI")
	check("tb_wcwidth('A') == 1", termbox2.tb_wcwidth(u32('A')) == 1,
		fmt.tprintf("got {}", termbox2.tb_wcwidth(u32('A'))))
	check("tb_wcwidth(U+4E00) == 2", termbox2.tb_wcwidth(0x4E00) == 2,
		fmt.tprintf("got {}", termbox2.tb_wcwidth(0x4E00)))
	check("tb_attr_width() == 32", termbox2.tb_attr_width() == 32,
		fmt.tprintf("got {} (TB_OPT_ATTR_W really built in)", termbox2.tb_attr_width()))
	check("tb_has_truecolor() == 1", termbox2.tb_has_truecolor() == 1,
		fmt.tprintf("got {}", termbox2.tb_has_truecolor()))
	check("clay archive linked", clay.MinMemorySize() > 0,
		fmt.tprintf("clay.MinMemorySize() = {} bytes", clay.MinMemorySize()))
	check("Event struct is 24 bytes", size_of(termbox2.Event) == 24,
		fmt.tprintf("size_of(termbox2.Event) = {}", size_of(termbox2.Event)))
	return !any_failed
}

// case_double calls the init/shutdown cycle twice. Guards: a second init without a
// shutdown must report TB_ERR_INIT_ALREADY, and a shutdown after a shutdown must
// report TB_ERR_NOT_INIT — the state machine must not double-free or lie.
case_double :: proc() -> bool {
	say("case double — two tb_init/tb_shutdown round-trips")

	r1 := termbox2.tb_init()
	check("first tb_init == TB_OK", r1 == termbox2.TB_OK, fmt.tprintf("{}", r1))
	if r1 != termbox2.TB_OK { return false }

	r2 := termbox2.tb_init()
	check("second tb_init == TB_ERR_INIT_ALREADY", r2 == termbox2.TB_ERR_INIT_ALREADY,
		fmt.tprintf("{} ({})", r2, termbox2.tb_strerror(r2)))

	r3 := termbox2.tb_shutdown()
	check("first tb_shutdown == TB_OK", r3 == termbox2.TB_OK, fmt.tprintf("{}", r3))

	r4 := termbox2.tb_shutdown()
	check("second tb_shutdown == TB_ERR_NOT_INIT", r4 == termbox2.TB_ERR_NOT_INIT,
		fmt.tprintf("{} ({})", r4, termbox2.tb_strerror(r4)))

	r5 := termbox2.tb_init()
	check("re-init after shutdown == TB_OK", r5 == termbox2.TB_OK, fmt.tprintf("{}", r5))
	r6 := termbox2.tb_shutdown()
	check("final tb_shutdown == TB_OK", r6 == termbox2.TB_OK, fmt.tprintf("{}", r6))
	return !any_failed
}

// case_handoff is the A1 test: paint, hand the terminal to `sleep 2`, take it back,
// then prove we can still paint *and* read input.
case_handoff :: proc() -> bool {
	say("case handoff — tb_shutdown -> sleep 2 -> tb_init")
	if !enter_terminal() { return false }
	paint("frame 1 — before the handoff")

	h := terminal.handoff_run({"sleep", "2"}, home_dir())
	check("child exit == 0", h.exit == 0, fmt.tprintf("got {} (killed_by={})", h.exit, h.killed_by))
	check("terminal re-acquired", h.ok, fmt.tprintf("ok={} err={} ({})", h.ok, h.err,
		termbox2.tb_strerror(h.err)))
	check("forced repaint ran after the handoff", FRAMES_PAINTED >= 1,
		fmt.tprintf("FRAMES_PAINTED={}", FRAMES_PAINTED))

	// Post-handoff input: read one key. Resizes are skipped (the harness may have
	// resized the pty) so only a key event counts.
	ev := termbox2.Event{}
	got_key := false
	saw_resize := false
	for _ in 0..<24 {
		// tb_peek_event returns TB_OK on success — the *kind* of event lives in
		// ev.typ, not in the return value (verified in wait_event, termbox2.h:3461).
		rv := termbox2.tb_peek_event(&ev, 500)
		if rv == termbox2.TB_ERR_NO_EVENT || rv == termbox2.TB_ERR_POLL { continue }
		if rv != termbox2.TB_OK {
			say(fmt.tprintf("  peek_event -> {} ({})", rv, termbox2.tb_strerror(rv)))
			break
		}
		if ev.typ == termbox2.EVENT_KEY {
			got_key = true
			break
		} else if ev.typ == termbox2.EVENT_RESIZE {
			saw_resize = true
			continue
		}
	}
	ch_hex := fmt.tprintf("%04X", ev.ch)
	check("a keypress is readable after the handoff", got_key,
		fmt.tprintf("key={} ch={} (U+{}) resize_seen_before_key={}",
			ev.key, ev.ch, ch_hex, saw_resize))

	leave_terminal()
	return !any_failed
}

// case_child is the generic probe entry point used by the harness:
//   ./herdr-session child <cwd> <argv...>
// It reports our own pid/pgid/sid next to the child's, which is how "same
// foreground process group, NO setsid" and "HERDR_* scrubbed" get checked.
case_child :: proc(cwd: string, argv: []string) -> bool {
	say(fmt.tprintf("case child — {} (cwd={})", argv[0], cwd))
	write_pidfile()  // so the harness can group-kill us exactly like the tty would
	if !enter_terminal() { return false }
	paint("frame 1 — handing the terminal over")

	say(fmt.tprintf("  SELF pid={} pgid={} sid={}",
		int(posix.getpid()), int(posix.getpgrp()), int(posix.getsid(0))))
	say("  (the child prints its own pid/pgid/sid + env straight to the inherited tty)")

	h := terminal.handoff_run(argv, cwd)
	check("handoff returned ok (terminal reacquired)", h.ok,
		fmt.tprintf("ok={} err={} ({})", h.ok, h.err, termbox2.tb_strerror(h.err)))
	say(fmt.tprintf("  CHILD exit={} killed_by={}", h.exit, h.killed_by))
	check("forced repaint ran", FRAMES_PAINTED >= 1, fmt.tprintf("FRAMES_PAINTED={}", FRAMES_PAINTED))
	leave_terminal()
	return !any_failed
}

// case_sig_term parks in the alt screen so the harness can send SIGTERM. Our
// handler must call tb_shutdown() and re-raise; the exit status must be 143 and the
// leave-alt-screen sequence must reach the tty.
case_sig_term :: proc() -> bool {
	say("case sig-term — SIGTERM while in the alt screen")
	write_pidfile()
	if !enter_terminal() { return false }
	paint("frame 1 — waiting for SIGTERM")
	// Nothing restores the screen but our own handler, so just idle in the peek.
	ev := termbox2.Event{}
	for _ in 0..<60 {
		termbox2.tb_peek_event(&ev, 500)
	}
	// Reaching here means no signal arrived in 30 s — the test did not run.
	say("  [FAIL] no SIGTERM arrived; the harness did not signal us")
	leave_terminal()
	return false
}

home_dir :: proc() -> string {
	h := os.get_env_alloc("HOME", context.allocator)
	if h == "" { return "/" }
	return h
}

// ---------------------------------------------------------------------------

usage :: proc() {
	fmt.eprintln(`herdr-session smoke driver
  probe                       termbox2 + clay ABI (safe with no tty)
  double                      two init/shutdown round-trips
  handoff                     leave -> child -> re-enter, repaint + input survive
  child <cwd> <argv...>       generic handoff with any child
  sig-term                    park in the alt screen for a SIGTERM
  measure                     Clay measure_text in display columns
  app-unit                    Phase 3 model/validation/exit-contract unit checks
  app-live                    Phase 3 against the real herdr binary + ssh fixture
  fetch-unit                  Phase 4 merge identity/isolation/selection (offline)
  fetch-live                  Phase 4 fan-out vs real ssh: concurrency, deadlines,
                              no zombies (needs HERDR_SESSION_TEST_REMOTE=…)
  render                      Clay commands -> cells: border, rule, alignment, colour
  clip                        scissor containment
  clay-error                  duplicate id survives the C frame
  layout-dump                 the raw render command stream
  ui-frame        T5.1 spine: border, section rules, title, footer geometry
  ui-sessions     T5.2 four fixed columns, live filter, selection, ordering
  ui-shrink       T5.2 real resize re-clamps the selection
  ui-edit         T5.3 caret is a display column; CJK/emoji typed + pasted
  ui-list         T5.3 one filtered list for both pickers
  ui-float        T5.3 floating error pane, Enter/Esc dismiss`)
}

main :: proc() {
	terminal.set_full_repaint(force_repaint)
	terminal.install_terminal_restore_handlers()

	args := os.args
	// Default to `probe` rather than a terminal case: a bare `nix run .` must stay
	// green even where there is no controlling tty (this very agent's shell, for
	// one). The real TUI replaces this driver in Phase 3.
	name := "probe"
	if len(args) > 1 { name = args[1] }
	ok := false

	switch name {
	case "probe":    ok = case_probe()
	case "double":   ok = case_double()
	case "handoff":  ok = case_handoff()
	case "sig-term": ok = case_sig_term()
	case "measure":    ok = case_measure()
	case "app-unit":  ok = case_app_unit()
	case "app-live":  ok = case_app_live()
	case "fetch-unit":  ok = case_fetch_unit()
	case "fetch-live":  ok = case_fetch_live()
	case "render":     ok = case_render()
	case "clip":       ok = case_clip()
	case "clay-error": ok = case_clay_error()
	case "layout-dump": ok = case_layout_dump()
	case "ui-frame":    ok = case_ui_frame()
	case "ui-sessions": ok = case_ui_sessions()
	case "ui-shrink":   ok = case_ui_shrink()
	case "ui-edit":     ok = case_ui_edit()
	case "ui-list":     ok = case_ui_list()
	case "ui-float":    ok = case_ui_float()
	case "child":
		if len(args) < 4 {
			usage()
			os.exit(2)
		}
		ok = case_child(args[2], args[3:])
	case:
		usage()
		os.exit(2)
	}

	print_report()
	code := 0
	if !ok { code = 1 }
	os.exit(code)
}
