package it

// ─────────────────────────────────────────────────────────────────────────────
// handoff_test.odin — T11, the port of dev/handoff-smoke.sh.
//
// THE OLD SUITE, IN ONE SENTENCE: prove that giving the terminal away and taking
// it back is clean — that the child gets a real tty, that the user's terminal
// comes back unchanged, that exit codes survive, that Ctrl-C reaches the child
// and not the app, and that SIGTERM/SIGHUP do not strand the user on a
// half-restored screen.
//
// FLOOR 35 (tests/parity.tsv, tier=hermetic). The mapping from every old
// check site to the assertion that now carries it:
//
//   old 135  "$BIN probe"            -> handoff_abi_probe_reports_the_pinned_abi (6)
//   old 141  double init/shutdown    -> handoff_double_init_shutdown_round_trips (6)
//   old 155  check_stty  (03)       ┐
//   old 158  handoff+repaint+key    │-> handoff_to_sleep_repaints_and_reads_a_key (4)
//   old 155  termios round-trip     ┘
//   old 165  exit code (04)         -> handoff_child_exit_code_surfaces (2 mirrored + the
//                                    child's 7 itself, which the old suite only PRINTED)
//   old 175  env scrub/pgroup/cwd   -> handoff_scrubs_herdr_env: 2 mirrored + 8 facts the
//                                    env_probe.sh HEREDOC produced but the old suite never
//                                    counted (see the port note below)
//   old 196  check_stty  (06)       ┐
//   old 199  SIGINT during handoff  │-> handoff_sigint_goes_to_the_child (2 mirrored +
//   old 196  termios round-trip     ┘   the sig_probe.py HEREDOC's two masks + 40+sig)
//   old 224  check_stty x N         ┐
//   old 250  terminal restoration   ┘-> handoff_sigterm_and_sighup_restore_the_terminal (3 x 2)
//
// THE TWO HEREDOC PROBES ARE PORTED. Not imitated, not skipped:
//
//   env_probe.sh (dev/handoff-smoke.sh:37-45)  → role `env-probe`,
//     tests/it/probes/hsapp/hsapp.odin. Same five lines, same field
//     meanings (pid/pgid/sid from getpgrp/getsid — the same values awk read
//     out of /proc/self/stat columns 5 and 6 — HERDR_* prefix walk, TERM/
//     COLORTERM, ttyname(0)), plus the foreground-pgid question `tty` cannot answer.
//
//   sig_probe.py (dev/handoff-smoke.sh:47-67)  → role `sig-probe`, same file.
//     Same child SigBlk=0x0, same parent SigBlk=0x6, same handler that prints
//     CHILD_GOT_SIGNAL=<n> and exits 40+n, same CHILD_NO_SIGNAL fall-through
//     after the sleep.
//
// Those two probes' behaviours were the whole substance of old check sites 175
// and 196/199 while living as shell and python text generated at run time. If
// this file had been written without them, deleting dev/ at T17 would have
// deleted the assertions along with the files.
//
// WHAT IS ADDITIVE (never subtracted from anyone's floor): the termios
// anti-vacuity check ("was the terminal ever actually raw?"), the exact key
// the app read, the child's exit 7 as a counted value, the app's post-handoff
// signal mask, and the alt-screen byte-ordering claims that the old suite ran
// through stream_order.py and printed without counting.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"

import pty "../pty"
import support "../support"

// ck is the one counted assertion of this group. `loc` is forwarded so the
// ledger group stays `handoff_test` rather than being attributed to wherever
// this helper happens to live.
ck :: proc(t: ^testing.T, name: string, cond: bool, detail: string, loc := #caller_location) {
	support.check(t, name, cond, detail, loc=loc)
}

// ─────────────────────────────────────────────────────────────────────────────
// old 135 — "$BIN probe": the foreign ABI is not garbled.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
handoff_abi_probe_reports_the_pinned_abi :: proc(t: ^testing.T) {
	h, err := hh_begin("abi", "abi", {})
	if err != "" {
		ck(t, "the abi probe role spawned on a pty", false, err)
		return
	}
	defer hh_finish(h)

	keys := []string{
		"abi_wcwidth_A", "abi_wcwidth_CJK", "abi_attr_width",
		"abi_has_truecolor", "abi_clay_min_memory", "abi_event_size",
	}
	m, ok := hh_wait_ev(h, "abi_event_size", 20_000)
	// The completeness check comes FIRST: if the role died halfway, six
	// "absent != 1" failures would bury the one fact that matters (which key
	// never arrived).
	ck(t, "the probe reported all six ABI facts", ok && hh_ev_missing_names(m, keys) == "",
		fmt.tprintf("missing=[{}] wait_ok={}", hh_ev_missing_names(m, keys), ok))

	ck(t, "tb_wcwidth('A') == 1", hh_ev_is(m, "abi_wcwidth_A", 1),
		fmt.tprintf("got {}", hh_ev_str(m, "abi_wcwidth_A")))
	ck(t, "tb_wcwidth(U+4E00) == 2", hh_ev_is(m, "abi_wcwidth_CJK", 2),
		fmt.tprintf("got {}", hh_ev_str(m, "abi_wcwidth_CJK")))
	ck(t, "tb_attr_width() == 32 (TB_OPT_ATTR_W really built in)",
		hh_ev_is(m, "abi_attr_width", 32),
		fmt.tprintf("got {}", hh_ev_str(m, "abi_attr_width")))
	ck(t, "tb_has_truecolor() == 1", hh_ev_is(m, "abi_has_truecolor", 1),
		fmt.tprintf("got {}", hh_ev_str(m, "abi_has_truecolor")))
	clay_mem, clay_ok := hh_ev_i64(m, "abi_clay_min_memory")
	ck(t, "clay archive linked (MinMemorySize > 0)", clay_ok && clay_mem > 0,
		fmt.tprintf("clay.MinMemorySize() = {}", hh_ev_str(m, "abi_clay_min_memory")))
	ck(t, "Event struct is 24 bytes", hh_ev_is(m, "abi_event_size", 24),
		fmt.tprintf("size_of(termbox2.Event) = {}", hh_ev_str(m, "abi_event_size")))
}

// ─────────────────────────────────────────────────────────────────────────────
// old 141 — two tb_init/tb_shutdown round-trips, plus the guards that make the
// state machine lie-proof. The termios half of this case (old stty line 1) is
// carried below: after three init/shutdown pairs the user's terminal must still
// be exactly what it was.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
handoff_double_init_shutdown_round_trips :: proc(t: ^testing.T) {
	h, err := hh_begin("double", "double", {})
	if err != "" {
		ck(t, "the double role spawned on a pty", false, err)
		return
	}
	defer hh_finish(h)

	m, ok := hh_wait_ev(h, "double_r6", 20_000)
	if !ok {
		ck(t, "the double role reported all six init/shutdown codes", false,
			fmt.tprintf("never saw double_r6; keys present: {}; {}",
				hh_ev_missing_names(m, []string{"double_r1", "double_r2", "double_r3",
					"double_r4", "double_r5", "double_r6"}), hh_exit_info(h)))
		return
	}

	r1, _ := hh_ev_i64(m, "double_r1")
	r2, _ := hh_ev_i64(m, "double_r2")
	r3, _ := hh_ev_i64(m, "double_r3")
	r4, _ := hh_ev_i64(m, "double_r4")
	r5, _ := hh_ev_i64(m, "double_r5")
	r6, _ := hh_ev_i64(m, "double_r6")

	ck(t, "first tb_init == TB_OK", r1 == 0, fmt.tprintf("got {}", r1))
	ck(t, "second tb_init == TB_ERR_INIT_ALREADY", r2 == -3, fmt.tprintf("got {}", r2))
	ck(t, "first tb_shutdown == TB_OK", r3 == 0, fmt.tprintf("got {}", r3))
	ck(t, "second tb_shutdown == TB_ERR_NOT_INIT", r4 == -8, fmt.tprintf("got {}", r4))
	ck(t, "re-init after shutdown == TB_OK", r5 == 0, fmt.tprintf("got {}", r5))
	ck(t, "final tb_shutdown == TB_OK", r6 == 0, fmt.tprintf("got {}", r6))

	// The old suite PRINTED "program exit code" for every case and counted it
	// nowhere. Here it is counted.
	hh_wait_exit(h, 15_000)
	ck(t, "the double case exits 0", hh_exit_info(h) == "exit=0", hh_exit_info(h))

	// check_stty, carried (old STTY_LOG line 1: "02-double: stty -a before == after").
	same, detail := hh_termios_round_trip(h)
	ck(t, "termios round-trips across three init/shutdown pairs", same, detail)
}

// ─────────────────────────────────────────────────────────────────────────────
// old 155 + 158 — hand off to `sleep`, take the terminal back, prove the
// repaint fired and that a keypress is still readable AFTER the handoff.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
handoff_to_sleep_repaints_and_reads_a_key :: proc(t: ^testing.T) {
	h, err := hh_begin("sleep2", "handoff", []HH_KV{HH_KV{"HS_HANDOFF_SECS", "1"}})
	if err != "" {
		ck(t, "the handoff role spawned on a pty", false, err)
		return
	}
	defer hh_finish(h)

	// Wait for the role to say the child is gone and the terminal is ours
	// again, THEN press. Pressing earlier would measure the child's input queue.
	m, ok := hh_wait_ev(h, "ready_for_key", 20_000)
	if !ok {
		ck(t, "the handoff reached the post-handoff wait", false,
			fmt.tprintf("never saw ready_for_key; missing={}; {}",
				hh_ev_missing_names(m, []string{"handoff_ok", "handoff_exit", "frames"}),
				hh_exit_info(h)))
		return
	}

	// ANTI-VACUITY, sampled NOW: the role is parked in the alt screen with
	// the terminal re-acquired, so the line discipline is in the mode tb_init
	// left it in. Without this, "before == after" below would be just as true
	// of a process that never touched the tty at all.
	mid, mid_ok := pty.pty_termios_now(h.d)
	ck(t, "the app really did take the terminal (ECHO and ICANON both off while it owned it)",
		mid_ok && hh_termios_is_raw(mid),
		fmt.tprintf("tcgetattr_ok={} lflag={} raw={}", mid_ok, hh_bits_lflag(mid), hh_termios_is_raw(mid)))

	child_exit, cx_ok := hh_ev_i64(m, "handoff_exit")
	hok, _ := hh_ev_bool(m, "handoff_ok")
	frames, fr_ok := hh_ev_i64(m, "frames")

	ck(t, "child exit == 0", cx_ok && child_exit == 0,
		fmt.tprintf("got {} (killed_by={})", hh_ev_str(m, "handoff_exit"), hh_ev_str(m, "handoff_killed_by")))
	ck(t, "terminal re-acquired", hok,
		fmt.tprintf("ok={} err={} ({})", hh_ev_str(m, "handoff_ok"), hh_ev_str(m, "handoff_err"),
			hh_exit_info(h)))
	ck(t, "forced repaint ran after the handoff", fr_ok && frames >= 1,
		fmt.tprintf("FRAMES_PAINTED={}", hh_ev_str(m, "frames")))

	// Now the key. 'j' = 0x6A, the same byte the old suite piped in after a
	// delay, sent here only after the role announced it was listening.
	pty.pty_send(h.d, "j")
	km, kok := hh_wait_ev(h, "got_key", 15_000)
	got, _ := hh_ev_bool(km, "got_key")
	ck(t, "a keypress is readable after the handoff", kok && got,
		fmt.tprintf("got_key={} wait_ok={} {}", hh_ev_str(km, "got_key"), kok, hh_exit_info(h)))
	ch, ch_ok := hh_ev_i64(km, "key_ch")
	ck(t, "the byte the app read is the byte we sent (0x6A 'j')", ch_ok && ch == 0x6A,
		fmt.tprintf("key_ch={} want 106", hh_ev_str(km, "key_ch")))

	hh_wait_exit(h, 15_000)
	same, detail := hh_termios_round_trip(h)
	ck(t, "termios round-trips over handoff + repaint + re-entry", same, detail)

	// ADDITIVE: the ordering the old suite printed through stream_order.py and
	// never counted. LEAVE must precede the re-ENTER, and the repaint must
	// follow the re-entry — that is the difference between "the child owned a
	// screen we had released" and "the child painted over our UI".
	leaves := hh_raw_count(h, HH_ALT_LEAVE)
	enters := hh_raw_count(h, HH_ALT_ENTER)
	leave_at := hh_raw_index(h, HH_ALT_LEAVE)
	enter2 := hh_raw_index(h, HH_ALT_ENTER, 1)
	ck(t, "the app leaves the alt screen before it hands the terminal over",
		leaves >= 1 && leave_at >= 0,
		fmt.tprintf("alt-leave sequences={} first_at={}", leaves, leave_at))
	ck(t, "the app re-enters the alt screen after the child's turn (enter > leave)",
		enters >= 2 && enter2 > leave_at && leave_at >= 0,
		fmt.tprintf("enters={} second_enter_at={} first_leave_at={}", enters, enter2, leave_at))
}

// ─────────────────────────────────────────────────────────────────────────────
// old 165 — exit-code propagation. The old case piped `sh -c 'exit 7'`
// through the handoff, PRINTED "CHILD exit=7" and counted only two things.
// The 7 itself is counted here.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
handoff_child_exit_code_surfaces :: proc(t: ^testing.T) {
	h, err := hh_begin("exit7", "child", []HH_KV{HH_KV{"HS_CHILD_ROLE", "exit7"}})
	if err != "" {
		ck(t, "the exit-7 child spawned through the handoff", false, err)
		return
	}
	defer hh_finish(h)

	m, ok := hh_wait_ev(h, "handoff_exit", 20_000)
	if !ok {
		ck(t, "the handoff of the exit-7 child completed", false,
			fmt.tprintf("never saw handoff_exit; missing={}; {}",
				hh_ev_missing_names(m, []string{"handoff_ok", "frames"}), hh_exit_info(h)))
		return
	}
	// ANTI-VACUITY, reported by the app from its OWN fd at the moment it held
	// the tty. A harness-side sample cannot be used here: this child exits
	// immediately, so the app's raw-mode window closes before the harness can
	// look. See report_tty_raw in tests/it/probes/hsapp/hsapp.odin.
	ck(t, "the app really did take the terminal (ECHO and ICANON off while it owned it)",
		hh_ev_is_str(m, "app_after_tty_raw", "yes"),
		fmt.tprintf("app-reported raw={} lflag={}", hh_ev_str(m, "app_after_tty_raw"),
			hh_ev_str(m, "app_after_tty_lflag")))

	child_exit, cx_ok := hh_ev_i64(m, "handoff_exit")
	hok, _ := hh_ev_bool(m, "handoff_ok")
	frames, fr_ok := hh_ev_i64(m, "frames")

	ck(t, "handoff returned ok (terminal reacquired)", hok,
		fmt.tprintf("ok={} err={} (exit={} killed_by={})", hh_ev_str(m, "handoff_ok"),
			hh_ev_str(m, "handoff_err"), hh_ev_str(m, "handoff_exit"), hh_ev_str(m, "handoff_killed_by")))
	ck(t, "forced repaint ran", fr_ok && frames >= 1, fmt.tprintf("FRAMES_PAINTED={}", hh_ev_str(m, "frames")))
	ck(t, "the child's exit 7 surfaces through the handoff as 7", cx_ok && child_exit == 7,
		fmt.tprintf("got {} want 7", hh_ev_str(m, "handoff_exit")))
	// The child said something before it exited: exit 7 with no output at all
	// would be indistinguishable from "the child never ran".
	hh_pump(h, 200)
	ck(t, "the exit-7 child really ran (it wrote to the tty it inherited)",
		hh_raw_index(h, "CHILD_EXIT7_MARKER") >= 0 || hh_ev_has(m, "exit7_ran"),
		fmt.tprintf("tty marker seen={} evidence seen={}",
			hh_raw_index(h, "CHILD_EXIT7_MARKER") >= 0, hh_ev_has(m, "exit7_ran")))

	hh_wait_exit(h, 15_000)
	same, detail := hh_termios_round_trip(h)
	ck(t, "termios round-trips after a nonzero-exit child", same, detail)
}

// ─────────────────────────────────────────────────────────────────────────────
// old 175 — "env scrub / pgroup / cwd".
//
// The old tally line at :175 counted TWO assertions (handoff ok, repaint) and
// left everything env_probe.sh printed as commentary. The probe's five lines
// were the actual content of the case. They are counted here, and the probe
// runs as a compiled Odin role rather than a shell script the harness writes
// to disk.
//
// WHY THE ANTI-VACUITY CHECK IS NOT OPTIONAL: "the child saw zero HERDR_*
// variables" is also true of a spawner that never had any. The leak is
// installed deliberately (seven names, HH_LEAK) and counted before the
// handoff, so the zero on the other side is a scrub and not an absence.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
handoff_scrubs_herdr_env :: proc(t: ^testing.T) {
	cwd := "/tmp/hs-t-handoff-cwd"
	os.remove(cwd)
	if e := os.mkdir_all(cwd); e != nil && !os.is_dir(cwd) {
		ck(t, "the scratch cwd for the env probe could be created", false, fmt.tprintf("{}", e))
		return
	}

	h, err := hh_begin("env", "child", []HH_KV{
		HH_KV{"HS_CHILD_ROLE", "env-probe"},
		HH_KV{"HS_CHILD_CWD", cwd},
		HH_KV{"HS_LEAK", HH_LEAK},
	})
	if err != "" {
		ck(t, "the env-probe child spawned through the handoff", false, err)
		return
	}
	defer hh_finish(h)

	m, ok := hh_wait_ev(h, "env_probe_done", 20_000)
	if !ok {
		ck(t, "the env probe reported", false,
			fmt.tprintf("never saw env_probe_done; missing={}; {}",
				hh_ev_missing_names(m, []string{"child_herdr_count", "child_pwd", "child_stdin_tty"}),
				hh_exit_info(h)))
		return
	}

	// The two the old tally actually counted.
	hok, _ := hh_ev_bool(m, "handoff_ok")
	frames, fr_ok := hh_ev_i64(m, "frames")
	ck(t, "handoff returned ok (terminal reacquired)", hok,
		fmt.tprintf("ok={} err={}", hh_ev_str(m, "handoff_ok"), hh_ev_str(m, "handoff_err")))
	ck(t, "forced repaint ran", fr_ok && frames >= 1, fmt.tprintf("FRAMES_PAINTED={}", hh_ev_str(m, "frames")))

	// The premise, stated as an assertion.
	app_herdr, ah_ok := hh_ev_i64(m, "app_herdr_count")
	ck(t, "the app really held HERDR_* before handing over (the scrub has something to remove)",
		ah_ok && app_herdr == HH_LEAK_COUNT,
		fmt.tprintf("app HERDR_* count={} want {}", hh_ev_str(m, "app_herdr_count"), HH_LEAK_COUNT))

	// env_probe.sh line 2: CHILD HERDR_VARS=0
	herdr_n, hn_ok := hh_ev_i64(m, "child_herdr_count")
	ck(t, "CHILD HERDR_VARS == 0 — the whole HERDR_ namespace is gone",
		hn_ok && herdr_n == 0,
		fmt.tprintf("child saw {} HERDR_* variable(s): [{}]", hh_ev_str(m, "child_herdr_count"),
			hh_ev_str(m, "child_herdr_blob")))
	// env_probe.sh line 3: CHILD HERDR_LINES:[]
	ck(t, "CHILD HERDR_LINES is empty", hh_ev_str(m, "child_herdr_blob") == "",
		fmt.tprintf("blob='{}'", hh_ev_str(m, "child_herdr_blob")))
	// env_probe.sh line 4: TERM / COLORTERM survive — dropping them would
	// downgrade a herdr child's rendering from SemanticFrame to TerminalAnsi.
	ck(t, "CHILD TERM survived the scrub", hh_ev_str(m, "child_term") == HH_TERM,
		fmt.tprintf("child TERM='{}' want '{}'", hh_ev_str(m, "child_term"), HH_TERM))
	ck(t, "CHILD COLORTERM survived the scrub", hh_ev_str(m, "child_colorterm") == HH_COLORTERM,
		fmt.tprintf("child COLORTERM='{}' want '{}'", hh_ev_str(m, "child_colorterm"), HH_COLORTERM))
	// env_probe.sh line 5: CHILD stdin=<a tty>, never "not-a-tty"
	tty_name := hh_ev_str(m, "child_stdin_tty")
	ck(t, "CHILD stdin is a real terminal (tty, not 'not-a-tty')",
		tty_name != "not-a-tty" && len(tty_name) > 0 && tty_name[0] == '/',
		fmt.tprintf("child stdin={}", tty_name))
	// env_probe.sh line 1: same pgroup, same session — NO setsid().
	app_pgid, apg_ok := hh_ev_i64(m, "app_pgid")
	child_pgid, cpg_ok := hh_ev_i64(m, "child_pgid")
	ck(t, "the child is in the app's foreground process group (no setsid)",
		apg_ok && cpg_ok && child_pgid == app_pgid,
		fmt.tprintf("app pgid={} child pgid={}", hh_ev_str(m, "app_pgid"), hh_ev_str(m, "child_pgid")))
	app_sid, asd_ok := hh_ev_i64(m, "app_sid")
	child_sid, csd_ok := hh_ev_i64(m, "child_sid")
	ck(t, "the child stayed in the app's session", asd_ok && csd_ok && child_sid == app_sid,
		fmt.tprintf("app sid={} child sid={}", hh_ev_str(m, "app_sid"), hh_ev_str(m, "child_sid")))
	// env_probe.sh line 1: pwd — the cwd is the one WE set, not the spawner's.
	// (A session herdr creates takes the spawner's cwd as its identity_cwd, so
	// an accidental inherit here is a permanent property of that session.)
	ck(t, "the child's cwd is the explicitly handed-over one",
		hh_ev_str(m, "child_pwd") == cwd,
		fmt.tprintf("child pwd='{}' want '{}'", hh_ev_str(m, "child_pwd"), cwd))
	// What `tty` cannot answer: who is IN FRONT of that terminal.
	fg, fg_ok := hh_ev_i64(m, "child_tty_fg_pgid")
	ck(t, "the child is in the tty's foreground group (so it receives input)",
		fg_ok && child_pgid != 0 && fg == child_pgid,
		fmt.tprintf("tty foreground pgid={} child pgid={}", hh_ev_str(m, "child_tty_fg_pgid"),
			hh_ev_str(m, "child_pgid")))

	hh_wait_exit(h, 15_000)
	same, detail := hh_termios_round_trip(h)
	ck(t, "termios round-trips over the env-probe handoff", same, detail)
}

// ─────────────────────────────────────────────────────────────────────────────
// old 196 + 199 — SIGINT while the child owns the tty.
//
// sig_probe.py's two masks are the whole point and neither is a duplicate of
// the other:
//
//   child SigBlk == 0x0   the child OWNS Ctrl-C. handoff_run blocks
//                         SIGINT|SIGQUIT in the parent before the fork to
//                         close the fork/exec window and `child_pre_exec`
//                         clears them again for the child. Forget the clear
//                         and everything the user runs inside the handoff —
//                         a pager, a rebase, a build — starts life
//                         uninterruptible.
//   parent SigBlk == 0x6  the app does NOT also take Ctrl-C. A tty's Ctrl-C
//                         goes to the whole foreground group; if the app
//                         caught it too it would yank the screen back from
//                         under a child that still owns it.
//
// Measured from INSIDE each process, from its own /proc entry — which is the
// only way to ask the question of the process that is actually running.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
handoff_sigint_goes_to_the_child_and_not_the_app :: proc(t: ^testing.T) {
	// Mirrors :196/:199 AS IT ACTUALLY RAN. The old launcher was
	//   script -q -e -c "stty rows 40 cols 120; $BIN child … sig_probe.py"
	// A non-interactive shell that has to FORK (any -c string with more than
	// one command) sets SIGINT and SIGQUIT to SIG_IGN in the child, so the
	// app ran with Ctrl-C ignored. That is why its "case 6" exited 0 — see
	// the sibling test below for what happens without it.
	h, err := hh_begin("sigint-ign", "child", []HH_KV{
		HH_KV{"HS_CHILD_ROLE", "sig-probe"},
		HH_KV{"HS_CHILD_CWD", "/tmp"},
		HH_KV{"HS_IGN_INT_QUIT", "1"},
	})
	if err != "" {
		ck(t, "the sig-probe child spawned through the handoff", false, err)
		return
	}
	defer hh_finish(h)

	// The masks must be read BEFORE we signal — once the handler fires the
	// probe is gone. Hence waiting for the probe's readiness key rather than
	// sleeping a guessed amount.
	m, ok := hh_wait_ev(h, "sig_probe_ready", 20_000)
	if !ok {
		ck(t, "the sig probe reported before being signalled", false,
			fmt.tprintf("never saw sig_probe_ready; missing={}; {}",
				hh_ev_missing_names(m, []string{"child_sigblk", "parent_sigblk"}), hh_exit_info(h)))
		return
	}

	ck(t, "both masks were readable (a mask we cannot read must not read as 0x0)",
		hh_ev_is_str(m, "child_sigblk_readable", "yes") &&
			hh_ev_is_str(m, "parent_sigblk_readable", "yes"),
		fmt.tprintf("child={} parent={}", hh_ev_str(m, "child_sigblk_readable"),
			hh_ev_str(m, "parent_sigblk_readable")))
	ck(t, "the 'parent' the probe measured is the app that handed over the terminal",
		hh_ev_is_str(m, "app_pid", hh_ev_str(m, "parent_pid")) && hh_ev_has(m, "app_pid"),
		fmt.tprintf("app pid={} probe's ppid={}", hh_ev_str(m, "app_pid"), hh_ev_str(m, "parent_pid")))

	// CHILD ... SigBlk=0x0  <- child must be 0x0
	child_mask, cm_ok := hh_ev_i64(m, "child_sigblk")
	ck(t, "CHILD SigBlk == 0x0 — the child owns Ctrl-C", cm_ok && child_mask == 0,
		fmt.tprintf("child SigBlk=0x{} want 0x0", hh_ev_str(m, "child_sigblk_hex")))

	// PARENT ... SigBlk=0x6  <- SIGINT|SIGQUIT blocked while the child owns the tty
	parent_mask, pm_ok := hh_ev_i64(m, "parent_sigblk")
	ck(t, "PARENT SigBlk == 0x6 — the handoff owner blocks SIGINT|SIGQUIT so it does not race the child for Ctrl-C",
		pm_ok && parent_mask == 0x6,
		fmt.tprintf("parent SigBlk=0x{} want 0x6 (SIGINT|SIGQUIT)", hh_ev_str(m, "parent_sigblk_hex")))

	// Group-kill, exactly as the tty driver does with Ctrl-C.
	pty.pty_signal_group(h.d, posix.Signal.SIGINT)

	mm, mm_ok := hh_wait_ev(h, "handoff_exit", 20_000)
	if !mm_ok {
		ck(t, "the handoff completed after the group SIGINT", false,
			fmt.tprintf("never saw handoff_exit; {}", hh_exit_info(h)))
		return
	}
	ck(t, "the group-delivered SIGINT reached the child (CHILD_GOT_SIGNAL=2)",
		hh_ev_is(mm, "child_got_signal", 2),
		fmt.tprintf("child_got_signal={}", hh_ev_str(mm, "child_got_signal")))
	ck(t, "the child exited 42 = 40+SIGINT, the 40-signal convention the probe sets",
		hh_ev_is(mm, "handoff_exit", 42),
		fmt.tprintf("handoff_exit={} want 42", hh_ev_str(mm, "handoff_exit")))
	ck(t, "handoff returned ok (terminal reacquired)", hh_ev_true(mm, "handoff_ok"),
		fmt.tprintf("ok={} err={}", hh_ev_str(mm, "handoff_ok"), hh_ev_str(mm, "handoff_err")))
	frames, fr_ok := hh_ev_i64(mm, "frames")
	ck(t, "the forced repaint still ran after a child killed by Ctrl-C", fr_ok && frames >= 1,
		fmt.tprintf("FRAMES_PAINTED={}", hh_ev_str(mm, "frames")))

	hh_wait_exit(h, 15_000)
	ck(t, "the app exits 0 after the SIGINT storm, not to a signal",
		hh_exit_info(h) == "exit=0", hh_exit_info(h))
	// handoff_run restores the mask it set. If it did not, the app would go
	// on blocking SIGINT|SIGQUIT forever and the user's Ctrl-C would be dead
	// for the rest of the app's life. Read the map FRESH: `m` was loaded
	// before the handoff even finished, so the after-handoff keys were not in
	// it yet — which is exactly what a "<absent>" in a detail line means.
	fm := hh_ev_load(h)
	after_mask, am_ok := hh_ev_i64(fm, "app_after_sigblk")
	ck(t, "the app's own SIGINT|SIGQUIT block is lifted after the handoff",
		am_ok && (after_mask & 0x6) == 0,
		fmt.tprintf("app SigBlk after = 0x{}", hh_ev_str(fm, "app_after_sigblk_hex")))

	same, detail := hh_termios_round_trip(h)
	ck(t, "termios round-trips after a SIGINT during the handoff", same, detail)
}

// THE FINDING THE OLD SUITE COULD NOT SEE.
//
// The old "SIGINT during handoff" case ran under `script` with a multi-command
// -c string, so the app inherited SIGINT/SIGQUIT as SIG_IGN and glided past
// the group Ctrl-C. Run the SAME handoff with the default disposition — which
// is what the product gets when it is exec'd directly rather than by a
// forking shell — and the group Ctrl-C is fatal to the app: handoff_run blocks
// SIGINT before the fork, the child takes it and dies, the app unblocks its
// mask, the signal is still pending on the app, and the default disposition is
// "terminate".
//
// This is reported, not hidden: it is asserted here as measured, in the same
// shape every other case uses, so if the product later makes the app's
// disposition explicit (install_terminal_restore_handlers covers SIGTERM and
// SIGHUP but not SIGINT/SIGQUIT) this test changes and says so.
@(test)
handoff_sigint_default_disposition_is_a_real_finding :: proc(t: ^testing.T) {
	h, err := hh_begin("sigint-default", "child", []HH_KV{
		HH_KV{"HS_CHILD_ROLE", "sig-probe"},
		HH_KV{"HS_CHILD_CWD", "/tmp"},
	})
	if err != "" {
		ck(t, "the default-disposition sig-probe case spawned", false, err)
		return
	}
	defer hh_finish(h)

	m, ok := hh_wait_ev(h, "sig_probe_ready", 20_000)
	if !ok {
		ck(t, "the sig probe reported before being signalled", false,
			fmt.tprintf("never saw sig_probe_ready; {}", hh_exit_info(h)))
		return
	}
	// The premise, from the app's own /proc entry: no IGNored INT/QUIT here.
	ck(t, "this run really did have the DEFAULT SIGINT disposition (SigIgn == 0x0)",
		hh_ev_is_str(m, "app_sigign", "0000000000000000"),
		fmt.tprintf("app SigIgn={}", hh_ev_str(m, "app_sigign")))
	// The child's story is unchanged: it still owns Ctrl-C and still catches it.
	ck(t, "the child still caught the group SIGINT (child SigBlk 0x0, signal 2 received)",
		hh_ev_is(m, "child_sigblk", 0),
		fmt.tprintf("child SigBlk=0x{}", hh_ev_str(m, "child_sigblk_hex")))

	pty.pty_signal_group(h.d, posix.Signal.SIGINT)
	hh_wait_exit(h, 20_000)
	hh_pump(h, 250)

	ck(t, "with the default disposition the app dies to the pending SIGINT (exit 130)",
		contains_i(hh_exit_info(h), "exit=130"),
		fmt.tprintf("exit info='{}' want exit=130", hh_exit_info(h)))
	// The child did report its 40+SIGINT exit even though the app died around it.
	fm, _ := hh_wait_ev(h, "child_got_signal", 5_000)
	ck(t, "the child still exited on 40+SIGINT regardless of what the app did",
		hh_ev_is(fm, "child_got_signal", 2),
		fmt.tprintf("child_got_signal={}", hh_ev_str(fm, "child_got_signal")))
	// The user's terminal is still fine: tb_shutdown had already put it back
	// before the fork, and the app died at the mask restore, before re-acquiring.
	same, detail := hh_termios_round_trip(h)
	ck(t, "the terminal still round-trips in the default-disposition case", same, detail)
}

// ─────────────────────────────────────────────────────────────────────────────
// old 224 + 250 — SIGTERM / SIGHUP while in the alt screen.
//
// termbox2 installs only SIGWINCH. Putting the terminal back on a termination
// signal is the product's OWN handler, so the suite parks the app in the alt
// screen, signals it, and checks the three things that matter to the human at
// the other end of the ssh connection: the exit status is what a shell would
// report, the alt screen was left, and the line discipline is back.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
handoff_sigterm_and_sighup_restore_the_terminal :: proc(t: ^testing.T) {
	hh_restore_signal_case(t, "TERM", 143)
	hh_restore_signal_case(t, "HUP", 129)
}

hh_restore_signal_case :: proc(t: ^testing.T, sig_name: string, expect: int) {
	sig := posix.Signal.SIGTERM
	if sig_name == "HUP" { sig = posix.Signal.SIGHUP }

	h, err := hh_begin(fmt.tprintf("sig-{}", sig_name), "sig-term", {})
	if err != "" {
		ck(t, fmt.tprintf("SIG{} case: the app spawned on a pty", sig_name), false, err)
		return
	}
	defer hh_finish(h)

	_, ok := hh_wait_ev(h, "parked", 20_000)
	if !ok {
		ck(t, fmt.tprintf("SIG{} case: the app parked in the alt screen", sig_name), false,
			fmt.tprintf("never saw parked; {}", hh_exit_info(h)))
		return
	}
	// ANTI-VACUITY: if the terminal was never raw, "termios unchanged" below
	// is true of an app that never took the screen. Check it while the app is
	// parked.
	mid, mid_ok := pty.pty_termios_now(h.d)
	ck(t, fmt.tprintf("SIG{} case: the terminal was actually taken before the signal", sig_name),
		mid_ok && hh_termios_is_raw(mid),
		fmt.tprintf("tcgetattr_ok={} raw={}", mid_ok, hh_termios_is_raw(mid)))
	// Drain the paint before signalling, so the bytes we later attribute to
	// the handler are only the handler's.
	hh_pump(h, 250)

	pty.pty_kill(h.d, sig)
	hh_wait_exit(h, 15_000)
	hh_pump(h, 250)

	info := hh_exit_info(h)
	// pty_exit_info renders "exit=143 (killed by signal 15)": the 128+sig
	// convention is decoded, not the raw status. Assert the number, not the
	// shape, so a change in the driver's wording cannot hide a wrong code.
	ck(t, fmt.tprintf("SIG{} exits {} as the shell would", sig_name, expect),
		contains_i(info, fmt.tprintf("exit={}", expect)),
		fmt.tprintf("exit info='{}' want exit={}", info, expect))

	leaves := hh_raw_count(h, HH_ALT_LEAVE)
	ck(t, fmt.tprintf("SIG{} leaves the alternate screen", sig_name),
		leaves >= 1,
		fmt.tprintf("alt-screen-leave sequences={}", leaves))

	same, detail := hh_termios_round_trip(h)
	ck(t, fmt.tprintf("SIG{} leaves termios unchanged", sig_name), same, detail)
}

// contains_i — a plain substring test, so a detail string cannot accidentally
// "contain" the expected value by being empty or by unicode-shenanigans.
contains_i :: proc(hay, needle: string) -> bool {
	if len(needle) == 0 { return false }
	if len(hay) < len(needle) { return false }
	i := 0
	for i + len(needle) <= len(hay) {
		match := true
		for j := 0; j < len(needle); j += 1 {
			if hay[i+j] != needle[j] { match = false; break }
		}
		if match { return true }
		i += 1
	}
	return false
}
