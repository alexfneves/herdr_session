package hscheck

import "core:mem"
import "core:os"
import "core:c"
import "core:sys/posix"

// run.odin — spawn one suite binary, capture its streams SEPARATELY.
//
// Separate capture is not a nicety. Rule 9 of the migration is "no log
// concatenation": a later case must never inherit an earlier case's PASS lines.
// Merging stdout and stderr into one fd is the classic way that happens, and it
// also makes the `[HS]` assertion count fragile (interleaving can split a line).
// So: stdout -> <suite>.out.log, stderr -> <suite>.err.log, and both are scanned.

// spawn_and_capture runs `binary` with `env` (a list of "K=V"), writing the
// child's stdout/stderr to `out_log`/`err_log`. Returns the exit code, or -1 if
// the child could not be started.
// SpawnResult distinguishes the three ways a suite can end. Collapsing these
// into an exit code is what let a hang look like "the gate is thinking".
SpawnResult :: struct {
	exit      : i32,     // child's exit status, or -1 if it could not be started
	started   : bool,
	timed_out : bool,
	elapsed_ms : i64,
	killed    : bool,    // we had to SIGKILL it
}

// spawn_and_capture runs `binary` with `env`, writing the child's
// stdout/stderr to `out_log`/`err_log`, and waits AT MOST `timeout_ms`.
//
// THE TIMEOUT IS THE WHOLE POINT. The previous implementation called
// waitpid() with no bound. A suite that blocked -- waiting on a child it
// never reaped, on a tty, on a network read -- blocked the gate forever, and
// CI went silent. A gate that hangs is worse than a gate that is wrong:
// a wrong gate at least tells you something. This one converts "no output for
// 300 seconds and a red X nobody can explain" into a named, timed failure.
//
// The child is put in its OWN PROCESS GROUP before exec so that killing the
// group also takes the grandchildren. Killing only the direct child is how a
// hung grandchild from an offline-window test survives the gate's exit and
// leaks onto the machine.
spawn_and_capture :: proc(binary, out_log, err_log: string, env: []string, timeout_ms: i64) -> SpawnResult {
	c_bin := to_cstring(binary, context.temp_allocator)
	c_out := to_cstring(out_log, context.temp_allocator)
	c_err := to_cstring(err_log, context.temp_allocator)

	res : SpawnResult = {}

	mode := posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH}
	flags := posix.O_Flags{.WRONLY, .CREAT, .TRUNC}
	out_fd := posix.open(c_out, flags, mode)
	if out_fd < 0 { return res }
	err_fd := posix.open(c_err, flags, mode)
	if err_fd < 0 {
		posix.close(out_fd)
		return res
	}

	// argv/envp are built BEFORE the fork. The child must not allocate: it is a
	// copy of the gate's heap about to become a different program, and an
	// allocation there after exec is a corruption, not a mistake. A [^]cstring
	// also has no backing memory until something gives it one, so the dynamic
	// arrays below are what actually own the bytes.
	argv_dyn : [dynamic]cstring = {}
	append(&argv_dyn, c_bin)
	append(&argv_dyn, nil)
	c_envp := build_envp(env, context.temp_allocator)

	pid := posix.fork()
	if pid < 0 {
		posix.close(out_fd)
		posix.close(err_fd)
		return res
	}
	if pid == 0 {
		// Child. New process group FIRST: before anything can spawn under us, so
		// the group already owns every descendant when the parent decides to
		// kill it.
		posix.setpgid(0, 0)
		posix.dup2(out_fd, posix.STDOUT_FILENO)
		posix.dup2(err_fd, posix.STDERR_FILENO)
		posix.close(out_fd)
		posix.close(err_fd)
		posix.execve(c_bin, cast([^]cstring)(&argv_dyn[0]), c_envp)
		// exec failed. Say so on the captured stream and leave with 127 so the
		// gate reports "could not run" rather than silently scoring nothing.
		msg := "HS: exec failed\n"
		posix.write(posix.STDERR_FILENO, raw_data(msg), c.size_t(len(msg)))
		os.exit(127)
	}

	posix.close(out_fd)
	posix.close(err_fd)
	res.started = true

	// Belt and braces: the parent also sets the child's group, because the
	// child's own setpgid races with this one. Either succeeding is enough;
	// EACCES/ESRCH from the loser is expected and ignored.
	posix.setpgid(pid, pid)

	start := posix_clock_ms()
	deadline := start + timeout_ms
	status : c.int = 0
	for {
		got := posix.waitpid(pid, &status, posix.Wait_Flags{.NOHANG})
		if got == pid { break }
		if got < 0 { res.exit = -1; return res }
		now := posix_clock_ms()
		res.elapsed_ms = now - start
		if now >= deadline {
			res.timed_out = true
			// TERM first so the child can run cleanup and release the tty, then
			// KILL the whole group. Wait briefly between the two so a cooperative
			// child is not cut off mid-teardown, and a stubborn one still dies.
			posix.killpg(pid, posix.Signal.SIGTERM)
			grace := posix_clock_ms() + 2000
			for posix_clock_ms() < grace {
				g2 := posix.waitpid(pid, &status, posix.Wait_Flags{.NOHANG})
				if g2 == pid { break }
				usleep_local(50_000)
			}
			if posix.waitpid(pid, &status, posix.Wait_Flags{.NOHANG}) != pid {
				posix.killpg(pid, posix.Signal.SIGKILL)
				res.killed = true
				posix.waitpid(pid, &status, {})
			}
			res.elapsed_ms = posix_clock_ms() - start
			res.exit = 124
			return res
		}
		usleep_local(20_000)
	}

	res.elapsed_ms = posix_clock_ms() - start
	if posix.WIFEXITED(status) { res.exit = i32(posix.WEXITSTATUS(status)) }
	else if posix.WIFSIGNALED(status) { res.exit = -i32(posix.WTERMSIG(status)) }
	else { res.exit = -1 }
	return res
}

// posix_clock_ms uses CLOCK_MONOTONIC. Wall-clock time is not acceptable for a
// timeout: an NTP step or a suspend makes a suite look like it ran for hours
// or no time at all.
posix_clock_ms :: proc() -> i64 {
	ts : posix.timespec = {}
	// CLOCK_MONOTONIC: immune to clock_settime and to NTP slew.
	posix.clock_gettime(posix.Clock.MONOTONIC, &ts)
	return i64(ts.tv_sec) * 1000 + i64(ts.tv_nsec) / 1_000_000
}

usleep_local :: proc(us: i64) {
	ts := posix.timespec{
		tv_sec  = posix.time_t(us / 1_000_000),
		tv_nsec = i64((us % 1_000_000) * 1000),
	}
	posix.nanosleep(&ts, nil)
}

build_envp :: proc(env: []string, alloc: mem.Allocator) -> [^]cstring {
	// Null-terminated, the way execve wants it. Same pre-fork rule as argv.
	dyn : [dynamic]string = {}
	for e in env { append(&dyn, e) }
	out : [dynamic]cstring = {}
	for s in dyn {
		append(&out, to_cstring(s, alloc))
	}
	append(&out, nil)
	return cast([^]cstring)(&out[0])
}

to_cstring :: proc(s: string, alloc: mem.Allocator) -> cstring {
	buf := make([]u8, len(s)+1, alloc)
	for i := 0; i < len(s); i += 1 { buf[i] = s[i] }
	buf[len(s)] = 0
	return cast(cstring)(&buf[0])
}

os_read_file :: proc(path: string) -> ([]byte, os.Error) {
	return os.read_entire_file_from_path(path, context.allocator)
}
