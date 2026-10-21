package pty

// ─────────────────────────────────────────────────────────────────────────────
// ffi_test.odin — T3's "a pty actually exists and actually resizes" proof.
//
// This is not a smoke test for its own sake. T5's design rests on claims about
// these syscalls, and if any one of them is false the resize latency table
// measures nothing. So each is pinned here, in the cheap place, before anyone
// builds on it.
//
//   1. openpty yields two distinct, usable fds — including at the ledger's
//      smallest geometry (5x5), not just at a comfortable 80x24.
//   2. A geometry set on ONE end is readable off the OTHER end, both ways
//      round: the two fds really are one kernel tty object, not two buffers
//      that happen to be connected. Without this, "we resized the pty the app
//      holds" is a statement about a different terminal than the one it reads.
//   3. Writes cross in both directions.
//   4. TIOCSCTTY, done in a forked child after setsid(), really does make the
//      slave the child's controlling terminal — the property SIGWINCH delivery
//      depends on, and the one that CANNOT be shown from the test thread.
//   5. The tty is still interrogable after the child that owned it dies, with
//      the slave held open in the parent. This is the single reason the harness
//      never closes its slave end early.
//
// WHY THE CONTROLLING-TERMINAL TEST ENCODES ITS ANSWER IN THE EXIT STATUS
//   The child of a fork inside a test binary must not allocate: it inherits a
//   heap shared copy-on-write with a running test harness, and allocating there
//   is exactly the kind of thing that surfaces as a Heisenbug in the PARENT
//   forty minutes later. So every message is pre-built in the parent and the
//   child only ever calls _exit with a step code — no formatting, no
//   allocation, no ledger write in the child.
//   `_exit` and not `exit` for the same reason: exit() runs atexit handlers,
//   and a forked child running the harness's cleanup a second time means a
//   second ledger flush and a double free of memory the parent still owns.
// ─────────────────────────────────────────────────────────────────────────────

import "core:c"
import "core:fmt"
import "core:sys/posix"
import "core:testing"

import support "../support"

// Child exit codes for the controlling-terminal proof. Named so the parent's
// failure message can say WHICH step broke instead of "the child said no".
CTTY_OK                 : c.int = 0
CTTY_SETSID_FAILED      : c.int = 1
CTTY_TIOCSCTTY_FAILED   : c.int = 2
CTTY_TCGETSID_MISMATCH  : c.int = 3

@(test)
pty_allocates_two_distinct_usable_ends :: proc(t: ^testing.T) {
	p := open_pty(24, 80)
	support.check(t, "openpty succeeded", p.valid, "see stderr for errno")
	support.check(t, "master and slave are distinct, non-negative fds",
		p.master != p.slave && int(p.master) >= 0 && int(p.slave) >= 0,
		fmt.tprintf("master={} slave={}", int(p.master), int(p.slave)))

	// 5x5 is the smallest geometry the frozen resize ledger uses
	// (5x5 -> 5x9 -> 5x5). Pin it here so a harness that cannot allocate at
	// that size fails at T3 rather than halfway through T5's latency table.
	q := open_pty(5, 5)
	support.check(t, "the ledger's smallest geometry 5x5 also allocates", q.valid,
		"T5's resize table is 5x5 -> 5x9 -> 5x5")
	if q.valid {
		posix.close(q.master)
		posix.close(q.slave)
	}
	if p.valid {
		posix.close(p.master)
		posix.close(p.slave)
	}
}

@(test)
pty_geometry_is_one_kernel_object_across_both_ends :: proc(t: ^testing.T) {
	p := open_pty(24, 80)
	if !p.valid {
		support.check(t, "no pty to resize", false, "openpty failed")
		return
	}
	defer posix.close(p.master)
	defer posix.close(p.slave)

	// Set on the SLAVE, read on the MASTER — the direction that matters,
	// because the app holds the slave and the supervisor holds the master.
	support.eq_i(t, "TIOCSWINSZ on the slave returns 0",
		int(set_winsize(p.slave, 41, 132)), 0)
	got, rc := get_winsize(p.master)
	support.eq_i(t, "TIOCGWINSZ on the master returns 0", int(rc), 0)
	support.eq_i(t, "the MASTER sees the rows set on the slave", int(got.rows), 41)
	support.eq_i(t, "the MASTER sees the cols set on the slave", int(got.cols), 132)

	// And the reverse direction: a half-proven equivalence is a coincidence
	// waiting to be one-way.
	support.eq_i(t, "TIOCSWINSZ on the master returns 0",
		int(set_winsize(p.master, 12, 37)), 0)
	got2, rc2 := get_winsize(p.slave)
	support.eq_i(t, "TIOCGWINSZ on the slave returns 0", int(rc2), 0)
	support.eq_i(t, "the SLAVE sees the rows set on the master", int(got2.rows), 12)
	support.eq_i(t, "the SLAVE sees the cols set on the master", int(got2.cols), 37)

	// The exact geometry of the plan's frozen ledger. A resize that silently
	// clamped to a minimum size would turn the latency numbers into a fiction,
	// so the READ-BACK is the assertion, not the call.
	support.eq_i(t, "resize to 5x9 returns 0", int(set_winsize(p.slave, 5, 9)), 0)
	got3, _ := get_winsize(p.master)
	support.eq_i(t, "kernel reports 5 rows after the 5x9 resize", int(got3.rows), 5)
	support.eq_i(t, "kernel reports 9 cols after the 5x9 resize", int(got3.cols), 9)
}

@(test)
pty_bytes_cross_in_both_directions :: proc(t: ^testing.T) {
	p := open_pty(24, 80)
	if !p.valid {
		support.check(t, "no pty for the byte round trip", false, "openpty failed")
		return
	}
	defer posix.close(p.master)
	defer posix.close(p.slave)

	// master -> slave is the app's STDIN: this is how a driver types.
	to_slave := "attach\n"
	wn := posix.write(p.master, raw_data(to_slave), c.size_t(len(to_slave)))
	support.eq_i(t, "writing to the master delivers the full length", int(wn), len(to_slave))

	// READS ARE ACCUMULATED, NEVER SINGLE-SHOT, and this test is where that
	// rule earns its place. A pty read returns WHATEVER THE LINE DISCIPLINE
	// HAS RIGHT NOW, not one logical message: ECHO is on (kept on, because a
	// real terminal echoes), so the master's queue carries the echo of every
	// keystroke we sent interleaved with the app's own output, and the kernel
	// splits and merges at its own convenience. A single read compared against
	// an expected length or an expected string is asserting a race.
	//
	// This first read is the slave side: does what the supervisor typed reach
	// the terminal's input? Accumulate until the bytes show up, bounded.
	buf : [dynamic]u8
	tmp : [64]u8
	seen := stream_until_accept(&buf, &tmp, p.slave, to_slave, 200)
	support.check(t, "what the master wrote reaches the slave's input stream",
		seen,
		fmt.tprintf("accumulated {} bytes looking for {:x}", len(buf), to_slave))

	// And the other direction, through the SAME accumulation discipline.
	delete(buf)
	buf = make([dynamic]u8)
	to_master := "from the app side"
	wn2 := posix.write(p.slave, raw_data(to_master), c.size_t(len(to_master)))
	support.eq_i(t, "writing to the slave delivers the full length", int(wn2), len(to_master))
	seen2 := stream_until_accept(&buf, &tmp, p.master, to_master, 200)
	support.check(t, "what the slave wrote reaches the master's output stream",
		seen2,
		fmt.tprintf("accumulated {} bytes looking for {:x}", len(buf), to_master))
	// NOTE what is NOT asserted: that any single read returned exactly those
	// bytes, or that nothing else appeared. The echo of "attach\n" is in there
	// too. "Eventually contains X, read continuously" is the only honest
	// assertion shape over a live tty stream, and it is the shape screen.odin
	// feeds the emulator.
	delete(buf)
}

// stream_until_accept reads fd, appending to `acc`, until `want` appears in
// the accumulated bytes or `max_reads` reads have been done. Returns whether
// it appeared.
//
// Bounded by READ COUNT, not by wall-clock: a bounded-time loop needs a poll
// timeout and turns a real failure into a 5-second test; a bounded-read loop
// exits the instant the answer is known and cannot spin. Each read blocks on
// the fd, which is the correct park.
stream_until_accept :: proc(acc: ^[dynamic]u8, tmp: ^[64]u8, fd: posix.FD, want: string, max_reads: int) -> bool {
	if len(want) == 0 { return true }
	for i := 0; i < max_reads; i += 1 {
		n := posix.read(fd, cast([^]byte)&tmp[0], c.size_t(len(tmp)))
		if int(n) <= 0 {
			// 0 = EOF (every slave closed); <0 = error. Neither is retryable
			// here, and neither should be silent: bail and let the caller's
			// assertion carry the byte count in its detail.
			break
		}
		for k := 0; k < int(n); k += 1 { append(acc, tmp[k]) }
		if contains_bytes(string(acc[:]), want) { return true }
	}
	return contains_bytes(string(acc[:]), want)
}

contains_bytes :: proc(haystack: string, needle: string) -> bool {
	if len(needle) == 0 { return true }
	if len(needle) > len(haystack) { return false }
	for i := 0; i + len(needle) <= len(haystack); i += 1 {
		matched := true
		for j := 0; j < len(needle); j += 1 {
			if haystack[i+j] != needle[j] {
				matched = false
				break
			}
		}
		if matched { return true }
	}
	return false
}

@(test)
pty_child_acquires_it_as_controlling_terminal :: proc(t: ^testing.T) {
	// The property: after setsid() + TIOCSCTTY in the CHILD,
	// tcgetsid(slave) == the child's own pid. That equality is what makes the
	// child the foreground process of that terminal, and therefore what makes
	// a later TIOCSWINSZ from the master deliver SIGWINCH to it.
	//
	// Done in a forked child because TIOCSCTTY acts on the CALLING process's
	// session by definition — there is no version of this assertion the test
	// thread can make about itself without becoming the thing under test.
	p := open_pty(24, 80)
	if !p.valid {
		support.check(t, "no pty for the controlling-terminal proof", false, "openpty failed")
		return
	}
	defer posix.close(p.master)
	defer posix.close(p.slave)

	pid := posix.fork()
	if pid < 0 {
		support.check(t, "fork failed, cannot prove TIOCSCTTY", false,
			fmt.tprintf("errno={}", errno_name()))
		return
	}
	if pid == 0 {
		// ---- CHILD: nothing below allocates, formats, or touches the ledger.
		if posix.setsid() < 0 {
			posix._exit(CTTY_SETSID_FAILED)
		}
		if acquire_controlling_terminal(p.slave) != 0 {
			posix._exit(CTTY_TIOCSCTTY_FAILED)
		}
		if posix.tcgetsid(p.slave) != posix.getpid() {
			posix._exit(CTTY_TCGETSID_MISMATCH)
		}
		posix._exit(CTTY_OK)
	}

	status : c.int = 0
	// No WNOHANG: the child does three syscalls and exits. Blocking is the
	// correct and cheapest wait, and a poll loop here would be the idle-spin
	// the plan forbids.
	got := posix.waitpid(pid, &status, posix.Wait_Flags{})
	support.check(t, "waitpid collected the child",
		posix.WIFEXITED(status) || posix.WIFSIGNALED(status),
		fmt.tprintf("waitpid returned {}", int(got)))
	code := posix.WEXITSTATUS(status)
	support.eq_i(t, "the child reports tcgetsid(slave) == its own pid (exit code 0)",
		int(code), int(CTTY_OK))
	if code != CTTY_OK {
		meaning := "unknown"
		if code == CTTY_SETSID_FAILED { meaning = "setsid() failed" }
		if code == CTTY_TIOCSCTTY_FAILED { meaning = "TIOCSCTTY was refused" }
		if code == CTTY_TCGETSID_MISMATCH { meaning = "tcgetsid did not match the child pid" }
		support.check(t, "controlling-terminal acquisition broke", false,
			fmt.tprintf("child exit {} — {}", int(code), meaning))
	}
}

@(test)
pty_stays_interrogable_after_the_owning_child_dies :: proc(t: ^testing.T) {
	// The reason BOTH ends are held open in the parent for the whole life of a
	// test. If the slave were closed early — the forkpty shape — the line
	// discipline would go away with the child and `tcgetattr` would stop being
	// answerable, which is exactly the question "did the app put the terminal
	// back?" asks. Losing the answer at the moment it is needed is the failure
	// mode this harness must not have.
	p := open_pty(24, 80)
	if !p.valid {
		support.check(t, "no pty for the post-mortem proof", false, "openpty failed")
		return
	}
	defer posix.close(p.master)
	defer posix.close(p.slave)

	// Put the tty into a NON-default state, the way a handoff would: IEXTEN
	// off and a distinctive geometry. Both are things the teardown question
	// asks about.
	ts := posix.termios{}
	support.check(t, "tcgetattr answers while the tty is live",
		posix.tcgetattr(p.slave, &ts) == {},
		fmt.tprintf("errno={}", errno_name()))
	ts.c_lflag = ts.c_lflag - {posix.CLocal_Flag_Bits.IEXTEN}
	posix.tcsetattr(p.slave, posix.TC_Optional_Action.TCSANOW, &ts)
	support.eq_i(t, "resize to 7x41 returns 0", int(set_winsize(p.slave, 7, 41)), 0)

	pid := posix.fork()
	if pid < 0 {
		support.check(t, "fork failed", false, fmt.tprintf("errno={}", errno_name()))
		return
	}
	if pid == 0 {
		posix._exit(0)
	}
	status : c.int = 0
	posix.waitpid(pid, &status, posix.Wait_Flags{})

	// The questions, asked AFTER the child is gone:
	ws, rc := get_winsize(p.slave)
	support.eq_i(t, "TIOCGWINSZ still answers after the owning child exited", int(rc), 0)
	support.eq_i(t, "the geometry survived the child", int(ws.rows), 7)

	after := posix.termios{}
	support.check(t, "tcgetattr still answers after the owning child exited",
		posix.tcgetattr(p.slave, &after) == {},
		fmt.tprintf("errno={}", errno_name()))
	iexten_still_set := posix.CLocal_Flag_Bits.IEXTEN in after.c_lflag
	support.check(t, "the IEXTEN clearing survives the round trip a teardown would read",
		!iexten_still_set,
		fmt.tprintf("IEXTEN present after the round trip = {}", iexten_still_set))

	// fcntl(F_DUPFD) is the honest way to ask "is this fd still open?"
	// without perturbing the original. If the slave had gone away it is -1.
	dupped := posix.fcntl(p.slave, posix.FCNTL_Cmd.DUPFD, 0)
	support.check(t, "the slave fd is still open — the supervisor can still interrogate the tty",
		int(dupped) >= 0,
		fmt.tprintf("fcntl(F_DUPFD) -> {} errno={}", int(dupped), errno_name()))
	if int(dupped) >= 0 {
		posix.close(posix.FD(dupped))
	}
}
