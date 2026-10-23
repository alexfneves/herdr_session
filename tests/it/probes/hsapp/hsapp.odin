package hsapp

// ─────────────────────────────────────────────────────────────────────────────
// hsapp.odin — the TEST-OWNED app-role and child-probe roles for T11.
//
// Why this exists: `src/main.odin` currently plays the app role for
// dev/handoff-smoke.sh (its `probe` / `double` / `handoff` / `child` /
// `sig-term` cases plus the smoke painter), and two of that suite's child probes
// are SHELLED OUT HEREDOCS (`env_probe.sh`, `sig_probe.py`) written to disk at
// runtime by the script itself. T16 deletes the main dispatcher. Anything that
// only lived in those heredocs would then have no implementation left, and the
// parity floor would be counting assertions nothing produces. This file is where
// those probe behaviours actually live, compiled.
//
// HOW IT RUNS — one binary, many roles, selected by $HS_ROLE:
//
//   The role code lives in a LIBRARY package so it can be entered from more than
//   one place:
//     * this package's own `main` (tests/it/probes/handoff_app) for hand runs, and
//     * the test binary itself, through the `@(init)` dispatcher in
//       tests/it/handoff_roles_init.odin.
//
//   The second one is what removes path discovery from the equation entirely:
//   the it test binary re-execs ITSELF as the app, and the app re-execs itself
//   as the handoff's child probe. `$BIN` in the run environment stays pointed at
//   the product, which the harness needs for its own purposes; nothing has to
//   know where a probe binary was installed.
//
// Contract this file holds:
//   * It registers ITS OWN repaint hook (`termhandoff.set_full_repaint`) with a
//     test-owned FRAMES_PAINTED counter, so "the handoff forced a repaint" is
//     asserted against something the test can see and did not inherit from main.
//   * It never calls `tui_paint` and never sets `TUI_ACTIVE`.
//   * It makes NO counted assertions. Assertions belong to the parent test
//     process; a forked or exec'd child's counters never reach the ledger
//     (DECISIONS "Finding 2"). Everything here REPORTS and exits.
//
// ROLES (selected by $HS_ROLE) and the old check site each one feeds:
//
//   abi          dev/handoff-smoke.sh:135  "$BIN probe"      (01-probe.log)
//   double       :141                                        (02-double.log)
//   handoff      :155,158                                    (03.*)
//   child        :165 (exit code)  :175 (env scrub)  :196,199 (04/05/06.*)
//   sig-term     :224,250                                    (07-$SIG.*)
//   env-probe    the `env_probe.sh` HEREDOC at :37-45  -> ported here
//   sig-probe    the `sig_probe.py` HEREDOC at :47-67  -> ported here
//   exit7        the `sh -c 'exit 7'` of case 4, as a compiled child
//
// The two heredoc ports keep the shell/python probe's OUTPUT LINES, not just its
// meaning: what the child prints to the tty it inherited is the evidence, and a
// port that renames the lines makes the old transcript uncomparable.
// ─────────────────────────────────────────────────────────────────────────────

import termbox2 "../../../../vendor/termbox2-odin"
import clay "../../../../clay-odin"
import termhandoff "../../../../src/terminal"

import ev "../evidence"

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

ROLE_ENV :: "HS_ROLE"

// FRAMES_PAINTED counts calls to OUR repaint hook. It starts at zero and is
// only ever bumped by hs_repaint_hook, so a nonzero value means the handoff
// itself drove a full repaint after re-acquiring the terminal (plan step 6).
FRAMES_PAINTED : int = 0

FG : termbox2.Attr = termbox2.TB_GREEN
BG : termbox2.Attr = termbox2.TB_DEFAULT

// ─────────────────────────────────────────────────────────────────────────────
// Painting — deliberately minimal. This is a frame, not a UI.
// ─────────────────────────────────────────────────────────────────────────────

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
	for x in x0 + 1 ..< x1 { termbox2.tb_set_cell(x, y0, u32('─'), FG, BG) }
	for x in x0 + 1 ..< x1 { termbox2.tb_set_cell(x, y1, u32('─'), FG, BG) }
	for y in y0 + 1 ..< y1 { termbox2.tb_set_cell(x0, y, u32('│'), FG, BG) }
	for y in y0 + 1 ..< y1 { termbox2.tb_set_cell(x1, y, u32('│'), FG, BG) }
}

hs_paint :: proc(title: string) {
	termbox2.tb_clear()
	cols, rows := termbox2.tb_width(), termbox2.tb_height()
	draw_box(0, 0, cols - 1, rows - 1)
	draw_text(2, 1, title)
	draw_text(2, 3, fmt.tprintf("{}x{} alt screen · test-owned handoff frame", cols, rows))
	termbox2.tb_present()
}

// hs_repaint_hook is what the handoff calls after it gets the terminal back.
hs_repaint_hook :: proc() {
	FRAMES_PAINTED += 1
	hs_paint(fmt.tprintf("frame {} — FORCED full repaint after handoff", FRAMES_PAINTED))
}

// ─────────────────────────────────────────────────────────────────────────────
// Terminal ownership
// ─────────────────────────────────────────────────────────────────────────────

term_enter :: proc() -> bool {
	rv := termbox2.tb_init()
	ev.report("tb_init", fmt.tprintf("{}", rv))
	if rv != termbox2.TB_OK {
		ev.say(fmt.tprintf("hsapp: tb_init -> {} ({})\n", rv, termbox2.tb_strerror(rv)))
		return false
	}
	termbox2.tb_set_output_mode(termbox2.OUTPUT_TRUECOLOR)
	termbox2.tb_hide_cursor()
	return true
}

term_leave :: proc() {
	termbox2.tb_shutdown()
}

// ─────────────────────────────────────────────────────────────────────────────
// /proc self-observation. Same kernel answers the heredoc probes read.
// ─────────────────────────────────────────────────────────────────────────────

// sigblk_hex_of reads SigBlk from /proc/<pid>/status as the hex string the
// kernel wrote there. `who` is "self" or a decimal pid.
sig_field_of :: proc(who: string, field: string) -> string {
	path := "/proc/self/status"
	if who != "self" { path = fmt.tprintf("/proc/{}/status", who) }
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return "" }
	defer delete(data)
	lines, _ := strings.split_lines(string(data[:]))
	for line in lines {
		if !strings.has_prefix(line, field) { continue }
		f, _ := strings.fields(line)
		if len(f) < 2 { return "" }
		// CLONE, do not return the slice. Odin's split_lines/fields return VIEWS
		// into `data`, and the `defer delete(data)` above runs at THIS proc's
		// exit — i.e. before the caller ever reads what we returned. Left as a
		// view it is a use-after-free that reads fine early in a process's life
		// and comes back as `\t000000000000000` later. That was measured here,
		// not theorised.
		return strings.clone(f[1], context.allocator)
	}
	return ""
}

sig_field_dec :: proc(who: string, field: string) -> i64 {
	v, ok := hex_to_i64(sig_field_of(who, field))
	if !ok { return -1 }
	return v
}

sigblk_hex_of :: proc(who: string) -> string {
	return sig_field_of(who, "SigBlk:")
}

// hex_to_i64 parses the kernel's SigBlk field. Reports ok=false rather than
// silently yielding 0: a probe that could not read its mask must not be able to
// "pass" a must-be-zero assertion.
hex_to_i64 :: proc(s: string) -> (i64, bool) {
	n : i64 = 0
	digits := 0
	for i := 0; i < len(s); i += 1 {
		b := s[i]
		v := 0
		switch {
		case b >= '0' && b <= '9': v = int(b - '0')
		case b >= 'a' && b <= 'f': v = int(b - 'a') + 10
		case b >= 'A' && b <= 'F': v = int(b - 'A') + 10
		case:
			return 0, false
		}
		n = n * 16 + i64(v)
		digits += 1
	}
	if digits == 0 { return 0, false }
	return n, true
}

report_sigblk :: proc(prefix: string, who: string) {
	hex := sigblk_hex_of(who)
	ev.report(fmt.tprintf("{}_sigblk_hex", prefix), hex)
	v, ok := hex_to_i64(hex)
	ev.report(fmt.tprintf("{}_sigblk", prefix), fmt.tprintf("{}", v))
	ev.report(fmt.tprintf("{}_sigblk_readable", prefix), ifok(ok))
	// The IGNORE set is reported alongside the MASK because the two are not the
	// same question and the difference decided a real result here: a signal
	// that is BLOCKED stays pending and is delivered when the mask is lifted,
	// but a signal that is IGNORED is dropped at send time and never arrives.
	ev.report(fmt.tprintf("{}_sigign", prefix), sig_field_of(who, "SigIgn:"))
	ev.report(fmt.tprintf("{}_sigign_dec", prefix), fmt.tprintf("{}", sig_field_dec(who, "SigIgn:")))
}

ifok :: proc(ok: bool) -> string {
	if ok { return "yes" }
	return "no"
}

// report_tty_raw answers, from the fd the app itself holds, whether the line
// discipline is in the raw mode tb_init put it in. The suite needs this as an
// ANTI-VACUITY fact: "termios before == after" is equally true of a process
// that never took the terminal, so a round-trip assertion without a "was it
// ever raw?" companion proves nothing.
//
// It is reported BY THE APP rather than sampled by the harness because the
// window where it is true can be microseconds: for a child that exits
// immediately (`exit 7`), the app re-acquires the tty, repaints and leaves
// before a harness poll could ever see it. Measured that way and it produced a
// false red. The app's own observation of its own fd has no such race.
report_tty_raw :: proc(tag: string) {
	t : posix.termios = {}
	if posix.tcgetattr(posix.FD(1), &t) != {} {
		ev.report(fmt.tprintf("{}_tty_raw", tag), "unreadable")
		return
	}
	echo_off := (t.c_lflag & posix.CLocal_Flags{.ECHO}) == {}
	icanon_off := (t.c_lflag & posix.CLocal_Flags{.ICANON}) == {}
	ev.report(fmt.tprintf("{}_tty_raw", tag), ifok(echo_off && icanon_off))
	ev.report(fmt.tprintf("{}_tty_lflag", tag), fmt.tprintf("{}", t.c_lflag))
}

report_self :: proc(tag: string) {
	ev.report(fmt.tprintf("{}_pid", tag), fmt.tprintf("{}", i64(posix.getpid())))
	ev.report(fmt.tprintf("{}_pgid", tag), fmt.tprintf("{}", i64(posix.getpgid(0))))
	ev.report(fmt.tprintf("{}_sid", tag), fmt.tprintf("{}", i64(posix.getsid(0))))
	report_sigblk(tag, "self")
}

// ─────────────────────────────────────────────────────────────────────────────
// ROLE: abi — dev/handoff-smoke.sh:135 ("$BIN probe", 01-probe.log)
//
// The foreign ABI is not garbled: tb_wcwidth is a real call into the archive,
// the width/truecolor queries report the TB_OPT_ATTR_W the archive was actually
// compiled with, and the Event struct has the layout our bindings assume.
//
// Reported as facts rather than checked here for the same reason every other role
// reports: the ledger lives in the test process.
// ─────────────────────────────────────────────────────────────────────────────

role_abi :: proc() -> i32 {
	ev.report("abi_wcwidth_A", fmt.tprintf("{}", termbox2.tb_wcwidth(u32('A'))))
	ev.report("abi_wcwidth_CJK", fmt.tprintf("{}", termbox2.tb_wcwidth(0x4E00)))
	ev.report("abi_attr_width", fmt.tprintf("{}", termbox2.tb_attr_width()))
	ev.report("abi_has_truecolor", fmt.tprintf("{}", termbox2.tb_has_truecolor()))
	ev.report("abi_clay_min_memory", fmt.tprintf("{}", clay.MinMemorySize()))
	ev.report("abi_event_size", fmt.tprintf("{}", size_of(termbox2.Event)))
	// COMPLETION SENTINEL. A harness that waits on the first fact it wants and
	// then reads the later ones off the same snapshot races the writer. Every
	// role ends with one key that means "everything else for this role is
	// already in the file", and the suite waits on THAT.
	ev.report("abi_role_complete", "1")
	ev.say("HSABI role done\n")
	return 0
}

// ─────────────────────────────────────────────────────────────────────────────
// ROLE: double — :141. Two tb_init/tb_shutdown round-trips + the guards.
// A second init without a shutdown must report TB_ERR_INIT_ALREADY and a
// shutdown after a shutdown TB_ERR_NOT_INIT: the state machine must not
// double-free or lie.
// ─────────────────────────────────────────────────────────────────────────────

role_double :: proc() -> i32 {
	r1 := termbox2.tb_init()
	r2 := termbox2.tb_init()
	r3 := termbox2.tb_shutdown()
	r4 := termbox2.tb_shutdown()
	r5 := termbox2.tb_init()
	r6 := termbox2.tb_shutdown()
	ev.report("double_r1", fmt.tprintf("{}", r1))
	ev.report("double_r2", fmt.tprintf("{}", r2))
	ev.report("double_r3", fmt.tprintf("{}", r3))
	ev.report("double_r4", fmt.tprintf("{}", r4))
	ev.report("double_r5", fmt.tprintf("{}", r5))
	ev.report("double_r6", fmt.tprintf("{}", r6))
	ev.report("double_role_complete", "1")
	ev.say("HSDOUBLE role done\n")
	return 0
}

// ─────────────────────────────────────────────────────────────────────────────
// ROLE: handoff — :155/:158. Paint, hand the terminal to `sleep N`, take it
// back, then prove we can still paint AND read input.
//
// The post-handoff keypress is only meaningful AFTER the child is gone and the
// terminal is ours again, which is why the app announces `ready_for_key` and the
// harness sends the key when it sees that key land in the evidence file.
// ─────────────────────────────────────────────────────────────────────────────

role_handoff :: proc(secs: string) -> i32 {
	if !term_enter() { return 2 }
	hs_paint("frame 1 — before the handoff")
	report_self("app")
	ev.report("app_frames_before", fmt.tprintf("{}", FRAMES_PAINTED))

	h := termhandoff.handoff_run({"sleep", secs}, home_dir())
	ev.report("handoff_exit", fmt.tprintf("{}", h.exit))
	ev.report("handoff_killed_by", fmt.tprintf("{}", h.killed_by))
	ev.report("handoff_ok", fmt.tprintf("{}", h.ok))
	ev.report("handoff_err", fmt.tprintf("{}", h.err))
	ev.report("frames", fmt.tprintf("{}", FRAMES_PAINTED))
	report_tty_raw("app_after")

	ev.report("ready_for_key", "1")
	ev.say("hsapp: ready for the post-handoff keypress\n")
	k := wait_key(24)
	ev.report("got_key", fmt.tprintf("{}", k.got))
	ev.report("key", fmt.tprintf("{}", k.key))
	ev.report("key_ch", fmt.tprintf("{}", k.ch))
	ev.report("resize_before_key", fmt.tprintf("{}", k.resize_before))
	ev.report("frames", fmt.tprintf("{}", FRAMES_PAINTED))
	ev.report("handoff_role_complete", "1")
	term_leave()
	ev.say("HSHANDOFF role done\n")
	return 0
}

Key_Result :: struct {
	got           : bool,
	key           : i32,
	ch            : i32,
	resize_before : bool,
}

// wait_key reads until one key event arrives. Resizes are skipped, not counted:
// the harness may resize the pty on its own and that is not the keypress.
wait_key :: proc(attempts: int) -> Key_Result {
	r := Key_Result{}
	evt := termbox2.Event{}
	for _ in 0 ..< attempts {
		// tb_peek_event returns a TB_* STATUS code, not the event kind; the
		// kind lives in evt.typ. A timeout is TB_ERR_NO_EVENT, not "no key".
		rv := termbox2.tb_peek_event(&evt, 500)
		if rv == termbox2.TB_ERR_NO_EVENT || rv == termbox2.TB_ERR_POLL { continue }
		if rv != termbox2.TB_OK {
			ev.report("peek_err", fmt.tprintf("{} ({})", rv, termbox2.tb_strerror(rv)))
			break
		}
		if evt.typ == termbox2.EVENT_KEY {
			r.got = true
			r.key = i32(evt.key)
			r.ch = i32(evt.ch)
			return r
		} else if evt.typ == termbox2.EVENT_RESIZE {
			r.resize_before = true
			continue
		}
	}
	return r
}

// ─────────────────────────────────────────────────────────────────────────────
// ROLE: child — :165 (exit code), :175 (env scrub/pgroup/cwd),
//                :196/:199 (SIGINT while the child owns the tty).
//
// The generic handover: install a deliberately LEAKY HERDR_* environment, take
// the terminal, hand it to another role of this same binary, take it back.
//
// The leak arrives as $HS_LEAK and is installed HERE. It cannot arrive as real
// HERDR_* variables because the pty harness scrubs the HERDR_* namespace from
// every spawn (it must, or it could not tell its own namespace from the
// product's). That round-trip is exactly the situation under test: an app whose
// own environment is full of HERDR_* must hand a clean one over.
//
// $HS_CHILD_ROLE names the role the child runs as — `env-probe`, `sig-probe` or
// `exit7`. $HS_CHILD_CWD is the cwd we hand over explicitly: a session herdr
// creates takes the spawner's cwd as its identity_cwd, so an accidental inherit
// here would be a permanent property and the probe prints `pwd` to catch it.
// ─────────────────────────────────────────────────────────────────────────────

role_child :: proc() -> i32 {
	// HS_IGN_INT_QUIT mirrors the disposition the OLD suite's app ran with.
	// It is not decoration and it is not papering over anything: it is what
	// `script -q -e -c "stty …; $BIN …"` gave the product. A non-interactive
	// shell that has to FORK (any -c string with more than one command) sets
	// SIGINT and SIGQUIT to SIG_IGN in the child, so every handoff case in
	// dev/handoff-smoke.sh ran with Ctrl-C ignored in the app. That is why
	// its "SIGINT during handoff" case exited 0. Measured both ways:
	//   script launcher   -> app SigIgn=0x6, app survives, exit 0
	//   direct spawn      -> app SigIgn=0x0, app dies 130 once the handoff
	//                       lifts its own block (the pending signal is
	//                       delivered then, and the default disposition is
	//                       "terminate")
	// The suite covers BOTH. See handoff_sigint_* in tests/it/handoff_test.odin.
	if os.get_env_alloc("HS_IGN_INT_QUIT", context.allocator) == "1" {
		posix.signal(posix.Signal.SIGINT, auto_cast posix.SIG_IGN)
		posix.signal(posix.Signal.SIGQUIT, auto_cast posix.SIG_IGN)
	}
	child_role := os.get_env_alloc("HS_CHILD_ROLE", context.allocator)
	if len(child_role) == 0 {
		ev.report("fatal", "child role needs HS_CHILD_ROLE")
		return 2
	}
	cwd := os.get_env_alloc("HS_CHILD_CWD", context.allocator)
	if len(cwd) == 0 { cwd = home_dir() }

	leaked := install_leaky_env()
	ev.report("app_herdr_count", fmt.tprintf("{}", leaked))

	self := self_exe_path()
	if len(self) == 0 {
		ev.report("fatal", "cannot resolve our own executable path")
		return 2
	}

	if !term_enter() { return 2 }
	hs_paint("frame 1 — handing the terminal over")
	report_self("app")
	// The mask BEFORE we hand over: the additive "the app is not permanently
	// immune to Ctrl-C afterwards" assertion compares the post-handoff mask
	// against this.
	report_sigblk("app_before", "self")

	// The child must start with OUR role name replaced by ITS role name. The
	// handoff passes our environment (scrubbed of HERDR_*) to the child at
	// fork time, so the swap has to happen before the fork and be undone
	// after it — otherwise this very process would re-dispatch as the probe on
	// its next startup.
	prev_role, had_role := lookup_role()
	set_role(child_role)

	h := termhandoff.handoff_run({self}, cwd)

	if had_role {
		set_role(prev_role)
	} else {
		os.unset_env(ROLE_ENV)
	}

	ev.report("child_role", child_role)
	ev.report("child_argv0", self)
	ev.report("child_cwd", cwd)
	ev.report("handoff_exit", fmt.tprintf("{}", h.exit))
	ev.report("handoff_killed_by", fmt.tprintf("{}", h.killed_by))
	ev.report("handoff_ok", fmt.tprintf("{}", h.ok))
	ev.report("handoff_err", fmt.tprintf("{}", h.err))
	ev.report("frames", fmt.tprintf("{}", FRAMES_PAINTED))
	report_tty_raw("app_after")
	// `after` is read AFTER handoff_run returned, i.e. after its
	// restore_signals(). If the restore were missing, the app would go on
	// blocking SIGINT|SIGQUIT forever and a user's Ctrl-C would be dead.
	report_sigblk("app_after", "self")
	ev.report("app_alive_after_handoff", "1")
	ev.report("child_role_complete", "1")
	term_leave()
	ev.say("HSCHILD role done\n")
	return 0
}

// ─────────────────────────────────────────────────────────────────────────────
// ROLE: sig-term — :224/:250. Park in the alt screen so the harness can signal
// us. NOTHING but our own handler puts the terminal back.
//
// We install the PRODUCT's restore handler (termhandoff.install_terminal_restore_
// handlers) rather than a local copy, so the suite proves the product's restore
// path and not a look-alike that only this test exercises.
// ─────────────────────────────────────────────────────────────────────────────

role_sig_term :: proc() -> i32 {
	if !term_enter() { return 2 }
	hs_paint("frame 1 — waiting for a signal in the alt screen")
	report_self("app")
	termhandoff.install_terminal_restore_handlers()
	ev.report("parked", "1")
	ev.say("hsapp: parked in the alt screen, awaiting a signal\n")
	for _ in 0 ..< 80 {
		e := termbox2.Event{}
		termbox2.tb_peek_event(&e, 500)
	}
	// Reaching here means no signal arrived in 40 s: the harness did not run.
	ev.report("no_signal", "1")
	term_leave()
	return 3
}

// ─────────────────────────────────────────────────────────────────────────────
// ROLE: env-probe — PORTED FROM THE HEREDOC at dev/handoff-smoke.sh:37-45.
//
// The original, verbatim, so the port is auditable line by line:
//
//   #!/bin/sh
//   echo "CHILD pid=$$ pgid=$(awk '{print $5}' /proc/self/stat) \
//        sid=$(awk '{print $6}' /proc/self/stat) pwd=$(pwd)"
//   echo "CHILD HERDR_VARS=$(env | grep -c '^HERDR_')"
//   echo "CHILD HERDR_LINES:[$(env | grep '^HERDR_' | tr '\n' ' ')]"
//   echo "CHILD TERM=${TERM:-MISSING} COLORTERM=${COLORTERM:-MISSING}"
//   echo "CHILD stdin=$(tty 2>/dev/null || echo not-a-tty)"
//
// Field-for-field: the awk column picks are the same kernel answers that
// getpgid(0)/getsid(0) give directly (field 5 of /proc/self/stat IS the
// process group, field 6 IS the session id), `env | grep '^HERDR_'` is a
// prefix walk over our own environment, and `tty` is ttyname(0).
//
// Runs AS the handoff's child with the stdio and environment the handoff
// actually handed over, printing straight to the INHERITED tty: what it says is
// ground truth for what the child RECEIVED, not for what the spawner intended.
// ─────────────────────────────────────────────────────────────────────────────

role_env_probe :: proc() -> i32 {
	pid := i64(posix.getpid())
	pgid := i64(posix.getpgid(0))
	sid := i64(posix.getsid(0))
	cwd := current_dir()
	herdr_names, herdr_all := collect_herdr()
	term := env_or_missing("TERM")
	colorterm := env_or_missing("COLORTERM")
	stdin_tty := tty_of(0)

	// The same five lines, on the tty the child inherited.
	ev.say(fmt.tprintf("CHILD pid={} pgid={} sid={} pwd={}\n", pid, pgid, sid, cwd))
	ev.say(fmt.tprintf("CHILD HERDR_VARS={}\n", len(herdr_names)))
	ev.say(fmt.tprintf("CHILD HERDR_LINES:[{}]\n", herdr_all))
	ev.say(fmt.tprintf("CHILD TERM={} COLORTERM={}\n", term, colorterm))
	ev.say(fmt.tprintf("CHILD stdin={}\n", stdin_tty))

	// The same facts on the channel the test actually parses.
	ev.report("child_pid", fmt.tprintf("{}", pid))
	ev.report("child_pgid", fmt.tprintf("{}", pgid))
	ev.report("child_sid", fmt.tprintf("{}", sid))
	ev.report("child_pwd", cwd)
	ev.report("child_herdr_count", fmt.tprintf("{}", len(herdr_names)))
	ev.report("child_herdr_names", herdr_names)
	ev.report("child_herdr_blob", herdr_all)
	ev.report("child_term", term)
	ev.report("child_colorterm", colorterm)
	ev.report("child_stdin_tty", stdin_tty)
	// `tty` answers with a NAME; tcgetpgrp answers who is IN FRONT of it, the
	// property the handoff depends on — a setsid() here would pull the child out
	// of the foreground group and it would receive no input at all.
	fg := i64(posix.tcgetpgrp(0))
	ev.report("child_tty_fg_pgid", fmt.tprintf("{}", fg))
	ev.report("child_fg_matches_own_pgid", fmt.tprintf("{}", fg == pgid))
	ev.report("env_probe_done", "1")
	// Exit 0 unconditionally: the probe's job is to report. The original never
	// failed, and a nonzero exit here would collide with the exit-code
	// assertions and make a reporting problem look like a handoff problem.
	return 0
}

// ─────────────────────────────────────────────────────────────────────────────
// ROLE: sig-probe — PORTED FROM THE PYTHON HEREDOC at
// dev/handoff-smoke.sh:47-67.
//
// The original, verbatim:
//
//   import os, signal, sys, time
//   def mask(pid): ... read SigBlk from /proc/<pid>/status ...
//   def handler(sig, frame):
//       print('CHILD_GOT_SIGNAL=%d  (so the group-delivered signal reached the child)' % sig)
//       os._exit(40 + sig)
//   signal.signal(SIGINT, handler); signal.signal(SIGQUIT, handler)
//   print('CHILD pid=.. pgid=.. sid=.. SigBlk=0x%x  <- child must be 0x0')
//   print('PARENT pid=.. pgid=.. SigBlk=0x%x  <- us; 0x6 == SIGINT|SIGQUIT blocked')
//   time.sleep(8); print('CHILD_NO_SIGNAL')
//
// WHY BOTH MASKS MATTER, and why they are not the same claim twice:
//   * child SigBlk == 0x0  — the child must own Ctrl-C. handoff_run blocks
//     SIGINT|SIGQUIT in the parent BEFORE the fork to close the fork/exec gap,
//     and `child_pre_exec` un-blocks them again for the child. Forget the
//     un-block and the child starts life with Ctrl-C disabled: `git rebase -i`,
//     a pager, a build — nothing the user runs inside the handoff could be
//     interrupted.
//   * parent SigBlk == 0x6 — the app must NOT also take Ctrl-C. Ctrl-C on a
//     tty goes to the WHOLE foreground process group; if the app caught it too
//     then the app would tear the terminal back out from under the child that
//     still owns it.
//
// ASYNC-SIGNAL-SAFETY: the handler cannot format, allocate or open files. Every
// byte it writes was rendered BEFORE the handler was installed: the tty line into
// a const string and the evidence line into a const string, both to fds that
// were already open. `_exit` (not `exit`) because running atexit handlers in a
// forked child is how a second ledger flush and a double free happen.
// ─────────────────────────────────────────────────────────────────────────────

GOT_SIGNAL_TTY_INT  :: "\nCHILD_GOT_SIGNAL=2  (so the group-delivered signal reached the child)\n"
GOT_SIGNAL_TTY_QUIT :: "\nCHILD_GOT_SIGNAL=3  (so the group-delivered signal reached the child)\n"
GOT_SIGNAL_EV_INT   :: "child_got_signal=2\n"
GOT_SIGNAL_EV_QUIT  :: "child_got_signal=3\n"

// sig_probe_state is process-static: a "c" calling-convention handler has no
// context and therefore must not close over anything.
sig_probe_state :: struct {
	evidence_fd : posix.FD,
	have_fd     : bool,
}

SP : sig_probe_state = {}

on_sig_probe_signal :: proc "c" (sig: posix.Signal) {
	tty_msg := GOT_SIGNAL_TTY_INT
	ev_msg  := GOT_SIGNAL_EV_INT
	if sig == posix.Signal.SIGQUIT {
		tty_msg = GOT_SIGNAL_TTY_QUIT
		ev_msg = GOT_SIGNAL_EV_QUIT
	}
	posix.write(posix.FD(1), raw_data(tty_msg), c.size_t(len(tty_msg)))
	if SP.have_fd {
		posix.write(SP.evidence_fd, raw_data(ev_msg), c.size_t(len(ev_msg)))
	}
	// 40+sig, exactly like os._exit(40 + sig) in the python: the parent's
	// waitpid sees 42 for SIGINT, which is what makes "the child really caught
	// it and did not die of it" a distinguishable outcome.
	posix._exit(c.int(40 + i32(sig)))
}

role_sig_probe :: proc() -> i32 {
	// Open the evidence channel BEFORE installing the handler: the handler can
	// only write to an fd that already exists.
	epath := ev.path_for()
	if len(epath) > 0 {
		cp, _ := strings.clone_to_cstring(epath)
		fd := posix.open(cp, posix.O_Flags{.WRONLY, .CREAT, .APPEND},
			posix.mode_t{.IRUSR, .IWUSR})
		free(rawptr(cp))
		if int(fd) >= 0 {
			SP.evidence_fd = fd
			SP.have_fd = true
		}
	}

	pid := i64(posix.getpid())
	pgid := i64(posix.getpgid(0))
	sid := i64(posix.getsid(0))
	ppid_raw := posix.getppid()
	ppid := i64(ppid_raw)
	ppgid := i64(posix.getpgid(ppid_raw))
	self_mask := sigblk_hex_of("self")
	parent_mask := sigblk_hex_of(fmt.tprintf("{}", ppid))

	ev.say(fmt.tprintf("CHILD pid={} pgid={} sid={} SigBlk=0x{}  <- child must be 0x0\n",
		pid, pgid, sid, self_mask))
	ev.say(fmt.tprintf("PARENT pid={} pgid={} SigBlk=0x{}  <- the handoff owner; 0x6 == SIGINT|SIGQUIT blocked\n",
		ppid, ppgid, parent_mask))

	ev.report("child_pid", fmt.tprintf("{}", pid))
	ev.report("child_pgid", fmt.tprintf("{}", pgid))
	ev.report("child_sid", fmt.tprintf("{}", sid))
	sv, sok := hex_to_i64(self_mask)
	ev.report("child_sigblk", fmt.tprintf("{}", sv))
	ev.report("child_sigblk_hex", self_mask)
	ev.report("child_sigblk_readable", ifok(sok))
	ev.report("parent_pid", fmt.tprintf("{}", ppid))
	ev.report("parent_pgid", fmt.tprintf("{}", ppgid))
	pv, pok := hex_to_i64(parent_mask)
	ev.report("parent_sigblk", fmt.tprintf("{}", pv))
	ev.report("parent_sigblk_hex", parent_mask)
	ev.report("parent_sigblk_readable", ifok(pok))

	// Installed AFTER the masks were read: if the mask were installed first we
	// could not report the state we are asserting about, and the readiness key
	// must be visible to the harness before it group-kills or the kill could
	// land before the probe has reported anything.
	posix.signal(posix.Signal.SIGINT, on_sig_probe_signal)
	posix.signal(posix.Signal.SIGQUIT, on_sig_probe_signal)

	ev.report("sig_probe_ready", "1")
	time.sleep(8 * time.Second)
	ev.say("CHILD_NO_SIGNAL\n")
	ev.report("child_no_signal", "1")
	return 0
}

// ─────────────────────────────────────────────────────────────────────────────
// ROLE: exit7 — the `sh -c 'exit 7'` of case 4, compiled.
//
// A dedicated role rather than a shell so the exit-code-propagation check does
// not depend on /bin/sh being present in the sandbox, and so the child says
// something on the tty first: exit code 7 with no output would be
// indistinguishable from "the child never ran".
// ─────────────────────────────────────────────────────────────────────────────

role_exit7 :: proc() -> i32 {
	ev.say("CHILD_EXIT7_MARKER about to exit 7\n")
	ev.report("exit7_ran", "1")
	// _exit, not exit: no atexit handlers run in the handoff's child.
	posix._exit(7)
}

// ─────────────────────────────────────────────────────────────────────────────
// Environment helpers
// ─────────────────────────────────────────────────────────────────────────────

HERDR_PREFIX :: "HERDR_"

// collect_herdr returns the HERDR_* names and the joined NAME=value blob that
// `env | grep '^HERDR_'` produced in the shell probe.
collect_herdr :: proc() -> (names: string, all: string) {
	env, err := os.environ(context.allocator)
	if err != nil { return "", "" }
	names_list : [dynamic]string
	all_list : [dynamic]string
	for entry in env {
		if !strings.has_prefix(entry, HERDR_PREFIX) { continue }
		eq := strings.index(entry, "=")
		name := entry
		if eq > 0 { name = entry[:eq] }
		append(&names_list, name)
		append(&all_list, entry)
	}
	return join(names_list[:], ","), join(all_list[:], " ")
}

// join is a plain, index-addressed join. Deliberately NOT `for a, b in parts`:
// in Odin that is (VALUE, INDEX), and swapping the two here would silently emit
// the separator the wrong number of times rather than fail.
join :: proc(parts: []string, sep: string) -> string {
	total := 0
	for i := 0; i < len(parts); i += 1 { total += len(parts[i]) }
	if len(parts) > 1 { total += (len(parts) - 1) * len(sep) }
	out := make([]byte, total)
	at := 0
	for i := 0; i < len(parts); i += 1 {
		if i > 0 {
			mem.copy(rawptr(&out[at]), raw_data(sep), len(sep))
			at += len(sep)
		}
		if len(parts[i]) > 0 {
			mem.copy(rawptr(&out[at]), raw_data(parts[i]), len(parts[i]))
			at += len(parts[i])
		}
	}
	return string(out[:])
}

env_or_missing :: proc(key: string) -> string {
	v, found := os.lookup_env(key, context.allocator)
	if !found || len(v) == 0 { return "MISSING" }
	return v
}

// current_dir is the `pwd` of the shell probe. getcwd into a fixed buffer, then
// clone out — the buffer is stack storage and must not be returned as a string.
current_dir :: proc() -> string {
	buf : [4096]u8
	p := posix.getcwd(&buf[0], c.size_t(len(buf)))
	if p == nil { return "unreadable" }
	return strings.clone(string(p), context.allocator)
}

// tty_of mirrors `tty`: the device name when the fd is a terminal, and
// "not-a-tty" when it is not (ttyname fails with ENOTTY/EBADF).
tty_of :: proc(fd: i32) -> string {
	name := posix.ttyname(posix.FD(fd))
	if name == nil { return "not-a-tty" }
	s := string(name)
	if len(s) == 0 { return "not-a-tty" }
	return strings.clone(s, context.allocator)
}

lookup_role :: proc() -> (string, bool) {
	v, found := os.lookup_env(ROLE_ENV, context.allocator)
	if !found { return "", false }
	return v, true
}

set_role :: proc(r: string) {
	os.set_env(ROLE_ENV, r)
}

// install_leaky_env copies $HS_LEAK ("K=V;K=V") into our real environment and
// returns how many HERDR_* variables we now hold. Non-HERDR_* names are
// installed too but not counted — the count is what the probe compares against.
install_leaky_env :: proc() -> int {
	blob := os.get_env_alloc("HS_LEAK", context.allocator)
	if len(blob) == 0 { return 0 }
	count := 0
	pairs, _ := strings.split(blob, ";")
	for pair in pairs {
		if len(pair) == 0 { continue }
		eq := strings.index(pair, "=")
		if eq < 0 { continue }
		k := pair[:eq]
		v := pair[eq+1:]
		os.set_env(k, v)
		if strings.has_prefix(k, HERDR_PREFIX) { count += 1 }
	}
	return count
}

home_dir :: proc() -> string {
	h := os.get_env_alloc("HOME", context.allocator)
	if len(h) == 0 { return "/" }
	return h
}

self_exe_path :: proc() -> string {
	p, err := os.get_executable_path(context.allocator)
	if err != nil || len(p) == 0 { return "" }
	return p
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry
// ─────────────────────────────────────────────────────────────────────────────

// run_role dispatches one role and returns the process exit code. Unknown role
// names come back as 2 rather than falling through to a default: a typo must be
// loud, not a silent no-op that the harness reads as "the role ran".
run_role :: proc(role: string) -> i32 {
	// Registered BEFORE any handoff, for every role, so there is exactly one
	// repaint hook and it is unmistakably ours. The handoff calls it after it
	// gets the terminal back; FRAMES_PAINTED going nonzero is what makes
	// "the handoff forced a repaint" (plan step 6) assertable from outside.
	termhandoff.set_full_repaint(hs_repaint_hook)
	switch role {
	case "abi":       return role_abi()
	case "double":    return role_double()
	case "handoff":   return role_handoff(handoff_secs())
	case "child":     return role_child()
	case "sig-term":  return role_sig_term()
	case "env-probe": return role_env_probe()
	case "sig-probe": return role_sig_probe()
	case "exit7":     return role_exit7()
	case:
		fmt.eprintf("hsapp: unknown role '{}'\n", role)
		return 2
	}
}

handoff_secs :: proc() -> string {
	s := os.get_env_alloc("HS_HANDOFF_SECS", context.allocator)
	if len(s) == 0 { return "2" }
	return s
}

// role_is_installed guards the (rare) case of the role dispatcher being entered
// twice in one process — it must not re-run.
role_is_installed :: proc() -> bool {
	return dispatch_claimed
}

dispatch_claimed : bool = false

// claim_and_run is the single entry the `@(init)` hook uses. Returns the exit
// code, or -1 when $HS_ROLE is not set at all (i.e. "not a role run, carry on
// with whatever this binary is for").
claim_and_run :: proc() -> i32 {
	role, found := lookup_role()
	if !found || len(role) == 0 { return -1 }
	if dispatch_claimed { return -1 }
	dispatch_claimed = true
	return run_role(role)
}
