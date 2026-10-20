package app

// herdr integration — the single choke point (T3.1).
//
// # Nothing else in this codebase spawns herdr
//
// Every herdr invocation goes through `run_capture` (read/act on state, output
// captured) or the handoff in `terminal` (give the terminal over). Centralising it
// is the point: the five rules below are each a *verified* failure mode, and they
// only hold if there is exactly one place that can get them wrong.
//
// # The rules this file enforces
//
//  1. **Scrub `HERDR_*` from every child.** We run *inside* herdr — verified
//     again this session: `HERDR_ENV=1`, `HERDR_SESSION=…`. Unscrubbed, every
//     create/attach dies with "nested herdr is disabled by default" (exit 1),
//     re-captured this session:
//         $ HERDR_ENV=1 herdr --session x   ->  exit 1, "nested herdr is disabled"
//     Note for the record: setting HERDR_ENV=0 instead is NOT a supported bypass
//     either — on 0.8.2 it walks past the nesting check and then fails on the tty
//     (exit 101). We never rely on that. Removing the whole namespace is the only
//     behaviour we depend on, because it is correct whatever herdr's truthiness
//     rules happen to be.
//     The scrub also drops inherited socket paths, which would otherwise point a
//     child straight at *this* live session. `TERM`/`COLORTERM` are kept:
//     dropping them downgrades herdr's own child rendering.
//     The scrub is `terminal.handoff`'s (T1.2) — reused, not re-implemented.
//
//  2. **stdout and stderr are separate buffers, never merged.** Error JSON comes
//     back on **stderr** (verified: `session stop --json <unknown>` → exit 1,
//     empty stdout, `{"error":{…}}` on stderr), and the Rust panic path writes
//     there too. Shell-merging the two streams in front of a JSON parse
//     corrupts it. See `outcome`.
//
//  3. **Validate names before invoking herdr.** Attaching is create-or-attach and
//     the server spawns *before* terminal init, so a bad name that crashes on
//     startup still leaves a live orphan session behind.
//
//  4. **Never trust `delete`'s answer.** `herdr session delete <never-existed>`
//     returns **exit 0** with `{"deleted": true}`. We pre-check the model and
//     report honestly. See `delete_session`.
//
//  5. **`default` is never offered** (D12). Filtered in `model.odin`, re-checked
//     here, and refused by `delete_session` even if a caller builds the request.
//
// # Exit-code contract — VERSION-TOLERANT (RCH-2 / O12)
//
//   code  meaning                                     where the message is
//   ----  ------------------------------------------  -------------------------
//     0   success                                     stdout (JSON with --json)
//     1   herdr error (nesting off, stop failed, …)    stderr {"error":{…}}
//     1*  no usable terminal (herdr >= 0.9.3)          stderr, plain text, NOT JSON
//     2   CLI syntax / name validation                 stderr + "herdr --help"
//   101   no usable terminal (herdr <= 0.8.2)          stderr, NOT JSON (Rust panic)
//   124   our own timeout fired                      —
//   127   `herdr: command not found` on a remote       stderr (ssh's)
//   255   ssh transport / auth failure                stderr (ssh's)
//
// 101 is deliberately *not* parsed as JSON, and 124 is one we synthesise.
//
// # The `1*` row, and why the map has two doors to the same answer
//
// herdr changed how it fails when there is no terminal. Both halves were
// captured on this box, against the same command (`herdr --session <name>`,
// stdin from a non-tty):
//
//   0.8.2  exit 101  thread 'main' panicked ... failed to initialize terminal
//   0.9.5  exit 1    herdr: cannot attach without a usable terminal: ...
//                    ; run inside a terminal
//
// A map keyed on the code alone therefore CANNOT be version-independent: code 1
// is simultaneously "a herdr error with an envelope" (both versions) and "the
// terminal refusal" (0.9.5 only). What separates them is not the code, it is
// the shape of stderr:
//
//   * envelope present ({"error":{code,message}}) -> a real herdr error. The
//     nesting refusal, a failed stop, a bad session name: these ALL arrive with
//     an envelope, and all arrive at exit 1.
//   * no envelope, but the text says the terminal is the problem -> the app has
//     no terminal to work with. That is `.tty_unavailable`, not a herdr error,
//     and it is actionable in a way "herdr error" is not.
//
// So `outcome` asks the envelope first and the marker second, and
// `outcome_needs_terminal` is the single predicate callers use when they want
// "did this fail because there was no terminal?" — true for 101 and for 1*.
// Both herdr versions answer it, which is the whole point: the user's herdr is
// not ours to pin (D: the user owns herdr via home-manager).

import json "core:encoding/json"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

import terminal "../terminal"

//-----------------------------------------------------------------------------
// Names
//-----------------------------------------------------------------------------

// NAME_MAX_LEN is a guard we impose on ourselves, not a herdr limit: it bounds
// what a paste can turn into an argv entry before anything validates it.
NAME_MAX_LEN :: 64

// Name_Validity is the verdict on a candidate session name plus a human-readable
// reason, so the TUI can echo *why* instead of just beeping.
Name_Validity :: struct {
	ok     : bool,
	reason : string,
}

NAME_OK :: Name_Validity{ok = true, reason = ""}

// name_is_valid_character is the herdr charset, `[A-Za-z0-9._-]` — taken from
// herdr-cycle.sh's own regex (`^[A-Za-z0-9._-]+$`). **No colons**, which is why
// the timestamp format uses dashes.
name_is_valid_character :: proc(b: byte) -> bool {
	return (b >= 'a' && b <= 'z') ||
	       (b >= 'A' && b <= 'Z') ||
	       (b >= '0' && b <= '9') ||
	       b == '.' || b == '_' || b == '-'
}

// validate_name checks a candidate session name. **Every** path that could reach
// herdr with a name calls this first, because the expensive failure is not a
// rejected name — it is a name that gets through and *creates a session*.
//
// Rejected: empty; wrong charset; longer than NAME_MAX_LEN; `.`/`..` (legal in
// the charset but path components under `~/.config/herdr/sessions/<name>`); and
// `default` (D12).
validate_name :: proc(name: string) -> Name_Validity {
	if len(name) == 0 {
		return Name_Validity{ok = false, reason = "empty name"}
	}
	if len(name) > NAME_MAX_LEN {
		return Name_Validity{ok = false,
			reason = fmt.tprintf("name is longer than {} characters", NAME_MAX_LEN)}
	}
	if name == "." || name == ".." {
		return Name_Validity{ok = false, reason = "'.' and '..' are not session names"}
	}
	if is_default_session_name(name) {
		return Name_Validity{ok = false,
			reason = "'default' is herdr's own workspace and is never used"}
	}
	for b in transmute([]byte)(name) {
		if !name_is_valid_character(b) {
			return Name_Validity{ok = false,
				reason = "only letters, digits, '.', '_' and '-' are allowed"}
		}
	}
	return NAME_OK
}

name_is_ok :: proc(name: string) -> bool {
	return validate_name(name).ok
}

//-----------------------------------------------------------------------------
// Environment scrub (rule 1)
//-----------------------------------------------------------------------------

// env_is_herdr_namespace reports whether an environment key belongs to herdr.
// `terminal.HERDR_NAMESPACE` is the single source of truth (T1.2) so the launch
// path and the reporting path cannot drift apart.
env_is_herdr_namespace :: proc(key: string) -> bool {
	return strings.has_prefix(key, terminal.HERDR_NAMESPACE)
}

// env_snapshot reads the current process environment into a map, for reporting
// and for tests. The child never sees this map; it gets
// `terminal.build_scrubbed_env()`, the NULL-terminated array execve() consumes.
env_snapshot :: proc() -> (map[string]string, os.Error) {
	env, err := os.environ(context.allocator)
	if err != nil { return nil, err }
	m := make(map[string]string)
	for entry in env {
		eq := strings.index(entry, "=")
		if eq < 0 { continue }
		m[entry[:eq]] = entry[eq+1:]
	}
	return m, nil
}

// scrub_env is the map-level view of the same rule, so it can be asserted without
// forking. `terminal.build_scrubbed_env` remains the only producer of a child
// environment; this exists so a test can check "no HERDR_* keys, TERM survives".
scrub_env :: proc(base: map[string]string) -> map[string]string {
	out := make(map[string]string)
	for k, v in base {
		if env_is_herdr_namespace(k) { continue }
		out[k] = v
	}
	return out
}

child_environment :: proc() -> [^]cstring {
	return terminal.build_scrubbed_env()
}

//-----------------------------------------------------------------------------
// Capture
//-----------------------------------------------------------------------------

// CAPTURE_TIMEOUT bounds a read-only / control command. Generous against a local
// herdr round-trip (single-digit ms), far short of the ~133 s a black-holed host
// costs when no timeout is set at all.
CAPTURE_TIMEOUT :: 10 * time.Second

// CONTROL_TIMEOUT is the budget for ONE control command the user is WAITING on
// with a frozen screen. It is derived from the transport, not picked: the
// mandatory ssh form carries `-o ConnectTimeout=5`, so a host that is gone
// answers in ~5 s and a live host answers in milliseconds. 6 s is that bound
// plus a second of slack, and it is the longest honest "working…" the delete
// path may ever show.
//
// The 10 s CAPTURE_TIMEOUT was DOUBLE what the ssh bound advertises: a delete
// aimed at a host that went away held a frozen UI for 10 s on `stop` and then
// 10 s on `delete`, for an answer that cannot arrive later than 5 s after each.
//
// Background fetches do NOT use this. They are bounded the other way (deadlines
// and floors, ISC-3) because there a late answer is still worth keeping.
CONTROL_TIMEOUT :: 6 * time.Second

// CAPTURE_EXIT_TIMEOUT is reported when *we* killed a long-running child. 124 is
// the `timeout(1)` convention so it cannot be mistaken for a herdr answer.
CAPTURE_EXIT_TIMEOUT :: 124

// CAPTURE_EXIT_NOT_FOUND is reported when the program could not be spawned at all
// — same code, same meaning as the shell's.
CAPTURE_EXIT_NOT_FOUND :: 127

// Capture is one completed herdr invocation: exit code plus the two output
// streams, kept **apart**.
Capture :: struct {
	code      : i32,
	out       : []byte, // stdout — never merged with stderr
	err       : []byte, // stderr — where herdr's error JSON actually lands
	timed_out : bool,   // we SIGKILLed it at the deadline
	spawned   : bool,   // false => the child never started (ENOENT / EACCES)
	argv      : []string,
}

// Drain_Stat is the tri-state result of one non-blocking read.
//
// ⚠️ TRAP (found while wiring T4.1,Phase 3's tests never reached it): a bool
// cannot carry this. The original `read_all_drain` returned `false` for BOTH
// "I read some bytes, more may be waiting" AND "there is nothing here right
// now", and `drain_until_blocked_or_eof` looped on `for !eof`. Against a child
// that goes quiet mid-flight (ssh after its banner, `sleep`, anything that
// writes then pauses) that loop never terminates: it is a 100 %-CPU spin on
// EAGAIN inside the UI thread, which is the exact thing ISC-A-2 forbids.
//
// Phase 3 got away with it because its children were all fast — they wrote and
// exited, so `read` returned 0 almost immediately. A fetch fan-out is the first
// caller that sits on a long-lived, mostly-silent pipe.
Drain_Stat :: enum {
	more,     // bytes read; call again
	blocked,  // EAGAIN/EWOULDBLOCK — nothing right now, go back to poll()
	eof,      // the writer closed
	error,    // a real error; treat as "stop polling this fd"
}

// read_all_drain pulls one chunk from a non-blocking fd, appending into `buf`.
// Prefer `drain_until_blocked_or_eof` for the "empty the pipe" job.
read_all_drain :: proc(fd: posix.FD, buf: ^[dynamic]byte) -> Drain_Stat {
	chunk: [16 * 1024]byte
	n := posix.read(fd, &chunk[0], c.size_t(len(chunk)))
	if n > 0 {
		append(buf, ..chunk[:int(n)])
		return .more // more may be waiting; caller keeps reading
	}
	if n == 0 { return .eof }
	e := posix.errno()
	if e == posix.Errno.EAGAIN || e == posix.Errno.EWOULDBLOCK { return .blocked }
	if e == posix.Errno.EINTR { return .blocked } // retried by the caller's loop
	return .error
}

set_nonblocking :: proc(fd: posix.FD) {
	flags := posix.fcntl(fd, .GETFL)
	if flags < 0 { return }
	posix.fcntl(fd, .SETFL, c.int(c.uint(flags) | c.uint(posix.O_NONBLOCK)))
}

// run_capture spawns `argv` with the HERDR_* namespace scrubbed, captures stdout
// and stderr into **separate** buffers, and returns within `timeout`.
//
// Nothing here touches the terminal — this is the non-interactive path used for
// listing, stopping and deleting. The interactive path is the handoff.
//
// ⚠️ It BLOCKS until the child exits or the deadline fires. Fine for a one-off
// command; Phase 4's fan-out must not call it in the render loop for a host it
// wants to keep waiting on — that is what the non-blocking fetch in T4.1 is for.
// The poll loop here is written so the same drain/reap pieces can be reused there.
run_capture :: proc(argv: []string, timeout: time.Duration) -> Capture {
	none := Capture{code = CAPTURE_EXIT_NOT_FOUND, argv = argv}
	if len(argv) == 0 { return none }

	// Resolve in the *parent*. `execvp` would search PATH using the inherited
	// environment rather than our scrubbed one, silently defeating rule 1
	// (learned the hard way in T1.2).
	prog := terminal.resolve_program(argv[0])
	if prog == nil { return none }

	child_argv := terminal.build_argv(argv)
	child_env := child_environment()

	pipes : [2][2]posix.FD
	if err := posix.pipe(&pipes[0]); err != nil { return none }
	if err := posix.pipe(&pipes[1]); err != nil {
		posix.close(pipes[0][0])
		posix.close(pipes[0][1])
		return none
	}

	pid := posix.fork()
	if pid < 0 {
		posix.close(pipes[0][0])
		posix.close(pipes[0][1])
		posix.close(pipes[1][0])
		posix.close(pipes[1][1])
		return none
	}

	if pid == 0 {
		// stdout -> pipes[0][1], stderr -> pipes[1][1]. Never dup2 one stream onto
		// the other, and never inherit our tty: the streams must stay apart here.
		posix.dup2(pipes[0][1], 1)
		posix.dup2(pipes[1][1], 2)
		for p in pipes {
			posix.close(p[0])
			posix.close(p[1])
		}
		// No controlling input on this path.
		devnull := posix.open("/dev/null", {})
		if devnull >= 0 { posix.dup2(devnull, 0) }
		posix.execve(prog, child_argv, child_env)
		posix._exit(CAPTURE_EXIT_NOT_FOUND)
	}

	// Parent. Closing the write ends is what makes EOF reachable at all.
	posix.close(pipes[0][1])
	posix.close(pipes[1][1])
	set_nonblocking(pipes[0][0])
	set_nonblocking(pipes[1][0])

	out_buf := make([dynamic]byte, 0, 8 * 1024)
	err_buf := make([dynamic]byte, 0, 2 * 1024)
	eof_out, eof_err := false, false
	started := time.now()
	killed := false

	pfds : [2]posix.pollfd

	for !(eof_out && eof_err) {
		remaining := timeout - time.since(started)
		if remaining <= 0 {
			posix.kill(pid, .SIGKILL)
			killed = true
			break
		}

		nfds := 0
		pfds[0] = posix.pollfd{}
		pfds[1] = posix.pollfd{}
		if !eof_out {
			pfds[nfds].fd = pipes[0][0]
			pfds[nfds].events = {.IN}
			nfds += 1
		}
		if !eof_err {
			pfds[nfds].fd = pipes[1][0]
			pfds[nfds].events = {.IN}
			nfds += 1
		}

		// Poll in short slices so the deadline stays honest even if one stream
		// dribbles bytes for a long time.
		ms := int(time.duration_milliseconds(remaining))
		if ms < 1 { ms = 1 }
		if ms > 100 { ms = 100 }

		rv := posix.poll(&pfds[0], posix.nfds_t(nfds), c.int(ms))
		if rv < 0 {
			if posix.errno() == posix.Errno.EINTR { continue }
			break
		}
		if rv == 0 { continue }

		for i in 0..<nfds {
			ready := pfds[i].revents
			ready_mask : posix.Poll_Event = {.IN, .HUP, .ERR}
			if (ready & ready_mask) == {} { continue }
			is_out := pfds[i].fd == pipes[0][0]
			if is_out {
				eof_out = drain_until_blocked_or_eof(pipes[0][0], &out_buf)
			} else {
				eof_err = drain_until_blocked_or_eof(pipes[1][0], &err_buf)
			}
		}
	}

	res := Capture{
		out       = out_buf[:],
		err       = err_buf[:],
		timed_out = killed,
		spawned   = true,
		argv      = argv,
	}
	res.code = reap_child(pid, 3 * time.Second)
	if killed { res.code = CAPTURE_EXIT_TIMEOUT }
	return res
}

// drain_until_blocked_or_eof empties a non-blocking fd, stopping at the FIRST
// EAGAIN. Returns true only at EOF (or a hard error, which we also stop on).
//
// "Blocked" and "EOF" have to be different answers: a caller sitting on a pipe
// whose writer is merely quiet must return to poll(), not keep reading. The
// previous bool-only version conflated them and spun. (See `Drain_Stat`.)
drain_until_blocked_or_eof :: proc(fd: posix.FD, buf: ^[dynamic]byte) -> bool {
	for {
		switch read_all_drain(fd, buf) {
		case .more:
			continue
		case .blocked:
			return false
		case .eof:
			return true
		case .error:
			return true
		}
	}
}

// reap_child waits for `pid` on a bounded WNOHANG spin — it never turns into a
// blocking wait we did not budget for. Returns the exit code, or -1 if it could
// not be reaped inside `budget`.
reap_child :: proc(pid: posix.pid_t, budget: time.Duration) -> i32 {
	status : c.int = 0
	started := time.now()
	for {
		r := posix.waitpid(pid, &status, {.NOHANG})
		if r > 0 { return terminal.exit_code(status) }
		if r < 0 {
			if posix.errno() == posix.Errno.EINTR { continue }
			return -1
		}
		if time.since(started) > budget { return -1 }
		time.sleep(1 * time.Millisecond)
	}
}

//-----------------------------------------------------------------------------
// The stdout/stderr split (rule 2) — `outcome`
//-----------------------------------------------------------------------------

Outcome_Kind :: enum {
	ok,            // exit 0 — parse stdout
	herdr_error,   // exit 1 — parse stderr for {"error":{code,message}}
	cli_error,     // exit 2 — argv was wrong: our bug, or a hostile config
	tty_panic,     // exit 101 — the pre-0.9 terminal failure (Rust panic, NOT JSON)
	tty_unavailable, // exit 1 with NO envelope and a terminal-shaped message (0.9.3+)
	timed_out,     // ours (124)
	no_herdr,      // 127 — herdr is not installed on that host
	ssh_failure,   // 255 — transport/auth
	not_found,     // we could not even spawn it
	unknown,
}

// TTY_REFUSAL_MARKERS are the words herdr uses when the terminal, not herdr, is
// the problem. Matched case-insensitively against stderr, and only after the
// {"error":…} envelope has been RULED OUT — the envelope is what makes "exit 1,
// herdr error" mean something else, and a marker-only match would collapse the
// two. Kept as a list rather than one substring because herdr's wording is not a
// contract we own and two of these phrases are version-specific:
//
//   0.8.2 (exit 101, panic path) "failed to initialize terminal"
//   0.9.5 (exit 1, clean)        "cannot attach without a usable terminal"
//                                "; run inside a terminal"
//
// Deliberately NOT matched: the word "terminal" alone. `herdr --help` and
// several real error envelopes contain it, and a false `.tty_unavailable` would
// tell a user to go find a terminal when their config is what is broken.
TTY_REFUSAL_MARKERS := []string{
	"usable terminal",
	"run inside a terminal",
	"failed to initialize terminal",
	"failed to initialize the terminal",
	"no controlling terminal",
	"terminal is required",
}

// stderr_says_no_terminal is the second door of the `1*` rule: shape, not code.
stderr_says_no_terminal :: proc(err: []byte) -> bool {
	if len(err) == 0 { return false }
	lower := strings.to_lower(string(err))
	for m in TTY_REFUSAL_MARKERS {
		if strings.contains(lower, strings.to_lower(m)) { return true }
	}
	return false
}

// outcome_needs_terminal is THE version-tolerant answer to "was this a no-tty
// failure?". Both herdr generations get here — 0.8.2 by panicking at 101,
// 0.9.5 by exiting 1 with a clean sentence — and callers must not have to know
// which one the user has installed.
outcome_needs_terminal :: proc(k: Outcome_Kind) -> bool {
	return k == .tty_panic || k == .tty_unavailable
}

// Herdr_Error is the parsed `{"error":{"code","message"}}` envelope. `present`
// is false when the payload was not that shape — which includes the Rust panic
// text, so a caller can never accidentally attribute panic output to herdr.
Herdr_Error :: struct {
	code    : string,
	message : string,
	present : bool,
}

Raw_Error_Envelope :: struct {
	code    : string,
	message : string,
}

Raw_Error_Wrapper :: struct {
	err : Raw_Error_Envelope `json:"error"`,
}

parse_error_envelope :: proc(payload: []byte) -> Herdr_Error {
	if len(payload) == 0 { return Herdr_Error{} }
	w : Raw_Error_Wrapper = {}
	if err := json.unmarshal(payload, &w); err != nil {
		return Herdr_Error{}
	}
	if w.err.code == "" && w.err.message == "" { return Herdr_Error{} }
	return Herdr_Error{code = w.err.code, message = w.err.message, present = true}
}

// outcome applies the exit-code contract.
//
// THE RULE, stated once: **exit 0 → stdout is authoritative; exit ≠ 0 → stderr
// is authoritative.** Never the other way round, and never one merged buffer.
// This is the only place that decides which stream to parse, which is what makes
// "never merge the streams before a JSON parse" is a property of the design
// rather than a habit each caller has to remember.
outcome :: proc(c: ^Capture) -> (kind: Outcome_Kind, payload: []byte, herr: Herdr_Error) {
	if c.timed_out { return .timed_out, nil, Herdr_Error{} }
	if !c.spawned { return .not_found, nil, Herdr_Error{} }

	if c.code == 0 {
		return .ok, c.out, Herdr_Error{}
	}

	// Everything below answers from STDERR only.
	herr = parse_error_envelope(c.err)

	// The `1*` split, in the only order that is not a guess: the envelope first.
	// Exit 1 WITH an envelope is a herdr error on every version (nesting refused,
	// stop failed, name rejected). Exit 1 with NO envelope and a terminal-shaped
	// message is 0.9.3+ saying "I have no terminal" — same meaning as the old
	// 101 panic, different code.
	if c.code == 1 && !herr.present && stderr_says_no_terminal(c.err) {
		return .tty_unavailable, c.err, Herdr_Error{}
	}
	if c.code == 1 { return .herdr_error, c.err, herr }
	if c.code == 2 { return .cli_error, c.err, herr }
	// The pre-0.9 terminal failure. A Rust panic is not JSON and its text is
	// internal detail, so the payload is deliberately nil: the caller shows a
	// generic line instead of echoing a backtrace into the status bar. Note this
	// branch comes AFTER the envelope check, which is where 0.9.3+'s exit-1
	// refusal is caught; between them, `outcome_needs_terminal` covers every
	// herdr generation without the caller choosing a version.
	if c.code == 101 { return .tty_panic, nil, Herdr_Error{} }
	if c.code == 127 { return .no_herdr, c.err, herr }
	if c.code == 255 { return .ssh_failure, c.err, herr }
	return .unknown, c.err, herr
}

outcome_label :: proc(k: Outcome_Kind) -> string {
	#partial switch k {
	case .ok:          return "ok"
	case .herdr_error:  return "herdr error"
	case .cli_error:    return "bad command line"
	case .tty_panic:    return "terminal-init panic"
	case .tty_unavailable: return "no usable terminal"
	case .timed_out:    return "timed out"
	case .no_herdr:     return "herdr not installed there"
	case .ssh_failure:  return "ssh failed"
	case .not_found:    return "herdr not found"
	}
	return "unknown error"
}

//-----------------------------------------------------------------------------
// argv construction
//-----------------------------------------------------------------------------

// HERDR_BIN is resolved from PATH in the parent by `terminal.resolve_program`,
// deliberately not baked in as an absolute path: the user owns herdr
// (home-manager), and 0.8.2-vs-0.9.x drift is theirs to manage — not something
// we paper over by hiding it inside our own PATH.
HERDR_BIN :: "herdr"

SSH_BIN :: "ssh"

// SSH_BASE_ARGS every fetch carries. MANDATORY, not tuning: without
// `ConnectTimeout` a black-holed host costs ~133 s, and without `BatchMode` a
// passphrase prompt hangs the fan-out forever instead of failing in ~120 ms.
// `-T` keeps stdout pure JSON (no tty, no chatter) and is ~20 ms faster.
//
// The trailing `--` is the OPTION-PARSING TERMINATOR (P2-7), and it is in this
// list rather than spelled out at each call site on purpose: `SSH_BASE_ARGS` is
// always emitted immediately before the device, so putting the terminator last
// here is what guarantees `--` sits between our options and the device in EVERY
// ssh argv we build, including ones added later. Verified on this box:
//
//	ssh -T -o BatchMode=yes -o ConnectTimeout=5 -- '-F/tmp/evil' 'echo x'
//	  → hostname contains invalid characters      (exit 255, nothing ran)
//	ssh -T -o BatchMode=yes -o ConnectTimeout=5   '-F/tmp/evil' 'echo x'
//	  → ssh READS /tmp/evil as its config file    (BatchMode gone)
//
// It is a SECOND layer, not a replacement: `remote_is_valid` still refuses such
// a device at config-parse and registry-parse time, with a warning. Validation
// stops the user's typo; `--` makes the transport itself unable to be hijacked if
// that validation is ever bypassed.
SSH_BASE_ARGS :: [6]string{
	"-T",
	"-o", "BatchMode=yes",
	"-o", "ConnectTimeout=5",
	"--", // must stay LAST: it terminates option parsing right before the device
}

// remote_list_argv is our own `ssh -T … 'herdr session list --json'`.
//
// `herdr --remote X session list` is **invalid** (exit 2: "--remote can only be
// used with the default launch command") and `--machine` does not forward session
// commands either, so remote enumeration is always our own ssh.
//
// `device` goes in **verbatim** — the same string the config carried and the same
// one `launch_argv` puts after `--remote`.
remote_list_argv :: proc(device: string) -> []string {
	argv := make([dynamic]string, 0, 8)
	append(&argv, SSH_BIN)
	for a in SSH_BASE_ARGS { append(&argv, a) }
	append(&argv, device)
	append(&argv, "herdr session list --json")
	return argv[:]
}

// launch_argv builds the create-or-attach command (there is **no**
// `herdr session create`).
//
//	local : herdr --session <name>
//	remote: herdr --remote <device> --session <name>   <- device verbatim
launch_argv :: proc(device: string, name: string) -> (out: []string, ok: bool) {
	if v := validate_name(name); !v.ok { return nil, false }

	argv := make([dynamic]string, 0, 6)
	append(&argv, HERDR_BIN)
	if !is_local_device(device) {
		append(&argv, "--remote")
		append(&argv, device)
	}
	append(&argv, "--session")
	append(&argv, name)
	return argv[:], true
}

// attach_argv builds `herdr session attach <name>`. CREATE-OR-ATTACH: a caller
// that means "attach, do not create" must have checked the model first, or a typo
// silently spawns a session (see ISC-17 / the orphan rule).
attach_argv :: proc(name: string) -> (out: []string, ok: bool) {
	if v := validate_name(name); !v.ok { return nil, false }
	argv := make([dynamic]string, 0, 4)
	append(&argv, HERDR_BIN, "session", "attach")
	append(&argv, name)
	return argv[:], true
}

stop_argv :: proc(name: string) -> []string {
	argv := make([dynamic]string, 0, 4)
	append(&argv, HERDR_BIN, "session", "stop", "--json")
	append(&argv, name)
	return argv[:]
}

delete_argv :: proc(name: string) -> []string {
	argv := make([dynamic]string, 0, 4)
	append(&argv, HERDR_BIN, "session", "delete", "--json")
	append(&argv, name)
	return argv[:]
}

list_argv :: proc() -> []string {
	argv := make([dynamic]string, 0, 4)
	append(&argv, HERDR_BIN, "session", "list", "--json")
	return argv[:]
}

// control_argv routes a herdr *control* command to `device`.
//
// A local device gets the argv back unchanged. A remote device gets the same
// command wrapped in OUR OWN `ssh -T …`, for the same reason `remote_list_argv`
// exists: `herdr --remote X session delete` is rejected outright (verbatim rule
// 11 — `--remote` only pairs with the default launch command).
//
// Without this the identity rule breaks in the worst available way: a delete on
// a REMOTE row would run `herdr session delete <name>` HERE and destroy a
// same-named LOCAL session. The device is part of the identity, so it has to be
// part of the argv too.
//
// The inner command travels as a single quoted argument. Every name inside it
// has already cleared `validate_name` ([A-Za-z0-9._-]), so no shell
// metacharacter can exist in it; the quoting is defence in depth, not the guard.
control_argv :: proc(device: string, inner: []string) -> []string {
	if is_local_device(device) { return inner }
	cmd := strings.join(inner, " ")
	argv := make([dynamic]string, 0, len(SSH_BASE_ARGS)+3)
	append(&argv, SSH_BIN)
	for a in SSH_BASE_ARGS { append(&argv, a) }
	append(&argv, device)
	append(&argv, fmt.tprintf("'%s'", cmd))
	return argv[:]
}

//-----------------------------------------------------------------------------
// The delete path, with the honesty pre-check (rules 3, 4, 5)
//-----------------------------------------------------------------------------

// Delete_Result is what `delete_session` reports. `deleted` is only ever true
// when we **know** the session existed.
Delete_Result :: struct {
	deleted     : bool,
	existed     : bool,
	was_running : bool,
	refused     : bool,
	reason      : string,
	// herdr_said_deleted carries herdr's own answer for the logs, so "herdr said
	// deleted:true" and "we report: it never existed" can sit side by side.
	herdr_said_deleted : bool
}

// delete_session stops (if running) then deletes a session we have verified
// exists — and reports honestly when it does not.
//
// Verified behaviour this guards against:
//
//	$ herdr session delete --json hs-never-existed-zz-99
//	exit 0   {"deleted":true,"session":{"name":"hs-never-existed-zz-99", …}}
//
// …for a session that was never created. Answering "deleted" to a typo is worse
// than answering "no such session", because the user then believes a row they
// cannot see is gone. So the model decides, not herdr.
delete_session :: proc(sessions: []Session, device: string, name: string,
                     timeout: time.Duration) -> Delete_Result {
	if is_default_session_name(name) {
		return Delete_Result{refused = true,
			reason = "'default' is herdr's own workspace and is never deleted (D12)"}
	}
	if v := validate_name(name); !v.ok {
		return Delete_Result{refused = true, reason = v.reason}
	}

	idx := index_of_identity(sessions, device, name)
	if idx < 0 {
		// The pre-check. We do not call herdr at all: there is nothing to delete,
		// and calling it would put the `deleted:true` lie in our own logs.
		return Delete_Result{
			existed = false,
			refused = true,
			reason  = fmt.tprintf("{} is not in our list for {} — nothing was deleted", name, device),
		}
	}

	was_running := sessions[idx].running

	// herdr refuses to delete a *running* session, so stop first (parity with
	// herdr-cycle.cleanup_session). A failed stop is not fatal: the session may
	// have gone away between listing and acting, and the delete is the
	// authoritative step.
	if was_running {
		run_capture(control_argv(device, stop_argv(name)), timeout)
	}

	del := run_capture(control_argv(device, delete_argv(name)), timeout)
	herr := parse_error_envelope(del.err)

	if del.code != 0 {
		msg := herr.message
		if msg == "" { msg = fmt.tprintf("herdr exited with code {}", del.code) }
		return Delete_Result{existed = true, was_running = was_running,
			refused = true, reason = msg}
	}

	return Delete_Result{
		existed            = true,
		was_running        = was_running,
		deleted            = true,
		herdr_said_deleted = true,
	}
}

//-----------------------------------------------------------------------------
// Cleanup policy (D2 — RESOLVED by RCH-3/R1)
//-----------------------------------------------------------------------------

// Cleanup_Policy decides what happens to a session after we detach from it.
//
// D2 was parked at `never` while herdr's own detach semantics were unknown. The
// user has since decided the behaviour they want (RCH-3/R1):
//
//   "After creating/starting a session, then going back (the session was
//    detached), it should delete the session and update the list when going back
//    to the main state. If the session was already deleted there is no error to
//    show."
//
// The default is therefore `only_created`, NOT `always`. That distinction is the
// whole point of the policy existing: `always` would destroy a session the user
// merely attached to — a session they had before we ever saw it, with their own
// work in it. `only_created` destroys exactly the sessions this app generated a
// name for and asked herdr to start, and lays hands on nothing else.
Cleanup_Policy :: enum {
	never,         // destroy nothing; deletion is always an explicit user action
	only_created,  // ← DEFAULT (RCH-3/R1): destroy sessions we created, leave the user's own alone
	always,        // herdr-cycle's old behaviour: stop+delete after every detach
}

// DEFAULT_CLEANUP_POLICY is the shipped default (RCH-3/R1). It is the value the
// app uses when `cleanup_policy` is ABSENT from the config. A value that is
// present but unrecognised still falls back to `.never` (see
// `cleanup_policy_from_name`): an unparseable value must never escalate the user
// into a more destructive mode than they asked for.
DEFAULT_CLEANUP_POLICY :: Cleanup_Policy.only_created

cleanup_policy_value : Cleanup_Policy = DEFAULT_CLEANUP_POLICY

cleanup_policy :: proc() -> Cleanup_Policy {
	return cleanup_policy_value
}

set_cleanup_policy :: proc(p: Cleanup_Policy) {
	cleanup_policy_value = p
}

// cleanup_should_run answers whether the detach path should stop+delete `name`.
// D12 outranks every policy: `default` is never destroyed.
//
// The `we_created_it` half is what makes `only_created` (the shipped default)
// safe. It is supplied by the CALLER at the one place that knows the difference:
// `do_launch` passes true (the machine generated that name and asked herdr to
// create it) and `do_attach` passes false (the session belonged to the user
// before we ever listed it). "I did not create it" is not a guess made after the
// fact — it is recorded at the spawn site, which is the only moment the two
// cases are still distinguishable.
cleanup_should_run :: proc(p: Cleanup_Policy, name: string, we_created_it: bool) -> bool {
	if is_default_session_name(name) { return false }
	#partial switch p {
	case .never:        return false
	case .only_created: return we_created_it
	case .always:       return true
	}
	return false
}
