package app

// Parallel, non-blocking, self-healing session fetch (T4.1) and the
// identity-preserving merge that lands its results (T4.2).
//
// # No threads. Nothing in this file imports the threading library and none
// is wanted — see the header note on the wake mechanism.
//
// Every fetch is already an OS process, and that process's stdout becoming
// readable **is** the async wake event. Consequences, all load-bearing:
//
//   * no self-pipe for fetches (termbox2's resize self-pipe is the only
//     self-pipe in the design, and it is not ours to multiplex),
//   * no mutexes, because nothing is shared across an execution boundary,
//   * no data races, for the same reason,
//   * no idle spin: we block in `poll()` and are woken by bytes or by the
//     clock, never by a timer-driven re-read.
//
// ```
// startup:  local fetch inline (~3 ms) -> first paint
//           per device:  ssh -T -o BatchMode=yes -o ConnectTimeout=5 \
//                           <device> 'herdr session list --json'   [stdout = pipe]
// loop:     poll( ttyfd, resizefd, *fetch_fd )
//           fetch_fd readable -> read -> EOF -> waitpid(WNOHANG)
//                                   -> parse STDOUT ONLY
//                                   -> merge rows -> device: pending -> ok
//           own deadline exceeded -> SIGKILL child -> device: timed_out
// ```
//
// # The three things that make a host's failure harmless
//
//  1. **Every fd is O_NONBLOCK.** A host that never writes cannot stall a read.
//  2. **Every child is reaped.** `fetch_reap` uses `WNOHANG` only, so reaping
//     cannot block either, and `fetch_kill` + reap means a timeout cannot leave a
//     zombie behind.
//  3. **Status is per-device.** A failure writes to *that* `Device.status` and
//     merges *no* rows. It cannot clear, reorder or otherwise touch another
//     host's rows, which is what ISC-15 actually requires.
//
// # The deadline is a backstop, not the primary bound
//
// `ssh`'s own `ConnectTimeout=5` is the first line: measured, a black-holed host
// exits 255 at 5.01 s with `ConnectTimeout=5`, and 133 s without it. Our own
// deadline sits above that (default `FETCH_DEADLINE`) so it only fires when ssh
// itself is wedged — a hung control channel, a half-open session, an ssh that
// ignores its own timeout. When it fires we SIGKILL **and** reap, because a
// timeout that closes the pipes but never reaps is a zombie factory (T3.1's third
// trap, and still true here).
//
// # T4.2 — why the merge keys on identity and not on position
//
// `merge` replaces one device's row group and leaves every other group exactly
// alone. Selection is therefore tracked as a `(device, name)` **identity**, never
// as an index: a remote fetch that lands while the user has a row highlighted
// inserts rows that shift the index under it, and index-based selection silently
// moves the highlight to a different session — the next `Enter` then attaches
// something the user never picked. Identities do not move. `Selection` carries
// the pair, and the view re-resolves it to an index *after* every merge.
//
// Filter text and caret position are deliberately **not** in `Table` at all: the
// merge cannot clobber what it cannot reach, so "the filter survives a merge" is
// structural rather than a rule each caller has to remember.

import "core:c"
import "core:mem"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"

import terminal "../terminal"

//-----------------------------------------------------------------------------
// Deadline policy
//-----------------------------------------------------------------------------

// FETCH_DEADLINE is our own backstop for a fetch. It must be strictly larger than
// ssh's ConnectTimeout (5 s, set in `SSH_BASE_ARGS`) so the *ssh*-enforced bound
// wins in the normal unreachable case and ours only catches a wedged ssh.
FETCH_DEADLINE :: 13 * time.Second

// LOCAL_FETCH_DEADLINE bounds the local (no ssh) fetch. A local `session list`
// round-trip is ~3 ms; this is pure insurance against a wedged herdr socket.
LOCAL_FETCH_DEADLINE :: 5 * time.Second

// POLL_SLICE caps how long one poll() sleeps, so a deadline stays honest when a
// stream dribbles bytes and the registry is otherwise quiet.
POLL_SLICE :: 100 * time.Millisecond

//-----------------------------------------------------------------------------
// Fetch
//-----------------------------------------------------------------------------

Fetch_Kind :: enum {
	local, // `herdr session list --json` on this machine
	remote, // `ssh -T … 'herdr session list --json'`
}

// Fetch is one in-flight list request: a child process, its two captured streams,
// and (once finished) the verdict about that device.
//
// The two streams are **never merged** — `out` is what we JSON-parse and `err` is
// what we classify failures from. That split is inherited from `run_capture`'s
// discipline (ISC-A-1) and is the reason a chatty ssh cannot corrupt a parse.
Fetch :: struct {
	// Identity — the VERBATIM device string, `local` for this machine.
	device : string,
	label  : string,
	kind   : Fetch_Kind,
	argv   : []string,

	// The child and its pipes. Both read ends are O_NONBLOCK for the whole life
	// of the fetch.
	pid     : posix.pid_t,
	out_fd  : posix.FD,
	err_fd  : posix.FD,
	spawned : bool,
	closed  : bool,

	out     : [dynamic]byte,
	err     : [dynamic]byte,
	eof_out : bool,
	eof_err : bool,

	// Deadline bookkeeping. `started_at` + `budget`; we never mutate a Time, so
	// the arithmetic stays in `time.since` and cannot drift.
	started_at : time.Time,
	budget     : time.Duration,
	killed     : bool,

	// Verdict (meaningful once `settled`).
	settled   : bool,
	reaped  : bool, // the OS has actually collected the child. `settled` WITHOUT
	                // `reaped` is a zombie, so the two are tracked apart and
	                // `registry_free` refuses to let that stand.
	merged  : bool, // T5.5: this settled child's rows have been folded into the
	                // Table exactly once. The poll loop looks at every child on
	                // every wake, so without this a settled fetch would be
	                // re-merged (and re-dirtied the screen) forever.
	status    : Device_Status,
	detail    : string,
	rows      : []Session,
	exit_code : i32,

	// Evidence: the instant bytes first arrived. This is the wake event the whole
	// design rests on, so it is recorded rather than inferred.
	first_bytes_at : time.Time,
	ever_bytes     : bool,
	settled_at     : time.Time,
}

fetch_free :: proc(f: ^Fetch) {
	if f == nil { return }
	fetch_close(f)
	delete(f.out)
	delete(f.err)
	mem.free(f)
}

fetch_close :: proc(f: ^Fetch) {
	if f.closed { return }
	f.closed = true
	if f.out_fd != 0 { posix.close(f.out_fd) }
	if f.err_fd != 0 { posix.close(f.err_fd) }
	f.out_fd = 0
	f.err_fd = 0
}

// fetch_pending is "still a child we are waiting on".
fetch_pending :: proc(f: ^Fetch) -> bool {
	return !f.settled
}

// fetch_remaining is the time left before our own deadline.
fetch_remaining :: proc(f: ^Fetch) -> time.Duration {
	left := f.budget - time.since(f.started_at)
	if left < 0 { return 0 }
	return left
}

fetch_label :: proc(f: ^Fetch) -> string {
	if f.label != "" { return f.label }
	return f.device
}

//-----------------------------------------------------------------------------
// Spawning
//-----------------------------------------------------------------------------

// spawn_fetch starts `argv` with stdout and stderr on separate non-blocking
// pipes and returns immediately. It never waits, so it can be called in a loop
// across every host in the registry.
//
// The child env is `child_environment()` — the same scrubbed array `run_capture`
// and the handoff use, because the HERDR_* rule (ISC-2) is not allowed to have
// two implementations.
spawn_fetch :: proc(device, label: string, kind: Fetch_Kind, argv: []string,
                  budget: time.Duration) -> ^Fetch {

	f := new(Fetch)
	f.device = device
	f.label = label
	f.kind = kind
	f.argv = argv
	f.budget = budget
	f.started_at = time.now()
	f.status = .pending
	f.out = make([dynamic]byte, 0, 16 * 1024)
	f.err = make([dynamic]byte, 0, 4 * 1024)

	if len(argv) == 0 {
		return settle_failed_spawn(f, "empty argv")
	}

	// Resolve in the PARENT: execvp() would search PATH with the inherited
	// environment and silently undo the scrub (T1.2/T3.1).
	prog := terminal.resolve_program(argv[0])
	if prog == nil {
		return settle_failed_spawn(f, fmt.tprintf("{} not found", argv[0]))
	}

	child_argv := terminal.build_argv(argv)
	child_env := child_environment()

	pipes : [2][2]posix.FD
	if err := posix.pipe(&pipes[0]); err != nil { return settle_failed_spawn(f, "pipe() failed") }
	if err := posix.pipe(&pipes[1]); err != nil {
		posix.close(pipes[0][0])
		posix.close(pipes[0][1])
		return settle_failed_spawn(f, "pipe() failed")
	}

	pid := posix.fork()
	if pid < 0 {
		for p in pipes {
			posix.close(p[0])
			posix.close(p[1])
		}
		return settle_failed_spawn(f, "fork() failed")
	}

	if pid == 0 {
		// Child. stdout -> A, stderr -> B; never one onto the other, and never a
		// tty. Input is /dev/null so nothing can block reading a terminal that
		// is not ours to read.
		posix.dup2(pipes[0][1], 1)
		posix.dup2(pipes[1][1], 2)
		for p in pipes {
			posix.close(p[0])
			posix.close(p[1])
		}
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

	f.pid = pid
	f.out_fd = pipes[0][0]
	f.err_fd = pipes[1][0]
	f.spawned = true
	return f
}

// settle_failed_spawn is the one shape of "there will never be a child": no
// process, no pipes, a settled fetch with a reason. Callers never have to
// special-case it — from the registry's point of view it is just a device that
// settled early.
settle_failed_spawn :: proc(f: ^Fetch, why: string) -> ^Fetch {
	f.spawned = false
	f.settled = true
	f.status = .failed
	f.exit_code = CAPTURE_EXIT_NOT_FOUND
	f.detail = fmt.tprintf("could not start the fetch for {}: {}", f.device, why)
	f.settled_at = time.now()
	return f
}

// spawn_remote_fetch is the ONLY way a remote list is started. The argv comes
// from `remote_list_argv`, so `-T`, `BatchMode=yes` and `ConnectTimeout=5`
// cannot be dropped by a caller that forgot why they are there.
spawn_remote_fetch :: proc(r: Remote, budget: time.Duration) -> ^Fetch {
	return spawn_fetch(r.device, remote_label(r), .remote, remote_list_argv(r.device), budget)
}

// spawn_local_fetch is the async form of the local list. The startup path uses
// `local_snapshot` (blocking, ~3 ms) instead, because the first paint must not
// wait on a poll cycle; this exists for refreshes and for the tests that need
// local and remote to go through the same machinery.
spawn_local_fetch :: proc(budget: time.Duration) -> ^Fetch {
	return spawn_fetch(DEVICE_LOCAL, DEVICE_LOCAL, .local, list_argv(), budget)
}

//-----------------------------------------------------------------------------
// Draining
//-----------------------------------------------------------------------------

// fetch_drain empties both streams as far as they will go without blocking.
//
// It is driven by poll() readiness, but it does not assume only the ready fd has
// data: draining both every wake costs one extra EAGAIN and cannot strand bytes
// behind a still-open pipe. `drain_until_blocked_or_eof` (T3.1) is reused
// verbatim — this is exactly the seam it was split out for.
fetch_drain :: proc(f: ^Fetch) {
	if !f.eof_out {
		f.eof_out = drain_until_blocked_or_eof(f.out_fd, &f.out)
	}
	if !f.eof_err {
		f.eof_err = drain_until_blocked_or_eof(f.err_fd, &f.err)
	}
	// The wake event itself: the first moment a child gave us anything.
	if !f.ever_bytes && (len(f.out) > 0 || len(f.err) > 0) {
		f.ever_bytes = true
		f.first_bytes_at = time.now()
	}
}

fetch_drained :: proc(f: ^Fetch) -> bool {
	return f.eof_out && f.eof_err
}

// fetch_fds_watched lists the fds that are still worth polling. An EOF stream is
// removed from the set so a long-lived fetch shrinks its poll footprint instead
// of re-waking on a hangup we already handled.
fetch_fds_watched :: proc(f: ^Fetch, fds: ^[dynamic]posix.pollfd) {
	if f.settled || f.closed { return }
	if !f.eof_out {
		append(fds, posix.pollfd{fd = f.out_fd, events = {.IN}})
	}
	if !f.eof_err {
		append(fds, posix.pollfd{fd = f.err_fd, events = {.IN}})
	}
}

//-----------------------------------------------------------------------------
// Reaping, killing, settling
//-----------------------------------------------------------------------------

// fetch_reap collects the child if it has exited. WNOHANG only: a reap that can
// block is not a reap, it is a hidden `wait()`.
//
// Returns true when the child is gone (and the fetch is therefore settled).
fetch_reap :: proc(f: ^Fetch) -> bool {
	if !f.spawned || f.settled { return f.settled }
	status : c.int = 0
	r := posix.waitpid(f.pid, &status, {.NOHANG})
	if r < 0 {
		if posix.errno() == posix.Errno.EINTR { return false }
		// ECHILD: somebody already collected it. Treat it as gone rather than
		// leaving the fetch live forever with a pid that no longer exists.
		f.reaped = true
		f.exit_code = -1
		settle_exit(f, -1)
		return true
	}
	if r == 0 { return false } // still running
	f.reaped = true
	f.exit_code = terminal.exit_code(status)
	settle_exit(f, f.exit_code)
	return true
}

// fetch_kill is our deadline firing. SIGKILL (not TERM): a child that ignored its
// own connect timeout and holds our pipe is not going to listen politely.
fetch_kill :: proc(f: ^Fetch) {
	if !f.spawned || f.settled { return }
	f.killed = true
	posix.kill(f.pid, .SIGKILL)
}

// settle_exit turns a finished child into a device verdict: status + rows.
//
// THE STREAM RULE lives in `outcome` (herdr.odin), not here: exit 0 -> stdout,
// exit != 0 -> stderr. Keeping that decision in one function across both the
// blocking and the non-blocking path is what makes ISC-A-1 structural.
settle_exit :: proc(f: ^Fetch, code: i32) {
	if f.settled { return }

	c := Capture{
		code      = code,
		out       = f.out[:],
		err       = f.err[:],
		timed_out = f.killed,
		spawned   = f.spawned,
		argv      = f.argv,
	}
	kind, payload, herr := outcome(&c)
	f.status = device_status_of(kind, string(f.err[:]))
	f.exit_code = code
	f.settled = true
	f.settled_at = time.now()

	if f.status == .ok {
		rows, ok := parse_session_list(payload, f.device, fetch_label(f))
		if !ok {
			// exit 0 with a body that is not a session list. That is not a
			// host outage; it is an unparseable answer, and it costs this
			// device its group and nothing else.
			f.status = .failed
			f.detail = "answered, but not with a session list"
			return
		}
		f.rows = rows
		f.detail = fmt.tprintf("{} session(s)", len(rows))
		return
	}

	f.detail = herr.message
	if f.detail == "" { f.detail = outcome_label(kind) }
}

// device_status_of maps the transport-level outcome onto the per-host status the
// table shows.
//
// The one split that is ours to make (herdr's contract cannot make it): exit 255
// covers BOTH "could not connect" and "would not let us in", and the two need
// different words in the UI. `ssh` prints them distinctly, so we read which.
// Measured against this box:
//
//	ssh: connect to host 10.255.255.1 port 22: Connection timed out  -> unreachable
//	Permission denied (publickey,password,keyboard-interactive).      -> auth_failed
device_status_of :: proc(kind: Outcome_Kind, err_text: string) -> Device_Status {
	#partial switch kind {
	case .ok:          return .ok
	case .timed_out:   return .timed_out
	case .no_herdr:    return .no_herdr
	case .ssh_failure:  return ssh_failure_status(err_text)
	case .herdr_error:  return .failed
	case .cli_error:    return .failed
	case .tty_panic:    return .failed
	// Same verdict as the panic, for the same reason: the fetch itself is fine,
	// the *child* could not run. It is not a host outage and must not be
	// reported as one — but it is not a success either.
	case .tty_unavailable: return .failed
	case .not_found:    return .failed
	}
	return .failed
}

// AUTH_MARKERS are what ssh prints when the transport worked and the *identity*
// was refused. Anything else at 255 is a connectivity failure.
//
// "Host key verification failed" is deliberately NOT here: that is the ssh
// trust/config path, not a refused credential, and lumping it into `auth` would
// send the user off to re-add a key when the fix is in known_hosts. The verbatim
// stderr is kept in `detail` either way, so nothing is lost.
AUTH_MARKERS := []string{
	"Permission denied",
	"permission denied",
	"Authentication failed",
	"Too many authentication failures",
	"no supported authentication methods",
	"Authentications that can continue",
}

ssh_failure_status :: proc(err_text: string) -> Device_Status {
	for m in AUTH_MARKERS {
		if strings.contains(err_text, m) { return .auth_failed }
	}
	return .unreachable
}

device_status_label ::proc(s: Device_Status) -> string {
	#partial switch s {
	case .pending:     return "pending"
	case .ok:          return "ok"
	case .timed_out:   return "timeout"
	case .unreachable: return "unreachable"
	case .no_herdr:    return "no herdr"
	case .auth_failed: return "auth"
	case .failed:      return "failed"
	}
	return "?"
}

//-----------------------------------------------------------------------------
// Registry
//-----------------------------------------------------------------------------

// Registry is the set of in-flight fetches. It owns nothing but the list; the
// caller owns the `^Fetch` values (see `registry_release` for the convenience).
Registry :: struct {
	items : [dynamic]^Fetch,

	// Diagnostics the tests read and the footer may show one day.
	wakeups    : int, // poll() calls that returned >0
	idle_wakes : int, // poll() calls that returned 0 (the clock, not bytes)
	kills      : int, // how many children we killed at our deadline
	loops        : int // step() iterations, i.e. frames we could have painted
}

// KILL_REAP_BUDGET is how long we are willing to stay in this call waiting for
// a child WE killed to be collectable. SIGKILL is not blockable and the kernel
// collects within microseconds, so 250 ms is already three orders of magnitude
// of slack; the budget exists only so an impossible kernel state cannot hang the
// UI thread forever.
KILL_REAP_BUDGET :: 250 * time.Millisecond

// kill_and_reap is the timeout close-out: SIGKILL, drain the pipes the dead
// child released, then COLLECT it.
//
// ⚠️ Reaping is not optional here. Settling the record without collecting the
// child leaves a zombie holding the pid table entry — which is T3.1's third
// trap ("a timeout that closes the pipes but never reaps is a zombie factory"),
// re-creating itself the moment the fan-out was made asynchronous. The first
// cut of this file did exactly that and `fetch-live` caught 3 zombies with the
// registry reporting every fetch cleanly settled, which is the whole reason the
// zombie test is in the suite and not a nice-to-have.
//
// If the collect genuinely will not complete, the fetch settles anyway (the
// caller must not wait on a child we have already killed) but is left marked
// un-reaped so `registry_reap_debts` keeps trying, and `registry_free` asserts
// it got there in the end.
kill_and_reap :: proc(f: ^Fetch) {
	if f.settled && f.reaped { return }
	t0 := time.now()
	for {
		fetch_drain(f)
		if fetch_reap(f) { return }
		if time.since(t0) > KILL_REAP_BUDGET { break }
		time.sleep(1 * time.Millisecond)
	}
	// Force the verdict, but do NOT claim the child was collected.
	f.reaped = false
	settle_exit(f, CAPTURE_EXIT_TIMEOUT)
}

// registry_reap_debts collects anything that settled before its child could be
// collected. Call it from a frame boundary; it is cheap when there are no debts.
registry_reap_debts :: proc(r: ^Registry) {
	for f in r.items {
		if !f.spawned || f.reaped { continue }
		if fetch_reap(f) { continue }
		// still not collectable — leave it live for the next sweep
	}
}

// registry_unreaped lists the devices whose child we never collected. Non-zero
// means we made a zombie.
registry_unreaped :: proc(r: ^Registry) -> int {
	n := 0
	for f in r.items {
		if f.spawned && f.settled && !f.reaped { n += 1 }
	}
	return n
}

registry_free :: proc(r: ^Registry) {
	// Final debt sweep: never exit with a child of ours uncollected.
	for _ in 0..<8 {
		if registry_unreaped(r) == 0 { break }
		registry_reap_debts(r)
	}
	for f in r.items { fetch_free(f) }
	delete(r.items)
}

registry_add :: proc(r: ^Registry, f: ^Fetch) {
	append(&r.items, f)
}

registry_pending :: proc(r: ^Registry) -> int {
	n := 0
	for f in r.items {
		if fetch_pending(f) { n += 1 }
	}
	return n
}

registry_settled :: proc(r: ^Registry) -> int {
	return len(r.items) - registry_pending(r)
}

registry_all :: proc(r: ^Registry) -> []^Fetch {
	return r.items[:]
}

// registry_fds fills `fds` with every fd still worth polling. This is the slice
// the real main loop appends to the tty/resize fds and hands to one poll().
registry_fds :: proc(r: ^Registry, fds: ^[dynamic]posix.pollfd) {
	for f in r.items { fetch_fds_watched(f, fds) }
}

// registry_min_remaining is the smallest deadline left across live fetches — the
// correct poll() timeout if we want to be awake exactly when the first child
// overruns.
registry_min_remaining :: proc(r: ^Registry) -> time.Duration {
	min_left := time.Duration(-1)
	for f in r.items {
		if !fetch_pending(f) { continue }
		left := fetch_remaining(f)
		if min_left < 0 || left < min_left { min_left = left }
	}
	if min_left < 0 { return 0 }
	return min_left
}

// registry_step runs one iteration of the loop in the header: drain whatever is
// readable, settle whatever finished, sleep until the next event, then kill
// whatever overran. `wait` is at most how long it sleeps.
//
// Returns the number of fetches still pending when it returns. A caller that
// wants the whole fan-out calls it until it says zero; a UI caller calls it once
// per frame with its own poll() over the union of fds.
registry_step :: proc(r: ^Registry, wait: time.Duration) -> int {
	r.loops += 1

	registry_pump(r)
	registry_settle_drained(r)
	if registry_pending(r) == 0 { return 0 }

	// Sleep until the first of: bytes on a watched fd, or the earliest deadline.
	// Whichever wakes us, the same three steps follow — that is what keeps the
	// deadline honest without a second timer anywhere.
	left := registry_min_remaining(r)
	if left > 0 {
		sleep_for := wait
		if sleep_for > POLL_SLICE { sleep_for = POLL_SLICE }
		if sleep_for > left { sleep_for = left }
		registry_poll(r, sleep_for)
		registry_pump(r)
		registry_settle_drained(r)
	}

	// Deadlines. Re-checked after the sleep because the sleep is the only thing
	// that can carry us past one.
	registry_expire(r)
	return registry_pending(r)
}

// registry_settle_drained reaps every child whose streams have both hit EOF.
//
// Reaping is attempted, never waited for: `fetch_reap` is WNOHANG-only, so a
// child that closed its pipes but has not been scheduled yet is simply picked up
// on the next pass instead of blocking this one.
registry_settle_drained :: proc(r: ^Registry) {
	for f in r.items {
		if f.closed || !fetch_pending(f) { continue }
		if fetch_drained(f) { fetch_reap(f) }
	}
}

// registry_pump drains every live fetch, not just the fd that woke us. See
// `fetch_drain` for why that is the safer contract.
registry_pump :: proc(r: ^Registry) {
	for f in r.items {
		if f.closed || !fetch_pending(f) { continue }
		fetch_drain(f)
	}
}

// registry_poll sleeps up to `wait` waiting for any watched fd.
registry_poll :: proc(r: ^Registry, wait: time.Duration) {
	fds := make([dynamic]posix.pollfd, 0, 32)
	defer delete(fds)
	registry_fds(r, &fds)
	if len(fds) == 0 {
		ms := int(time.duration_milliseconds(wait))
		if ms < 1 { ms = 1 }
		time.sleep(wait)
		r.idle_wakes += 1
		return
	}

	ms := int(time.duration_milliseconds(wait))
	if ms < 1 { ms = 1 }
	rv := posix.poll(&fds[0], posix.nfds_t(len(fds)), c.int(ms))
	if rv < 0 {
		if posix.errno() == posix.Errno.EINTR { return }
		return
	}
	if rv == 0 { r.idle_wakes += 1; return }
	r.wakeups += 1
}

// registry_expire enforces our own deadline: kill, then reap, then settle as
// timed_out. Done in that order on purpose — SIGKILL without the reap is the
// zombie factory, and reaping before the kill just misses.
registry_expire :: proc(r: ^Registry) {
	for f in r.items {
		if !fetch_pending(f) { continue }
		if time.since(f.started_at) < f.budget { continue }
		fetch_kill(f)
		r.kills += 1
		kill_and_reap(f)
	}
}

// registry_wait_all drives the fan-out to completion. Bounded by `overall` so a
// broken test cannot hang the suite; returns false if anything was left over.
registry_wait_all :: proc(r: ^Registry, overall: time.Duration) -> bool {
	started := time.now()
	for registry_pending(r) > 0 {
		if time.since(started) > overall { return false }
		registry_step(r, POLL_SLICE)
	}
	return true
}

// registry_status_for reads back one device's verdict after settling.
registry_status_for :: proc(r: ^Registry, device: string) -> (Device_Status, string, []Session) {
	for f in r.items {
		if f.device != device { continue }
		return f.status, f.detail, f.rows
	}
	return .pending, "no fetch for that device", nil
}

//-----------------------------------------------------------------------------
// T4.2 — Table: the merged, identity-keyed row set
//-----------------------------------------------------------------------------

// Table is what the sessions view reads. It holds rows and per-device status and
// *nothing else* — in particular no filter text and no caret, so a merge cannot
// reset state it does not own. See the header for why that is a design property
// and not a coincidence.
Table :: struct {
	rows    : [dynamic]Session,
	devices : [dynamic]Device,
}

table_free :: proc(t: ^Table) {
	delete(t.rows)
	delete(t.devices)
}

// table_destroy is the driver-side one-shot: free the dynamic arrays AND the
// heap Table. `delete()` in this Odin only takes dynamic arrays/maps/strings,
// so a `^Table` needs mem.free — wrapping it here means no test driver has to
// remember which of the two it is holding.
table_destroy :: proc(t: ^Table) {
	if t == nil { return }
	table_free(t)
	mem.free(t)
}

// table_reset_devices seeds the device groups from a Discovery, local first.
table_reset_devices :: proc(t: ^Table, devices: []Device) {
	clear(&t.devices)
	for d in devices {
		append(&t.devices, d)
	}
}

// table_device finds a device group by its VERBATIM target string. No matching,
// no normalising — `alice@box` and `box` are different groups, because they are
// different ssh invocations and possibly different machines.
table_device :: proc(t: ^Table, device: string) -> ^Device {
	for d, i in t.devices {
		if d.target == device { return &t.devices[i] }
	}
	return nil
}

// Merge_Report is what `merge` did, in counts. The tests assert against this
// rather than eyeballing the table, so "only that host's rows moved" is a number
// and not an impression.
Merge_Report :: struct {
	device  : string,
	added   : int,
	updated : int,
	removed : int,
	// Foreign is the count of rows belonging to OTHER devices, carried through
	// the merge untouched. `merge` guarantees they are byte-identical to the
	// input; the caller can hash them to prove it.
	carried : int,
	total   : int,
}

// merge replaces `device`'s row group with `fetched` and changes nothing else.
//
// Identity rules, each one a bug this exists to prevent:
//
//   * Rows are keyed on **(device, name)**. Names collide across hosts by
//     design (two boxes can each own `api`), so a name-only merge would
//     silently collapse two different sessions into one row — and then a
//     `delete` against that row would hit whichever one happened to survive.
//   * Removing the device's old rows and appending the new ones means a session
//     deleted on the host disappears on refresh, without any per-row guesswork.
//   * Rows of other devices are carried through by value and are never
//     re-derived, so host A cannot reorder, drop or rename host B's rows.
//   * The result is re-sorted with the model's own comparator, so `local` is
//     still first and each group is still timestamp-ascending.
merge :: proc(t: ^Table, device: string, fetched: []Session) -> Merge_Report {
	rep := Merge_Report{device = device}

	// 1. Keep every row that is NOT this device's. This is the isolation step:
	//    it is also the step that makes the whole merge provable, because the
	//    foreign rows are copied verbatim and never revisited.
	kept := make([dynamic]Session, 0, len(t.rows) + len(fetched))
	old_names := make(map[string]bool)
	for r in t.rows {
		if r.device != device {
			append(&kept, r)
			rep.carried += 1
			continue
		}
		old_names[r.name] = true
	}

	// 2. Now the device's group, from the fetch. `updated` is reported against
	//    the old group so the caller can see a refresh vs a first load.
	seen := make(map[string]bool)
	for r in fetched {
		if r.device != device {
			// Defensive: a producer that mis-tagged a row must not smuggle a
			// foreign row into this device's group.
			continue
		}
		if seen[r.name] { continue }
		seen[r.name] = true
		if old_names[r.name] { rep.updated += 1 } else { rep.added += 1 }
		append(&kept, r)
	}

	for name in old_names {
		if !seen[name] { rep.removed += 1 }
	}

	clear(&t.rows)
	for r in kept { append(&t.rows, r) }
	delete(kept)
	delete(old_names)
	delete(seen)

	sort_sessions(t.rows[:])
	rep.total = len(t.rows)
	return rep
}

// apply merges one *settled* fetch into the table and records the device status.
//
// A non-ok fetch merges **no rows** — that is the whole of ISC-15. It does not
// clear the group either: a host that goes unreachable mid-session keeps showing
// the last list we actually got, under a status that says we could not refresh
// it. Blanketing a host's rows on a network blip would be its own kind of lie.
apply :: proc(t: ^Table, f: ^Fetch) -> Merge_Report {
	rep := Merge_Report{device = f.device}
	if !f.settled {
		rep.device = f.device
		return rep
	}
	set_device_status(t, f.device, fetch_label(f), f.status, f.detail)
	if f.status == .ok {
		return merge(t, f.device, f.rows)
	}
	// Failed: report the shape of the table without claiming any change.
	for r in t.rows {
		if r.device == f.device { rep.carried += 1 }
	}
	rep.total = len(t.rows)
	return rep
}

// set_device_status records the per-host verdict, creating the group header if
// this is the first we have heard of the device.
set_device_status :: proc(t: ^Table, device, label: string, status: Device_Status, detail: string) {
	d := table_device(t, device)
	if d == nil {
		append(&t.devices, Device{target = device, label = label, status = status, detail = detail})
		return
	}
	d.status = status
	d.detail = detail
	if d.label == "" { d.label = label }
}

//-----------------------------------------------------------------------------
// T4.2 — Selection: identity, never index
//-----------------------------------------------------------------------------

// Selection is a held row expressed as its identity pair. The view keeps one of
// these instead of an index, and re-resolves it after every merge.
Selection :: struct {
	device : string,
	name   : string,
	valid  : bool,
}

NO_SELECTION :: Selection{device = "", name = "", valid = false}

selection_of :: proc(s: ^Session) -> Selection {
	return Selection{device = s.device, name = s.name, valid = true}
}

// selection_index resolves a held identity against the current rows.
// -1 means the session is gone (deleted locally or remotely), and the caller
// must decide what to show; it must NOT fall back to an index.
selection_index :: proc(rows: []Session, sel: Selection) -> int {
	if !sel.valid { return -1 }
	return index_of_identity(rows, sel.device, sel.name)
}

// selection_session is the resolved row, for `Enter` to act on. Returning the
// row rather than an index means the caller cannot act on one and read another.
selection_session :: proc(rows: []Session, sel: Selection) -> (^Session, bool) {
	i := selection_index(rows, sel)
	if i < 0 { return nil, false }
	return &rows[i], true
}

// selection_from_index snapshots the identity at an index — the only sanctioned
// way to turn "where the highlight is" into something a merge cannot move.
selection_from_index :: proc(rows: []Session, index: int) -> Selection {
	if index < 0 || index >= len(rows) { return NO_SELECTION }
	return selection_of(&rows[index])
}

//-----------------------------------------------------------------------------
// Local snapshot — the blocking inline fetch the first paint uses
//-----------------------------------------------------------------------------

// local_snapshot runs the local list synchronously and merges it. The first
// frame waits on this and nothing else: measured ~3 ms, against ~150 ms per
// remote host. Remote fetches are already in flight by the time it returns in
// the startup sequence — see `fetch_live` for the ordering proof.
local_snapshot :: proc(t: ^Table, budget: time.Duration) -> (Merge_Report, Capture) {
	c := run_capture(list_argv(), budget)
	rows, ok := parse_session_list(c.out, DEVICE_LOCAL, DEVICE_LOCAL)
	if !ok {
		set_device_status(t, DEVICE_LOCAL, DEVICE_LOCAL, .failed,
			"local herdr answered, but not with a session list")
		return Merge_Report{device = DEVICE_LOCAL, total = len(t.rows)}, c
	}
	set_device_status(t, DEVICE_LOCAL, DEVICE_LOCAL, .ok,
		fmt.tprintf("{} session(s)", len(rows)))
	return merge(t, DEVICE_LOCAL, rows), c
}
