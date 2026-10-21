package pty

// ─────────────────────────────────────────────────────────────────────────────
// ffi.odin — the pty primitives `core:sys/posix` does not provide.
//
// VERIFIED ABSENT from the SDK (`core/sys/posix/*.odin`, dev-2026-10 store path
// 4ycdn03zvpadrpwb7c43gnr0gr23k597): `openpty`, `forkpty`, and `ioctl`. They
// are not "hidden behind a different name" — `grep` over the whole package finds
// none of them. So they are declared by hand against libc, following the one
// precedent in this repo: `src/ui_cases.odin:340-354` declares `Win_Size` +
// `TIOCSWINSZ` + a `foreign odin_c { ioctl ... }` block to shrink a live tty.
//
// WHY `system:c` AND NOT A FOREIGN ARCHIVE
//   These are libc symbols, not a bundled library, so `foreign import odin_c
//   "system:c"` is the correct form: the linker resolves them from the same
//   libc every other part of the binary already uses. Verified on this toolchain:
//       openpty rc=0 master=3 slave=4
//       ioctl(fd, TIOCSWINSZ, &winsize) rc=0
//       ioctl(fd, TIOCGWINSZ, &winsize) rc=0   → 33x111 read back
//       tcgetattr(fd, &t) rc=OK               (core:sys/posix, unchanged)
//
// THE ONE NON-OBVIOUS BINDING RULE
//   A C symbol may be bound by a renamed Odin procedure ONLY via
//   `@(link_name="…")`. The `--- "name"` suffix form written in the planning
//   notes is a SYNTAX ERROR in this Odin, and worse, TWO procedures cannot both
//   bind `ioctl` with DIFFERENT signatures:
//       Error: Redeclaration of foreign procedure 'ioctl' with different type
//              signatures
//   (Hit directly while writing this file: an `ioctl_ws(.. ^Win_Size)` and an
//   `ioctl_int(.. c.int)` pair both pointing at `ioctl` will not compile.)
//   The fix is ONE binding with the arg as `rawptr`, which is what C's
//   variadic `ioctl(int, unsigned long, ...)` actually is. `&ws` and `nil` both
//   pass through it correctly.
//
// WHY EACH REQUEST CONSTANT IS HERE
//   TIOCSWINSZ (0x5414)  set the window size. On the SLAVE before spawn it
//                        fixes the geometry the app inherits; on the MASTER it
//                        is what makes the kernel deliver SIGWINCH to the
//                        foreground pgroup — i.e. this one request IS "the user
//                        dragged the window" as far as termbox is concerned.
//   TIOCGWINSZ (0x5413)  read the size back. Bound because an assertion that
//                        TIOCSWINSZ "worked" without reading the kernel's copy
//                        back is asserting nothing about the kernel.
//   TIOCSCTTY  (0x540E)  make this fd the CALLING SESSION'S controlling
//                        terminal. This is the reason the child must do it
//                        itself after `setsid()` and before `dup2`: without a
//                        controlling terminal the app's SIGWINCH never arrives,
//                        and `isatty()`/termbox init behaves as if there were
//                        no tty at all. It must NOT be done in the parent —
//                        which is why it is proven in a forked child in
//                        ffi_test.odin, and not by a call from the test thread.
//
// WHAT IS *NOT* REIMPLEMENTED HERE, on purpose — `core:sys/posix` already has
// all of it, and hand-rolling a second copy of a symbol the SDK exports is how
// two definitions of "fork" end up in one binary:
//   fork (unistd.odin:338), setsid (819), dup2 (181), execve (290),
//   waitpid / WIFEXITED / WEXITSTATUS / WIFSIGNALED / WTERMSIG
//     (sys_wait.odin:92-108), tcgetattr / tcsetattr / tcgetsid
//     (termios.odin:69,92,78), poll (poll.odin:25), kill (signal.odin:29).
// ─────────────────────────────────────────────────────────────────────────────

import "core:c"
import "core:fmt"
import "core:sys/posix"

// Win_Size mirrors `struct winsize` (termios.h): four `unsigned short`.
// Field ORDER AND WIDTH ARE THE ABI — a reordered or widened field here does not
// fail to compile, it silently writes the window size into the wrong slots and
// the app reports a terminal geometry nobody asked for.
Win_Size :: struct {
	rows   : u16, // ws_row
	cols   : u16, // ws_col
	xpixel : u16, // ws_xpixel — unused by termbox, must still be present
	ypixel : u16, // ws_ypixel
}

TIOCSWINSZ : c.ulong = 0x5414 // set window size
TIOCGWINSZ : c.ulong = 0x5413 // get window size
TIOCSCTTY  : c.ulong = 0x540E // acquire as controlling tty (session leader only)

foreign import odin_c "system:c"

@(default_calling_convention = "c")
foreign odin_c {
	// openpty(master, slave, name, termp, winp)
	//   Any of name/termp/winp may be NULL. NULL `name` means we never learn a
	//   `/dev/pts/N` path; that is fine here because every operation in this
	//   harness goes through the fd, never through the path — and it avoids
	//   `ptsname()`'s static buffer, which is not thread-safe and this suite may
	//   later run under a threaded runner.
	openpty :: proc(master: ^c.int, slave: ^c.int, name: ^c.char,
	              termp: ^posix.termios, winp: ^Win_Size) -> c.int ---

	// forkpty(slave, name, termp, winp) — fork AND allocate in one step.
	// Returns the child pid in the parent, 0 in the child, -1 on failure.
	// Declared because the driver may want it; NOT used for the SIGTERM/termios
	// proof, because that proof requires the PARENT to keep the slave open, and
	// forkpty closes the slave in the parent by design. Anything that needs to
	// `tcgetattr` the tty after the child dies must use openpty + fork.
	forkpty :: proc(amaster: ^c.int, name: ^c.char, termp: ^posix.termios,
	              winp: ^Win_Size) -> c.int ---

	// ioctl, bound once. `rawptr` for the third argument mirrors C's variadic
	// third argument. See the header: two differently-typed `ioctl` bindings do
	// not compile in this Odin.
	@(link_name="ioctl")
	ioctl :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
}

// ─────────────────────────────────────────────────────────────────────────────
// Thin, checked wrappers
// ─────────────────────────────────────────────────────────────────────────────

// Pty_Pair is an allocated pseudo-terminal. BOTH ENDS ARE HELD IN THE PARENT ON
// PURPOSE. Losing the slave is the classic way to lose the whole post-mortem:
// once every slave fd is closed the line discipline goes away and `tcgetattr`
// on the master reports ENOTTY, so "did the app put the terminal back?" stops
// being answerable exactly at the moment it is asked.
Pty_Pair :: struct {
	master : posix.FD,
	slave  : posix.FD,
	rows   : i32,
	cols   : i32,
	valid  : bool,
}

// open_pty allocates a pair and fixes the geometry on the SLAVE before anyone
// inherits it. The geometry is set on the slave rather than the master because
// the SLAVE is the terminal the app sees; setting it on the master first and
// reading it back off the slave is the round trip that proves the two ends are
// genuinely one kernel tty object.
open_pty :: proc(rows, cols: i32) -> Pty_Pair {
	p : Pty_Pair = {}
	m, s : c.int = -1, -1
	ws := Win_Size{
		rows   = u16(rows),
		cols   = u16(cols),
		xpixel = 0,
		ypixel = 0,
	}
	rc := openpty(&m, &s, nil, nil, &ws)
	if rc != 0 {
		fmt.eprintfln("[HS] openpty failed rc={} errno={}", rc, posix.errno())
		return p
	}
	p.master = posix.FD(m)
	p.slave = posix.FD(s)
	p.rows = rows
	p.cols = cols
	p.valid = true
	return p
}

// set_winsize is the one call that produces a SIGWINCH in the child's fg pgroup.
// Returns the raw rc so the caller can assert on it; a bare `bool` would hide
// errno, and errno is the difference between "not supported" and "wrong fd".
set_winsize :: proc(fd: posix.FD, rows, cols: i32) -> c.int {
	ws := Win_Size{
		rows   = u16(rows),
		cols   = u16(cols),
		xpixel = 0,
		ypixel = 0,
	}
	return ioctl(c.int(fd), TIOCSWINSZ, &ws)
}

// get_winsize reads the KERNEL'S copy of the geometry. This is what makes a
// "we resized it" claim falsifiable rather than a log line.
get_winsize :: proc(fd: posix.FD) -> (Win_Size, c.int) {
	ws : Win_Size = {}
	rc := ioctl(c.int(fd), TIOCGWINSZ, &ws)
	if rc != 0 {
		return Win_Size{}, rc
	}
	return ws, rc
}

// acquire_controlling_terminal: TIOCSCTTY with arg 0.
//
// MUST be called in the child, after setsid(), before dup2/execve. As the
// session leader the child owns the new session and the kernel allows the
// handover; called from any other position it fails, and failing here produces
// an app that runs with no controlling tty — which silently degrades into
// "resize does nothing" rather than an error anyone sees.
acquire_controlling_terminal :: proc(fd: posix.FD) -> c.int {
	return ioctl(c.int(fd), TIOCSCTTY, nil)
}

// errno_name renders the current errno without importing the whole error table
// into every caller's format string.
errno_name :: proc() -> string {
	e := posix.errno()
	if e == posix.Errno.NONE { return "NONE" }
	return fmt.tprintf("{}({})", e, i32(e))
}
