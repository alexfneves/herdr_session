package termhandoff

// The leave → exec → wait → re-enter sequence from plan §Terminal handoff.
//
// This is the single highest-risk assumption in the project (plan risk A1): our TUI
// and the child (eventually `herdr session attach`) share ONE alternate buffer, so
// the terminal has to be handed over and taken back cleanly. The sequence, each
// step verified against the pinned termbox2 source:
//
//   1. stop rendering            (caller's contract — see the note below)
//   2. tb_shutdown()             SGR0 + CLEAR + leave ?1049 + exit keypad/mouse
//                                + restore original termios + SIGWINCH → SIG_DFL
//                                (tb_deinit, termbox2.h:3188-3212)
//   3. fork/exec the child       INHERITED stdio, SAME foreground process group,
//                                NO setsid (the child needs our controlling tty),
//                                child cwd set explicitly, HERDR_* scrubbed
//   4. block SIGINT/SIGQUIT; waitpid()
//                                NOT self-SIGSTOP: a self-stopped process is not
//                                resumed by its child's SIGCHLD
//   5. tb_init()                 reopens /dev/tty, tb_reset(), re-enters alt screen
//                                (tb_init_rwfd, termbox2.h:2364-2387)
//   6. FORCE a full repaint      never trust inherited screen state — the child may
//                                have died mid-paint (the panic path skips resets)
//
// Step 1 belongs to the caller: the event loop must stop rendering before calling
// handoff_run, so there is no frame in flight to race with. Steps 2-6 live here so
// the handoff has exactly one implementation that can be right or wrong.

import termbox2 "../../vendor/termbox2-odin"

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"

// HANDOFF_SIGNALS are the signals the handoff owns. Ctrl-C/Ctrl-\ on the tty are
// delivered to the WHOLE foreground process group, so we block them for the child's
// entire lifetime (only the child should see them) and explicitly clear them again
// for the child, or it would start life with Ctrl-C disabled.
HANDOFF_SIGNALS :: [2]posix.Signal{.SIGINT, .SIGQUIT}

// Repaint is installed by the app with set_full_repaint. It must paint a complete
// frame from scratch (Clay layout re-describe → renderer → tb_present) and must
// not depend on anything the child left on screen.
Repaint :: proc()

// full_repaint is invoked after the terminal is re-acquired. Plan step 6 is a rule,
// not a suggestion, so it is enforced here instead of being left to each caller.
full_repaint : Repaint = nil

// set_full_repaint registers the painter used after every handoff.
set_full_repaint :: proc(f: Repaint) {
	full_repaint = f
}

Handoff :: struct {
	// exit is the child's exit code. A child killed by an uncaught signal reports
	// the shell convention 128+signum; `killed_by` carries the raw signal number.
	exit      : i32,
	killed_by : i32, // 0 unless the child died from a signal

	// ok is true only if we got the terminal back (tb_init succeeded) — i.e. the
	// user is not stranded on a half-restored screen.
	ok : bool,
	// err is the tb_init() return code when ok is false (TB_OK otherwise).
	err : i32,
}

// handoff_run releases the terminal, runs `argv` with inherited stdio in our own
// foreground process group, waits for it, then re-enters the alternate screen and
// forces a full repaint.
//
// `cwd` is set explicitly on the child because a session herdr creates takes the
// spawner's cwd as its identity_cwd — an accidental inherit here is a permanent
// property of the created session.
//
// Everything the child needs is prepared BEFORE the fork: the child path performs
// no allocation, which is the only reason it is safe to run after fork().
handoff_run :: proc(argv: []string, cwd: string) -> Handoff {
	if len(argv) == 0 {
		return Handoff{exit = 127, killed_by = 0, ok = false, err = termbox2.TB_ERR}
	}

	// ---- prepare the child (allocating; parent only) ----
	prog := resolve_program(argv[0])
	if prog == nil {
		fmt.eprintf("herdr-session: cannot resolve %s\n", argv[0])
		return Handoff{exit = 127, killed_by = 0, ok = false, err = termbox2.TB_ERR}
	}
	child_argv := build_argv(argv)
	child_env := build_scrubbed_env()
	child_cwd := cstr(cwd)

	// ---- step 2: release the terminal ----
	// tb_shutdown writes SGR0 / CLEAR / ?1049l / exit-keypad / exit-mouse and
	// restores the termios it captured at init, so the shell behaves as if we were
	// never here.
	if rv := termbox2.tb_shutdown(); rv != termbox2.TB_OK {
		// TB_ERR_NOT_INIT just means we never owned the screen; nothing to restore.
		fmt.eprintf("herdr-session: tb_shutdown -> %s\n", termbox2.tb_strerror(rv))
	}

	// A stack copy of the constant set: constants are not addressable, and this copy
	// is what both the parent's mask call and the child's un-block use.
	owned := HANDOFF_SIGNALS

	// ---- step 4a: block SIGINT/SIGQUIT before forking ----
	// Ctrl-C on the tty is delivered to the WHOLE foreground process group.
	// Blocking it here means only the child sees it, which is what the user wants
	// while an attached session owns the screen. The child clears these bits itself
	// (see child_pre_exec) or it would start life with Ctrl-C disabled.
	//
	// Explicitly NOT a self-SIGSTOP: a process stopped with SIGSTOP is not woken by
	// its own child's SIGCHLD, so the classic "stop while the child owns the tty"
	// trick hangs us until the user notices.
	saved := block_signals(owned[:])

	// ---- step 3: fork ----
	pid := posix.fork()
	if pid < 0 {
		restore_signals(saved)
		fmt.eprintf("herdr-session: fork failed: %v\n", posix.errno())
		return Handoff{exit = 127, killed_by = 0, ok = reacquire_terminal() == termbox2.TB_OK, err = termbox2.TB_ERR}
	}
	if pid == 0 {
		// The child. Nothing from here on may allocate.
		child_pre_exec(child_cwd, owned[:])
		posix.execve(prog, child_argv, child_env)
		// exec failed (ENOENT / EACCES / …). 127 is the shell's "not found".
		posix._exit(127)
	}

	// ---- step 4b: wait for the child ----
	// SIGINT/SIGQUIT stay blocked across the whole wait; EINTR just loops.
	status: c.int = 0
	for {
		r := posix.waitpid(pid, &status, {})
		if r < 0 {
			if posix.errno() == posix.Errno.EINTR { continue }
			restore_signals(saved)
			fmt.eprintf("herdr-session: waitpid failed: %v\n", posix.errno())
			return Handoff{exit = 127, killed_by = 0, ok = reacquire_terminal() == termbox2.TB_OK, err = termbox2.TB_ERR}
		}
		break
	}
	restore_signals(saved)

	res := Handoff{exit = exit_code(status), killed_by = term_signal(status)}

	// ---- steps 5+6: re-acquire the terminal, then force a full repaint ----
	res.err = reacquire_terminal()
	if res.err != termbox2.TB_OK {
		// The screen may be in an unknown state. Say so loudly — plan §Failure
		// modes 4: never leave the user without a way out.
		fmt.eprintf("herdr-session: could not re-enter the terminal (%s). "+
			"Run `reset` if the display looks wrong.\n", termbox2.tb_strerror(res.err))
		return res
	}
	res.ok = true

	if full_repaint != nil {
		full_repaint()
	}

	return res
}

// reacquire_terminal re-enters the alternate screen after a handoff.
// Returns TB_OK, or the tb_init() error code.
reacquire_terminal :: proc() -> i32 {
	rv := termbox2.tb_init()
	if rv != termbox2.TB_OK {
		return rv
	}
	// A fresh init resets the output mode to TB_OUTPUT_NORMAL and shows the cursor,
	// so both are re-asserted on every entry, never assumed.
	#assert(termbox2.OUTPUT_TRUECOLOR == 5, "truecolor must be selected after every re-init")
	termbox2.tb_set_output_mode(termbox2.OUTPUT_TRUECOLOR)
	termbox2.tb_hide_cursor()
	// Belt and braces for step 6: dropping the front buffer guarantees the next
	// tb_present repaints every cell even if the child scribbled over the screen.
	termbox2.tb_invalidate()
	termbox2.tb_present()
	return termbox2.TB_OK
}

//-----------------------------------------------------------------------------
// Child construction
//-----------------------------------------------------------------------------

// child_pre_exec is the child's short run between fork() and execve(). It must not
// allocate, must not format, and must not touch Odin runtime state.
//
// NO setsid(): the child needs our controlling tty to render at all, and it must
// stay in our foreground process group so tty input — above all Ctrl-C — reaches
// it the way the user expects.
child_pre_exec :: proc(cwd: cstring, clear: []posix.Signal) {
	if cwd != nil {
		posix.chdir(cwd)
	}
	// We blocked these in the parent before forking so that no signal can land in
	// the gap between fork and exec. Clear them again for the child.
	set := make_sigset(clear)
	posix.sigprocmask(.UNBLOCK, &set, nil)
}

// build_argv turns argv into a NULL-terminated C array.
build_argv :: proc(argv: []string) -> [^]cstring {
	out := make([dynamic]cstring, len(argv) + 1)
	for s, i in argv {
		out[i] = cstr(s)
	}
	out[len(argv)] = nil
	return &out[0]
}

// HERDR_NAMESPACE is the environment namespace herdr owns.
//
// Plan §Verbatim rules 1: the *presence* of HERDR_ENV is what makes herdr refuse a
// nested create/attach — setting it to 0 is not a bypass. The whole namespace goes
// wholesale, because an inherited HERDR_SOCKET_PATH / HERDR_CLIENT_SOCKET_PATH
// could otherwise point a child straight at *this* live session.
//
// TERM and COLORTERM are deliberately untouched: dropping them downgrades herdr's
// child rendering from SemanticFrame to TerminalAnsi.
HERDR_NAMESPACE :: "HERDR_"

// build_scrubbed_env produces our environment minus every HERDR_* variable as a
// NULL-terminated C array ready for execve().
build_scrubbed_env :: proc() -> [^]cstring {
	env, err := os.environ(context.allocator)
	if err != nil {
		fmt.eprintf("herdr-session: cannot read the environment: %v\n", err)
	}

	kept := make([dynamic]cstring, 0, len(env) + 1)
	for entry in env {
		eq := strings.index(entry, "=")
		if eq < 0 { continue }
		if strings.has_prefix(entry[:eq], HERDR_NAMESPACE) { continue }
		append(&kept, cstr(entry))
	}
	append(&kept, nil)
	return &kept[0]
}

// resolve_program finds the executable for `name` using execvp()'s PATH rules, but
// resolved in the parent so the child has nothing to do after the fork.
// We cannot use execvp() itself: it searches PATH using the *inherited* environ,
// not our scrubbed array, which would defeat the whole point.
// Returns nil when not found.
resolve_program :: proc(name: string) -> cstring {
	if name == "" { return nil }

	// An explicit path is used verbatim (and must be executable).
	if strings.contains(name, "/") {
		return executable_or_nil(name)
	}

	path := os.get_env_alloc("PATH", context.allocator)
	if path == "" { return nil }
	for &dir in strings.split(path, ":") {
		if dir == "" { dir = "." }
		full := strings.concatenate({dir, "/", name}, context.allocator)
		if p := executable_or_nil(full); p != nil {
			return p
		}
	}
	return nil
}

executable_or_nil :: proc(path: string) -> cstring {
	p := cstr(path)
	if posix.access(p, {.X_OK}) != nil {
		return nil
	}
	return p
}

//-----------------------------------------------------------------------------
// Signal helpers
//-----------------------------------------------------------------------------

make_sigset :: proc(sigs: []posix.Signal) -> posix.sigset_t {
	set: posix.sigset_t = {}
	posix.sigemptyset(&set)
	for s in sigs {
		posix.sigaddset(&set, s)
	}
	return set
}

// block_signals adds `sigs` to the process mask and returns the mask as it was before.
block_signals :: proc(sigs: []posix.Signal) -> posix.sigset_t {
	set := make_sigset(sigs)
	old: posix.sigset_t = {}
	posix.sigprocmask(.BLOCK, &set, &old)
	return old
}

restore_signals :: proc(old: posix.sigset_t) {
	// `old` is by value; take the address of a local copy.
	current := old
	posix.sigprocmask(.SETMASK, &current, nil)
}

install_terminal_restore_handlers :: proc() {
	posix.signal(posix.Signal.SIGTERM, on_terminal_signal)
	posix.signal(posix.Signal.SIGHUP, on_terminal_signal)
}

// on_terminal_signal puts the terminal back before dying.
//
// termbox2 installs ONLY SIGWINCH — restoring the screen on SIGTERM/SIGHUP is ours
// to add (plan D8). tb_shutdown is not strictly async-signal-safe, but the
// alternative (a mangled terminal for the rest of the user's session) is worse,
// and the handler does nothing but flush the tty and restore termios.
//
// proc "c" has no Odin context: no allocation and no fmt inside.
on_terminal_signal :: proc "c" (sig: posix.Signal) {
	termbox2.tb_shutdown()
	// Re-raise with the default disposition so our own exit status reflects the signal.
	posix.signal(sig, auto_cast posix.SIG_DFL)
	posix.raise(sig)
}

//-----------------------------------------------------------------------------
// Exit status decoding
//-----------------------------------------------------------------------------

exit_code :: proc(status: c.int) -> i32 {
	if posix.WIFEXITED(status) {
		return i32(posix.WEXITSTATUS(status))
	}
	if posix.WIFSIGNALED(status) {
		return 128 + i32(posix.WTERMSIG(status))
	}
	return -1
}

term_signal :: proc(status: c.int) -> i32 {
	if posix.WIFSIGNALED(status) {
		return i32(posix.WTERMSIG(status))
	}
	return 0
}

//-----------------------------------------------------------------------------
// String helper
//-----------------------------------------------------------------------------

// cstr copies s into a NUL-terminated allocation owned by the ambient allocator.
cstr :: proc(s: string) -> cstring {
	buf := make([]byte, len(s) + 1)
	mem.copy(&buf[0], raw_data(s), len(s))
	buf[len(s)] = 0
	return cstring(&buf[0])
}
