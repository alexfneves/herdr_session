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
import app "./app"
import input "./input"
import ui "./ui"

import "core:c"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:time"

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

// ============================================================================
// T5.5 — THE REAL TUI
// ============================================================================
//
// Everything below replaces the Phase 1 driver for the case that matters: a
// human on a real terminal. The shape is fixed by the plan and by the modules
// that already exist — nothing here invents a layer that T1..T5.4 already own:
//
//   keymap  decodes the tty bytes          (T5.4)
//   state   decides what the key MEANS     (T5.4)   update(app,key) -> Command
//   exec    turns a Command into an effect (T5.5)   execute(cmd,rows,home)
//   fetch   owns every list child          (T4)
//   handoff owns the terminal handover     (T2)
//   ui      paints                         (T5.1..T5.3)
//
// The loop is a single-threaded poll() over the union of:
//   * termbox's tty fd        (keys)
//   * termbox's resize pipe   (SIGWINCH, delivered by termbox to itself)
//   * every in-flight fetch's stdout/stderr pipe
// …so "bytes arrived from host X" and "the user pressed a key" wake the same
// wait, and the deadline arithmetic rides along in the poll timeout. One thread,
// no spin: when nothing is pending we block with timeout == -1 and burn no CPU.
//
// The whole struct lives at module scope because Odin procedure literals capture
// the context and NOT the caller's locals, so a callback-shaped design would not
// compile the moment it needed the app's state (same reason the frame is
// open/close rather than a closure — see ui/frame.odin).

Tui :: struct {
	machine  : app.App,      // the 7-state machine; `update` is its only door
	table    : app.Table,    // merged (device,name) rows + per-host status
	reg      : app.Registry, // every in-flight list child

	painter  : ui.Painter,
	frame    : ui.Frame,
	sess     : ui.Sessions,
	name_ed  : ui.Edit,
	filter_ed: ui.Edit,
	list     : ui.List,
	flt      : ui.Float,
	pal      : ui.Palette,

	cfg     : app.Config, // what ~/.config/herdr_session.json said (T6.1)

	remotes     : []app.Remote,
	themes      : []string,  // canonical palette names, picker order
	theme_now   : string,    // the applied theme's canonical name
	theme       : app.Theme, // its colours, resolved once at boot
	remote_rows : [dynamic]ui.Picker_Row,
	theme_rows  : [dynamic]ui.Picker_Row,
	shown_rows  : [dynamic]app.Session, // machine-filtered projection, reused
	fds         : [dynamic]posix.pollfd,

	notice   : string, // last executor line; cleared by the next keypress
	dirty    : bool,
	quitting : bool
}

tui : Tui

// ── terminal ownership ────────────────────────────────────────────────────

// tui_is_a_tty is the `nix run .` gate. Piping the TUI into a file or a pipe
// must produce a clean sentence and a non-zero exit, not a panic, not a mangled
// screen, and not 40 silent frames of nothing.
tui_is_a_tty :: proc() -> bool {
	return bool(posix.isatty(0)) && bool(posix.isatty(1))
}

tui_die :: proc(msg: string) {
	fmt.eprintf("herdr-session: {}\n", msg)
	os.exit(3)
}

// ── remote discovery ─────────────────────────────────────────────────────

// tui_config_remotes is the O7 seam, now actually filled by the loader.
//
// Before T6.1 this function WAS the configured set (built from fixture env
// vars), which is why discovery had a parameter with no producer. It is now the
// union of two sources with different standing:
//
//   1. tui.cfg.remotes — the product path: `"remotes"` in
//      ~/.config/herdr_session.json, verbatim ssh targets.
//   2. tui_fixture_remotes() — the DEV path: the loopback fixture the T4/T5
//      smoke suites already drive over real ssh, appended on top.
//
// Both are needed and they are kept visibly separate so nobody mistakes the
// fixture for a product concept, and so removing the fixture later is deleting
// one proc rather than re-deriving the seam.
tui_config_remotes :: proc() -> []app.Remote {
	out := make([dynamic]app.Remote, 0, len(tui.cfg.remotes) + 2)
	for r in tui.cfg.remotes { append(&out, r) }
	for r in tui_fixture_remotes() {
		// The config wins a collision: a user who wrote the same target by hand
		// with a label should not be overwritten by the fixture's bare target.
		dup := false
		for have in out { if have.device == r.device { dup = true } }
		if !dup { append(&out, r) }
	}
	return out[:]
}

// tui_fixture_remotes is the dev-only host set: HERDR_SESSION_TEST_REMOTE (a
// loopback ssh target), its alias, and HERDR_SESSION_TEST_UNREACHABLE (a
// black-hole host that makes "one host is down" a measurable thing rather
// than an assertion). Reading them HERE and nowhere else is what keeps the
// fixture-host-name grep over src/ empty while the loopback fixture still
// exercises the real ssh path.
tui_fixture_remotes :: proc() -> []app.Remote {
	out := make([dynamic]app.Remote, 0, 2)
	target := os.get_env_alloc("HERDR_SESSION_TEST_REMOTE", context.allocator)
	if target != "" {
		label := os.get_env_alloc("HERDR_SESSION_TEST_REMOTE_ALIAS", context.allocator)
		append(&out, app.Remote{device = target, label = label})
	}
	dead := os.get_env_alloc("HERDR_SESSION_TEST_UNREACHABLE", context.allocator)
	if dead != "" {
		append(&out, app.Remote{device = dead, label = dead})
	}
	return out[:]
}

// tui_discover probes the machine registry ONCE at startup (cached: on 0.8.2 it
// is a guaranteed error path and paying it per refresh buys nothing) and falls
// back to the configured set.
tui_discover :: proc() -> app.Discovery {
	probe := app.run_capture(app.machine_probe_argv(), app.CAPTURE_TIMEOUT)
	payload : []byte = nil
	if probe.code == 0 { payload = probe.out[:] }  // stdout ONLY — never merged
	return app.discover_resolved(payload, tui_config_remotes())
}

// ── the fetch fan-out ────────────────────────────────────────────────────

// cloak keeps our private capture pipes out of the handoff child. handoff_run
// forks with inherited stdio, and an inherited read end of a fetch pipe is an fd
// leak into a long-lived herdr session for no reason at all.
cloak_fetch :: proc(f: ^app.Fetch) {
	if f == nil || !f.spawned { return }
	posix.fcntl(f.out_fd, .SETFD, c.int(posix.FD_CLOEXEC))
	posix.fcntl(f.err_fd, .SETFD, c.int(posix.FD_CLOEXEC))
}

tui_fan_out :: proc() {
	for r in tui.remotes {
		f := app.spawn_remote_fetch(r, app.FETCH_DEADLINE)
		cloak_fetch(f)
		app.registry_add(&tui.reg, f)
	}
}

// tui_refresh retires every in-flight snapshot and starts a new round: the local
// list inline (it is ~3 ms and it is what the user is looking at) plus a fresh
// fan-out. An in-flight fetch that was superseded is killed AND reaped, so a
// refresh can never leak a child or merge a stale list over a newer one.
tui_refresh :: proc() {
	for f in app.registry_all(&tui.reg) {
		if app.fetch_pending(f) {
			app.fetch_kill(f)
			app.kill_and_reap(f)
		}
	}
	app.registry_free(&tui.reg)
	tui.reg = app.Registry{}

	app.local_snapshot(&tui.table, app.LOCAL_FETCH_DEADLINE)
	tui_fan_out()
	tui_sync_model()
}

// tui_sync_model repoints the machine at the live rows and re-places the
// selection BY IDENTITY, which is the whole reason `held` exists: a refresh that
// reorders the table cannot move the user's cursor to a different session.
tui_sync_model :: proc() {
	tui.machine.sessions = tui.table.rows[:]
	app.rebuild_shown(&tui.machine)
}

// ── effects ──────────────────────────────────────────────────────────────

// tui_run_command is the only place a Command leaves the machine.
tui_run_command :: proc(cmd: app.Command) {
	// Machine-side commands need no executor: `update` already moved the state and
	// already emptied the text it owns, and the view re-reads that text every
	// frame, so there is nothing left to synchronise by hand.
	#partial switch cmd.kind {
	case .none, .clear_filter, .clear_field, .show_error:
		return
	case .quit:
		tui.quitting = true
		return
	case: break
	}

	eff := app.execute(cmd, tui.table.rows[:], home_dir(), app.CAPTURE_TIMEOUT)

	#partial switch eff.kind {
	case .refused:
		// A refusal is a fact the user has to see, and {Error} is where facts go.
		app.to_error(&tui.machine, eff.message)
	case .quit:
		tui.quitting = true
	case .applied:
		// The executor says what it applied; tui_persist_theme says whether the
		// choice reached the file. Both halves belong in the notice, and the
		// second must not be dropped — an unreported failed save is worse than
		// a reported one.
		tui.notice = eff.message
		if eff.theme != "" {
			suffix := tui_persist_theme(eff.theme)
			if suffix != "" { tui.notice = fmt.tprintf("{}{}", tui.notice, suffix) }
		}
	case .none:
		break
	case:
		tui.notice = eff.message
	}

	if eff.refresh { tui_refresh() }
	tui.dirty = true
}

// tui_apply_theme is the ISC-7 persistence path: paint now, save the choice,
// and make the notice say whether the save happened.
//
// WHY HERE AND NOT IN THE EXECUTOR
//
// The executor is the choke point for effects, but its signature
// `execute(cmd, rows, home, timeout) -> Effect` is pinned by 339 existing app
// checks, and threading a config path through it for one command is a wider
// change than the feature is worth. `tui_run_command` is the ONLY consumer of
// Effect in the program, so there is exactly one place an applied theme can
// arrive from, and it is this one. The honesty requirement — a save that failed
// must not be reported as a save — is met by putting the outcome in the notice.
tui_persist_theme :: proc(name: string) -> string {
	t, ok := app.theme_named(name)
	if !ok {
		// The machine only offers canonical names, so this is a bug and not a
		// user error; keep the current palette rather than painting with nothing.
		return fmt.tprintf(" — NOT applied: '{}' is not a compiled-in palette", name)
	}
	tui.theme = t
	tui.theme_now = t.name
	tui.pal = ui.palette_of(t)
	saved, err := app.config_save_theme(tui.cfg.path, t.name)
	if saved {
		// The file now agrees with the screen, so a load-time warning about an
		// unknown or broken theme is no longer true and must stop being shown.
		clear(&tui.cfg.warnings)
		tui.cfg.theme = t.name
		tui.cfg.theme_fell_back = false
		return fmt.tprintf(" and saved to {}", tui.cfg.path)
	}
	// Painted but not persisted: say so, because "applied" alone would be a
	// lie about what the next start does.
	return fmt.tprintf(" but NOT SAVED: {}", err)
}

// ── events ───────────────────────────────────────────────────────────────

tui_on_key :: proc(k: input.Key) {
	tui.notice = ""            // the last key always supersedes the last verdict
	cmd := app.update(&tui.machine, k)
	// Dirty on EVERY key, not only on the keys that triggered an effect: most
	// keys change the machine (state, filter, cursor) and nothing else will tell
	// the painter about it. The renderer diffs, so a key that changed nothing
	// repaints nothing — marking anyway costs a comparison, not a screen.
	tui.dirty = true
	tui_run_command(cmd)
}

tui_on_resize :: proc() {
	// Nothing to compute: the next paint re-reads tb_width/tb_height, re-runs
	// frame_layout, re-clamps the selection and repaints. Doing it here instead
	// of on the next keypress is what makes a resize visible WITHOUT a key.
	tui.dirty = true
}

// tui_take_event pulls one termbox event without blocking. Returns false when
// the queue is empty (the caller then goes to poll), and sets `lost` on a real
// termbox failure so a dead terminal cannot turn the loop into a spin.
tui_take_event :: proc() -> (got: bool, lost: bool) {
	ev := termbox2.Event{}
	rv := termbox2.tb_peek_event(&ev, 0)
	if rv == termbox2.TB_ERR_NO_EVENT || rv == termbox2.TB_ERR_POLL {
		return false, false
	}
	if rv != termbox2.TB_OK {
		fmt.eprintf("herdr-session: tb_peek_event -> {}\n", termbox2.tb_strerror(rv))
		return false, true
	}
	if ev.typ == termbox2.EVENT_RESIZE {
		tui_on_resize()
	} else if ev.typ == termbox2.EVENT_KEY {
		tui_on_key(input.from_event(&ev))
	}
	return true, false
}

// tui_service_fetches drains every live child, settles what finished, merges it
// and kills what overran. All four steps are non-blocking (fetch_drain stops at
// EAGAIN, fetch_reap is WNOHANG-only, kill_and_reap is for children we already
// SIGKILLed), so this is safe to call on every wake.
tui_service_fetches :: proc() {
	app.registry_pump(&tui.reg)
	app.registry_settle_drained(&tui.reg)
	for f in app.registry_all(&tui.reg) {
		if f.settled && !f.merged { tui_merge(f) }
	}
	app.registry_expire(&tui.reg)
	app.registry_reap_debts(&tui.reg)
}

// tui_merge folds one settled fetch into the table and marks it consumed, so a
// settled child is merged exactly once even though the loop looks at it again.
tui_merge :: proc(f: ^app.Fetch) {
	app.apply(&tui.table, f)
	f.merged = true
	tui_sync_model()
	tui.dirty = true
}

// ── the wait ─────────────────────────────────────────────────────────────

// tui_wait blocks until the tty has a key, the resize pipe speaks, a fetch has
// bytes, or the earliest deadline arrives. `timeout == -1` when nothing is in
// flight: the process then sleeps until the user does something, which is the
// difference between an event loop and a spin lock.
tui_wait :: proc() {
	clear(&tui.fds)
	ttyfd, rsfd : i32 = -1, -1
	if termbox2.tb_get_fds(&ttyfd, &rsfd) != termbox2.TB_OK { return }
	append(&tui.fds, posix.pollfd{fd = posix.FD(ttyfd), events = {.IN}})
	append(&tui.fds, posix.pollfd{fd = posix.FD(rsfd),  events = {.IN}})
	app.registry_fds(&tui.reg, &tui.fds)

	// The timeout is a three-way min, and the middle term is not a knob.
	//
	// A fetch whose stdout AND stderr have both hit EOF leaves the poll set (there
	// is nothing left to read from it), but that does NOT mean it is finished:
	// the child closes its pipes a moment before it exits, so the very next
	// `waitpid(WNOHANG)` can still return 0. At that instant the fetch has no
	// fd anywhere in this set, so no I/O event will ever wake us for it again —
	// measured: a healthy loopback fetch had both EOFs at +155 ms and did not
	// settle until +5014 ms, when an unrelated host's ssh finally exited and woke
	// the poll. Blocking on `min_remaining` alone turns "the child has not been
	// collected yet" into "the app is frozen for 13 seconds".
	//
	// So while anything is in flight the sleep is capped at POLL_SLICE, exactly
	// the discipline `registry_step` uses for the same reason. Ten extra wakeups
	// per second while a fetch lives costs nothing measurable; blocking with no
	// timer at all is still what happens once the registry is empty, which is
	// what keeps the idle CPU at zero.
	timeout : i32 = -1
	if app.registry_pending(&tui.reg) > 0 {
		left := app.registry_min_remaining(&tui.reg)
		ms := i32(time.duration_milliseconds(left))
		if ms < 0 { ms = 0 }
		slice := i32(time.duration_milliseconds(app.POLL_SLICE))
		if ms > slice { ms = slice }
		timeout = ms
	}

	if len(tui.fds) == 0 { return }
	TUI_POLLS += 1
	rv := posix.poll(&tui.fds[0], posix.nfds_t(len(tui.fds)), timeout)
	if rv > 0 {
		TUI_POLL_HITS += 1
	} else if rv == 0 {
		TUI_POLL_IDLES += 1
	} else {
		TUI_POLL_ERRS += 1
	}
}

// ── projection helpers ───────────────────────────────────────────────────

pick_device_id    :: proc(r: app.Remote) -> string { return r.device }
pick_device_label :: proc(r: app.Remote) -> string { return app.remote_label(r) }
pick_device_detail:: proc(r: app.Remote) -> string { return "ssh target (verbatim)" }

pick_theme_id     :: proc(s: string) -> string { return s }
pick_theme_label  :: proc(s: string) -> string { return s }

// pick_theme_detail marks the row that is currently applied, so the picker
// shows live state and not just a list. The machine's filter is a substring
// match on the NAME only (state.theme_matches), so this text cannot change
// which rows are shown — it is purely what the user reads.
pick_theme_detail :: proc(s: string) -> string {
	if s == tui.theme_now { return "(current)" }
	return ""
}

// tui_project_shown rebuilds the machine-filtered session slice the table view
// paints. Reused buffer: no allocation per frame, and no aliasing either — the
// view never writes through it.
//
// `shown` holds INDICES into `sessions`, and Odin's `for x, i in xs` binds x to
// the element and i to the position: the index we need is the ELEMENT. Reading
// it off the position instead is invisible until a filter is active — with no
// filter the two are identical, which is exactly how this was missed.
tui_project_shown :: proc() -> []app.Session {
	clear(&tui.shown_rows)
	rows := tui.machine.sessions
	for idx, _ in tui.machine.shown {
		if idx >= 0 && idx < len(rows) { append(&tui.shown_rows, rows[idx]) }
	}
	return tui.shown_rows[:]
}

// tui_sync_text copies the MACHINE's text into a view editor. The machine owns
// filter/field text (T5.4); the view only renders it. Feeding typed characters
// straight to the editor would put the caret somewhere the machine has never
// heard of, so the copy goes one way only, once per frame.
tui_sync_text :: proc(e: ^ui.Edit, s: string) {
	ui.edit_clear(e)
	if len(s) > 0 { ui.edit_paste(e, s) }
}

// ── painting ─────────────────────────────────────────────────────────────

host_status_word :: proc(s: app.Device_Status) -> string {
	switch s {
	case .pending:     return "pending"
	case .ok:          return "ok"
	case .timed_out:   return "timeout"
	case .unreachable: return "down"
	case .no_herdr:    return "no-herdr"
	case .auth_failed: return "auth"
	case .failed:      return "failed"
	}
	return "?"
}

// tui_host_line is the per-host verdict in the footer. A dead host has to be
// visible as *that host only*, which is the user-facing half of ISC-15.
//
// Built with tprintf rather than a byte buffer on purpose: returning
// `string(buf[:])` out of a scope that `defer delete(buf)`s the buffer hands the
// caller a string pointing at freed memory, and the footer then renders exactly
// that — garbage where "local ok 3" should be.
tui_host_line :: proc() -> string {
	out := ""
	for d in tui.table.devices {
		n := 0
		for r in tui.table.rows {
			if r.device == d.target { n += 1 }
		}
		name := d.target
		if d.label != "" { name = d.label }
		one := fmt.tprintf("{} {} {}", name, host_status_word(d.status), n)
		if out == "" {
			out = one
		} else {
			out = fmt.tprintf("{}  {}", out, one)
		}
	}
	return out
}

tui_state_text :: proc() -> string {
	if tui.notice != "" { return tui.notice }
	// ISC-19: a config problem has to be visible without being fatal. The
	// warning sits in the state slot (the first thing the eye lands on after
	// the header) and is superseded by any notice, so it never hides a verdict
	// the user just earned.
	warn := app.config_warning_text(tui.cfg)
	if warn != "" {
		return fmt.tprintf("\u26a0 {}  ·  {}  ·  {}", warn,
			app.state_label(tui.machine.state), tui_host_line())
	}
	return fmt.tprintf("{}  ·  {}", app.state_label(tui.machine.state), tui_host_line())
}

tui_paint :: proc() {
	cols, rows := termbox2.tb_width(), termbox2.tb_height()
	if cols != tui.painter.cols || rows != tui.painter.rows {
		ui.painter_resize(&tui.painter, cols, rows)
	}
	l := ui.frame_layout(cols, rows)

	f := &tui.frame
	f.cols = cols
	f.rows = rows
	f.title = "herdr-session"
	f.state = tui_state_text()
	f.keys = tui_keys()
	f.pal = &tui.pal

	ui.frame_open(&tui.painter, f)
	#partial switch tui.machine.state {
	case .mode_selection, .attach, .delete_session:
		session_body(l)
	case .name_local, .name_remote_named:
		edit_body(l)
	case .remote_server:
		if len(tui.remote_rows) == 0 { tui_build_remote_rows() }
		picker_body(l, tui.remote_rows[:])
	case .theme:
		if len(tui.theme_rows) == 0 { tui_build_theme_rows() }
		picker_body(l, tui.theme_rows[:])
	case .error:
		error_body(l)
	}
	ui.frame_close(&tui.painter, f)
	termbox2.tb_present()
	tui.dirty = false
	TUI_FRAMES += 1
}

TUI_FRAMES : int = 0

session_body :: proc(l: ui.Frame_Layout) {
	rows := tui_project_shown()
	tui_sync_text(&tui.sess.filter, app.text_of(&tui.machine.filter))
	tui.sess.sel = tui.machine.held
	body := l.main_rows - 2          // filter line + column header
	if body < 1 { body = 1 }
	ui.sessions_clamp(&tui.sess, rows, body)
	ui.sessions_paint(&tui.sess, rows, l.cols, body, &tui.pal)
}

edit_body :: proc(l: ui.Frame_Layout) {
	tui_sync_text(&tui.name_ed, app.text_of(&tui.machine.field))
	w := l.cols - 2
	if w < 8 { w = 8 }
	ui.edit_paint(&tui.name_ed, "hs.tui.name.edit", w, &tui.pal)
}

// picker_body paints the SAME ui.List for the remote picker and the theme
// picker. The filter line above it is the machine's text rendered through the
// editor, so the caret behaves identically to the name field.
picker_body :: proc(l: ui.Frame_Layout, rows: []ui.Picker_Row) {
	tui_sync_text(&tui.filter_ed, app.text_of(&tui.machine.filter))
	w := l.cols - 2
	if w < 8 { w = 8 }
	ui.edit_paint(&tui.filter_ed, "hs.tui.pick.filter", w, &tui.pal)

	// The machine already decided which rows pass the filter; the view needs those
	// indices so its scroll/selection arithmetic lines up. Note the binding:
	// `for x, i in collection` puts the ELEMENT in x and the POSITION in i — the
	// indices we want are the elements, not the positions.
	clear(&tui.list.shown)
	for idx, _ in tui.machine.shown { append(&tui.list.shown, idx) }
	tui.list.sel = tui.machine.sel

	visible := l.main_rows - 1
	if visible < 1 { visible = 1 }
	tui.list.scroll = ui.keep_visible(tui.list.scroll, i32(len(rows)), visible, i32(tui.list.sel))
	ui.list_paint(&tui.list, rows, l.cols, visible, &tui.pal)
}

error_body :: proc(l: ui.Frame_Layout) {
	msg := tui.machine.last_error
	if msg == "" { msg = "nothing to report" }
	w := l.cols - 8
	if w < 12 { w = 12 }
	tui.flt.title = "error"
	tui.flt.lines = []string{ui.ellipsize(msg, w)}
	tui.flt.dismiss = "enter/esc dismiss"
	ui.float_paint(&tui.flt, l.cols, &tui.pal)
}

tui_build_remote_rows :: proc() {
	clear(&tui.remote_rows)
	rows := ui.picker_rows(tui.remotes, pick_device_id, pick_device_label, pick_device_detail)
	for r in rows { append(&tui.remote_rows, r) }
}

tui_build_theme_rows :: proc() {
	clear(&tui.theme_rows)
	rows := ui.picker_rows(tui.themes, pick_theme_id, pick_theme_label, pick_theme_detail)
	for r in rows { append(&tui.theme_rows, r) }
}

// tui_keys is the footer's honest list of what works RIGHT NOW. Anything not
// listed does nothing, which is what makes the footer a contract instead of
// decoration.
tui_keys :: proc() -> []ui.Key_Hint {
	#partial switch tui.machine.state {
	case .mode_selection:
		return KEYS_MODE[:]
	case .attach:
		return KEYS_ATTACH[:]
	case .delete_session:
		return KEYS_DELETE[:]
	case .name_local, .name_remote_named:
		return KEYS_NAME[:]
	case .remote_server:
		return KEYS_PICK[:]
	case .theme:
		return KEYS_THEME[:]
	case .error:
		return KEYS_ERROR[:]
	}
	return KEYS_MODE[:]
}

KEYS_MODE : [8]ui.Key_Hint = {
	ui.Key_Hint{"enter", "new local session"},
	ui.Key_Hint{"n", "named local"},
	ui.Key_Hint{"r", "new remote"},
	ui.Key_Hint{"s", "named remote"},
	ui.Key_Hint{"a", "attach"},
	ui.Key_Hint{"d", "delete"},
	ui.Key_Hint{"t", "theme"},
	ui.Key_Hint{"esc", "quit"},
}

KEYS_ATTACH : [5]ui.Key_Hint = {
	ui.Key_Hint{"up/down", "select"},
	ui.Key_Hint{"type", "filter"},
	ui.Key_Hint{"enter", "attach (existing only)"},
	ui.Key_Hint{"esc", "back"},
	ui.Key_Hint{"ctrl-c", "quit"},
}

KEYS_DELETE : [5]ui.Key_Hint = {
	ui.Key_Hint{"up/down", "select"},
	ui.Key_Hint{"type", "filter"},
	ui.Key_Hint{"enter", "stop + delete"},
	ui.Key_Hint{"esc", "back"},
	ui.Key_Hint{"ctrl-c", "quit"},
}

KEYS_NAME : [4]ui.Key_Hint = {
	ui.Key_Hint{"type", "A-Z a-z 0-9 . _ -"},
	ui.Key_Hint{"enter", "create"},
	ui.Key_Hint{"esc", "back"},
	ui.Key_Hint{"ctrl-c", "quit"},
}

KEYS_PICK : [5]ui.Key_Hint = {
	ui.Key_Hint{"up/down", "select"},
	ui.Key_Hint{"type", "filter"},
	ui.Key_Hint{"enter", "choose"},
	ui.Key_Hint{"esc", "back"},
	ui.Key_Hint{"ctrl-c", "quit"},
}

KEYS_THEME : [5]ui.Key_Hint = {
	ui.Key_Hint{"up/down", "select"},
	ui.Key_Hint{"type", "filter"},
	ui.Key_Hint{"enter", "apply theme"},
	ui.Key_Hint{"esc", "back"},
	ui.Key_Hint{"ctrl-c", "quit"},
}

KEYS_ERROR : [3]ui.Key_Hint = {
	ui.Key_Hint{"enter", "dismiss"},
	ui.Key_Hint{"esc", "dismiss"},
	ui.Key_Hint{"ctrl-c", "quit"},
}

// ── the loop ─────────────────────────────────────────────────────────────

tui_loop :: proc() {
	for !tui.quitting {
		// 1. Drain the terminal completely before blocking, so termbox's own input
	    //    buffer can never park bytes behind a poll() on an fd that looks idle.
		draining := true
		for draining && !tui.quitting {
			got, lost := tui_take_event()
			if lost { tui_lost_terminal() }
			draining = got
		}
		if tui.quitting { break }

		// 2. Every list child, drained and settled and merged.
		tui_service_fetches()

		// 3. Paint anything the last two steps changed, BEFORE blocking, so the
	    //    screen is never a frame behind the state.
		if tui.dirty { tui_paint() }

		// 4. Sleep until something real happens.
		tui_wait()
	}
}

// tui_dump_trace writes the loop's own timeline AT EXIT. Mid-run file I/O changes
// the timing of the very race it is meant to reveal, so the facts are collected
// in the structs that already hold them and printed once the loop is over.
// tui_dump_trace is the loop's own record, written once at exit and only when
// HS_TUI_TRACE names a file. Mid-loop file I/O moves the timing of the very
// races the loop is made of, so the facts are collected in the structs that
// already hold them (and four counters) and printed once, off the hot path.
tui_dump_trace :: proc() {
	path := os.get_env_alloc("HS_TUI_TRACE", context.allocator)
	if path == "" { return }
	f, err := os.open(path, os.File_Flags{.Write, .Trunc, .Create})
	if err != nil { return }
	defer os.close(f)
	total := i64(time.duration_milliseconds(time.since(BOOT_T0)))
	os.write_string(f, fmt.tprintf("total={}ms frames={} polls={} hits={} idles={} errs={} remote_fans={} local_ms={} first_paint_ms={}\n",
		total, TUI_FRAMES, TUI_POLLS, TUI_POLL_HITS, TUI_POLL_IDLES, TUI_POLL_ERRS,
		TUI_REMOTE_FANS, TUI_LOCAL_MS, TUI_FIRST_PAINT_MS))
	for fetch in app.registry_all(&tui.reg) {
		settled_at := total - i64(time.duration_milliseconds(time.since(fetch.settled_at)))
		os.write_string(f, fmt.tprintf("fetch {} kind={} pid={} eof_out={} eof_err={} settled={} reaped={} status={} killed={} first_bytes=+{}ms settled_at=+{}ms exit={} out={}B err={}B\n",
			fetch.device, int(fetch.kind), int(fetch.pid), fetch.eof_out, fetch.eof_err,
			fetch.settled, fetch.reaped, int(fetch.status), fetch.killed,
			first_bytes_at_ms(fetch), settled_at,
			fetch.exit_code, len(fetch.out), len(fetch.err)))
	}
	for d in tui.table.devices {
		os.write_string(f, fmt.tprintf("device {} status={} rows={}\n", d.target, int(d.status),
			len(app.names_for_device(tui.table.rows[:], d.target))))
	}
}

// first_bytes_at_ms is when the child first spoke, measured from BOOT_T0 (the
// struct stores the instant, not the offset, so the offset is derived at dump
// time rather than at the moment of the read).
first_bytes_at_ms :: proc(f: ^app.Fetch) -> i64 {
	if !f.ever_bytes { return -1 }
	return i64(time.duration_milliseconds(time.since(BOOT_T0)) -
		time.duration_milliseconds(time.since(f.first_bytes_at)))
}

tui_lost_terminal :: proc() {
	// Do not repaint into a screen we may not own, and do not exit 0 as if the
	// user asked to quit.
	tui.quitting = true
	TUI_LOST_TERMINAL = true
}

TUI_LOST_TERMINAL : bool = false
TUI_POLLS      : int = 0
TUI_POLL_HITS  : int = 0
TUI_POLL_IDLES : int = 0
TUI_POLL_ERRS  : int = 0

// tui_boot builds the world, paints the local rows, THEN starts the remotes.
// The order is the requirement: ISC-6 says the first frame already shows the
// local list while the fan-out is still in flight, because the local list costs
// ~3 ms and a remote host costs ~150 ms.
tui_boot :: proc() -> bool {
	BOOT_T0 = time.now()
	TUI_ACTIVE = true

	// ── T6.1/T6.2: read the config BEFORE taking the terminal ──────────
	//
	// Order matters twice over. (1) If the config is broken we still want the
	// warning on screen, and loading first means a config bug cannot manifest as
	// a half-initialised terminal. (2) config_load never fails, so there is no
	// reason to defer it — and doing it first means the very first frame is
	// already painted in the configured theme rather than recolouring under the
	// user's eyes.
	tui.cfg = app.config_load()
	if tui.cfg.path != "" {
		// Save target even when the file did not exist yet (first run: the
	// picker still has somewhere to write, and the notice names it).
		_ = tui.cfg.path
	}

	// The palette list is static, so it is built once and handed to the machine
	// as the picker's source of truth. This is also what makes the picker PRE-
	// SELECT the applied theme: `enter_state(.theme)` places the cursor on
	// `a.theme`, so the machine has to know the current theme for that to mean
	// anything.
	tui.themes, _ = app.theme_names(context.allocator)
	tui.theme = app.theme_named_or_default(tui.cfg.theme)
	tui.theme_now = tui.theme.name
	tui.pal = ui.palette_of(tui.theme)
	tui.machine.themes = tui.themes
	tui.machine.theme = tui.theme.name

	// D2: the cleanup policy is config-driven now, with the same safe default.
	app.set_cleanup_policy(app.cleanup_policy_from_name(tui.cfg.cleanup_policy))

	ui.sessions_init(&tui.sess)
	ui.edit_init(&tui.name_ed)
	ui.edit_init(&tui.filter_ed)
	ui.list_init(&tui.list)

	if !tui_is_a_tty() {
		tui_die("needs a real terminal: stdin and stdout must both be a tty. "+
			"Run it from an interactive shell (or `script -q -c 'nix run .' /dev/null`).")
		return false
	}

	if rv := termbox2.tb_init(); rv != termbox2.TB_OK {
		tui_die(fmt.tprintf("could not take over the terminal: {}", termbox2.tb_strerror(rv)))
		return false
	}
	termbox2.tb_set_output_mode(termbox2.OUTPUT_TRUECOLOR)
	termbox2.tb_hide_cursor()

	if !ui.painter_start(&tui.painter, termbox2.tb_width(), termbox2.tb_height()) {
		termbox2.tb_shutdown()
		tui_die("could not start the renderer")
		return false
	}

	// (a) discovery is LOCAL (one herdr call, no ssh) and must precede the
	//     fan-out because it decides which hosts to fan out to.
	probe_t0 := time.now()
	disc := tui_discover()
	TUI_DISCOVER_MS = i64(time.duration_milliseconds(time.since(probe_t0)))
	tui.remotes = disc.remotes
	app.table_reset_devices(&tui.table, app.devices_for_table(disc))

	// (b) THE local list, inline and blocking: ~3 ms, and it is the only thing
	//     the first frame waits on.
	local_t0 := time.now()
	app.local_snapshot(&tui.table, app.LOCAL_FETCH_DEADLINE)
	tui_sync_model()
	TUI_LOCAL_MS = i64(time.duration_milliseconds(time.since(local_t0)))

	// (c) FIRST PAINT — local rows are on screen before a single ssh exists.
	tui_paint()
	TUI_FIRST_PAINT_MS = i64(time.duration_milliseconds(time.since(BOOT_T0)))

	// (d) NOW the remotes start. Nothing above blocks on them.
	tui_fan_out()
	TUI_REMOTE_FANS = i64(app.registry_pending(&tui.reg))
	return true
}

TUI_DISCOVER_MS     : i64 = 0
TUI_LOCAL_MS        : i64 = 0
TUI_FIRST_PAINT_MS  : i64 = 0
TUI_REMOTE_FANS     : i64 = 0
BOOT_T0             : time.Time

// tui_run is the T5.5 entry point: boot, loop, restore, report nothing (the
// TUI is not a smoke case — it owns the screen, not stdout).
tui_run :: proc() -> bool {
	if !tui_boot() { return false }
	tui_loop()

	// Every exit path ends here: retire the children, then hand the terminal back.
	for f in app.registry_all(&tui.reg) {
		if app.fetch_pending(f) {
			app.fetch_kill(f)
			app.kill_and_reap(f)
		}
	}
	tui_dump_trace()
	app.registry_free(&tui.reg)
	ui.painter_stop(&tui.painter)
	app.table_free(&tui.table)
	delete(tui.remote_rows)
	delete(tui.theme_rows)
	delete(tui.shown_rows)
	delete(tui.fds)
	app.app_free(&tui.machine)
	termbox2.tb_shutdown()

	if TUI_LOST_TERMINAL {
		fmt.eprintln("herdr-session: lost the terminal; stopped.")
		return false
	}
	return true
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
  theme-set        T6.2 the compiled-in palette table: count, default, slots
  theme-resolve    T6.2 exact / alias / unknown-name resolution + the warning
  config-parse     T6.1 every parse mode: missing, corrupt, wrong type, unknown theme
  config-save      T6.1 the merge rule — unknown hand-added keys survive a save
  config-live      T6.1 the real loader against real files in a temp XDG_CONFIG_HOME
  colour-wire      T6.2 0..255 channels + TB_HI_BLACK through the real renderer
  clip                        scissor containment
  clay-error                  duplicate id survives the C frame
  layout-dump                 the raw render command stream
  ui-frame        T5.1 spine: border, section rules, title, footer geometry
  ui-sessions     T5.2 four fixed columns, live filter, selection, ordering
  ui-shrink       T5.2 real resize re-clamps the selection
  ui-edit         T5.3 caret is a display column; CJK/emoji typed + pasted
  ui-list         T5.3 one filtered list for both pickers
  ui-float        T5.3 floating error pane, Enter/Esc dismiss
  state-machine   T5.4 the 7-state machine: full (state x key) grid + every rule
  state-offline   T5.4 the same battery with no env and no child processes
  tui             T5.5 the real application: poll loop + executor + handoff
                    (this is what a bare "nix run ." runs)
  guard-attach <device> <name>
                  T5.5 evidence probe: run the REAL attach guard against a name
                    that is not in the model; show nothing was spawned
  guard-delete <device> <name>
                  T5.5 evidence probe: the same for the delete pre-check`)
}

// ---------------------------------------------------------------------------
// T5.5 evidence probes
// ---------------------------------------------------------------------------
// These run the SAME guards the live TUI runs (app.attach_guard / app.delete_guard
// over a model loaded from the real herdr), with no terminal involved. That is
// what the guards being pure functions of the model buys: the refusal the app
// cannot bypass is the refusal under test, not a test-local imitation of it.

guard_probe_rows :: proc() -> []app.Session {
	c := app.run_capture(app.list_argv(), app.CAPTURE_TIMEOUT)
	rows, ok := app.parse_session_list(c.out, app.DEVICE_LOCAL, app.DEVICE_LOCAL)
	if !ok { return nil }
	return rows
}

case_guard_attach :: proc(device: string, name: string) -> bool {
	rows := guard_probe_rows()
	say(fmt.tprintf("guard attach — device={} name='{}' (model: {} local row(s))",
		device, name, len(rows)))
	g := app.attach_guard(rows, device, name)
	check("attach_guard refused", !g.ok, g.reason)
	check("…with a reason a human can act on", len(g.reason) > 0, fmt.tprintf("\"{}\"", g.reason))
	// A guard that let something through would have left a child behind. ECHILD
	// (errno 10) from waitpid(WNOHANG) is the proof that we spawned nothing —
	// the boolean alone only proves what the function said about itself.
	st: c.int = 0
	kid := posix.waitpid(-1, &st, {.NOHANG})
	check("…and spawned no child at all", kid == -1 && int(posix.errno()) == 10,
		fmt.tprintf("waitpid(-1,WNOHANG) = {} (errno={})", int(kid), int(posix.errno())))
	return true
}

case_guard_delete :: proc(device: string, name: string) -> bool {
	rows := guard_probe_rows()
	say(fmt.tprintf("guard delete — device={} name='{}' (model: {} local row(s))",
		device, name, len(rows)))
	g := app.delete_guard(rows, device, name)
	check("delete_guard refused", !g.ok, g.reason)
	check("…with a reason that says nothing was destroyed", len(g.reason) > 0,
		fmt.tprintf("\"{}\"", g.reason))
	st: c.int = 0
	kid := posix.waitpid(-1, &st, {.NOHANG})
	check("…and spawned no child at all", kid == -1 && int(posix.errno()) == 10,
		fmt.tprintf("waitpid(-1,WNOHANG) = {} (errno={})", int(kid), int(posix.errno())))
	return true
}

// TUI_ACTIVE switches the handoff's forced-repaint hook between the Phase 1
// smoke box and the real TUI frame. There is exactly one hook, so a handoff can
// never repaint into the wrong renderer.
TUI_ACTIVE : bool = false

tui_repaint_hook :: proc() {
	if TUI_ACTIVE {
		tui_paint()
	} else {
		force_repaint()
	}
}

main :: proc() {
	terminal.set_full_repaint(tui_repaint_hook)
	terminal.install_terminal_restore_handlers()

	args := os.args
	// A bare `nix run .` is the APPLICATION, not the smoke driver: it runs the
	// real TUI. Every smoke case stays reachable by name, so all of dev/*-smoke.sh
	// keeps working untouched. `tui` itself refuses to run without a tty and says
	// so cleanly — see tui_is_a_tty.
	name := "tui"
	if len(args) > 1 { name = args[1] }
	ok := false

	switch name {
	case "tui": ok = tui_run()
	case "guard-attach":
		if len(args) < 4 { usage(); os.exit(2) }
		ok = case_guard_attach(args[2], args[3])
	case "guard-delete":
		if len(args) < 4 { usage(); os.exit(2) }
		ok = case_guard_delete(args[2], args[3])
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
	case "theme-set":     ok = case_theme_set()
	case "theme-resolve": ok = case_theme_resolve()
	case "config-parse":  ok = case_config_parse()
	case "config-save":   ok = case_config_save()
	case "config-live":   ok = case_config_live()
	case "colour-wire":   ok = case_colour_wire()
	case "clip":       ok = case_clip()
	case "clay-error": ok = case_clay_error()
	case "layout-dump": ok = case_layout_dump()
	case "ui-frame":    ok = case_ui_frame()
	case "ui-sessions": ok = case_ui_sessions()
	case "ui-shrink":   ok = case_ui_shrink()
	case "ui-edit":     ok = case_ui_edit()
	case "ui-list":     ok = case_ui_list()
	case "ui-float":    ok = case_ui_float()
	case "state-machine": ok = case_state_machine()
	case "state-offline": ok = case_state_offline()
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
