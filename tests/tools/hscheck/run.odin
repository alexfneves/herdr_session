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
spawn_and_capture :: proc(binary, out_log, err_log: string, env: []string) -> i32 {
	c_bin := to_cstring(binary, context.temp_allocator)
	c_out := to_cstring(out_log, context.temp_allocator)
	c_err := to_cstring(err_log, context.temp_allocator)

	mode := posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH}
	flags := posix.O_Flags{.WRONLY, .CREAT, .TRUNC}
	out_fd := posix.open(c_out, flags, mode)
	if out_fd < 0 { return -1 }
	err_fd := posix.open(c_err, flags, mode)
	if err_fd < 0 {
		posix.close(out_fd)
		return -1
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
		return -1
	}
	if pid == 0 {
		// Child. Redirect, then exec. Nothing here may allocate: the child is a
		// copy of the gate's heap and is about to become a different program.
		posix.dup2(out_fd, posix.STDOUT_FILENO)
		posix.dup2(err_fd, posix.STDERR_FILENO)
		posix.close(out_fd)
		posix.close(err_fd)
		posix.execve(c_bin, transmute([^]cstring)(&argv_dyn[0]), c_envp)
		// exec failed. Say so on the captured stream and leave with 127 so the
		// gate reports "could not run" rather than silently scoring nothing.
		msg := "HS: exec failed\n"
		posix.write(posix.STDERR_FILENO, raw_data(msg), c.size_t(len(msg)))
		os.exit(127)
	}

	posix.close(out_fd)
	posix.close(err_fd)

	status : c.int = 0
	for {
		got := posix.waitpid(pid, &status, {})
		if got == pid { break }
		if got < 0 { break }
	}
	if posix.WIFEXITED(status) { return i32(posix.WEXITSTATUS(status)) }
	if posix.WIFSIGNALED(status) { return -i32(posix.WTERMSIG(status)) }
	return -1
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
	return transmute([^]cstring)(&out[0])
}

to_cstring :: proc(s: string, alloc: mem.Allocator) -> cstring {
	buf := make([]u8, len(s)+1, alloc)
	for i := 0; i < len(s); i += 1 { buf[i] = s[i] }
	buf[len(s)] = 0
	return transmute(cstring)(&buf[0])
}

os_read_file :: proc(path: string) -> ([]byte, os.Error) {
	return os.read_entire_file_from_path(path, context.allocator)
}
