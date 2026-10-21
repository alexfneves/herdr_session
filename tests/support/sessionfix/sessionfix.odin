package sessionfix

// sessionfix.odin — the live hs-t-* lifecycle against a real herdr install.
//
// Split out of tests/support/scratch.odin. The naming interlock
// (`support.is_scratch`) stays app-free in `support` so every agent can assert
// the rule cheaply; only THIS package imports the product, because `app` pulls
// `src/terminal`, whose `package terminal` clause collides with `core:terminal`
// (reached from core:testing -> core:log) and breaks linking of any test binary
// that inherits it.
//
// The rule, restated: a scratch session is named hs-t-* and nothing else is
// ever destroyed. The predicate that enforces it is `support.is_scratch`, and
// it is checked at run time on EVERY destroy — including on names this block
// believes it created itself.
//
// Teardown is registered as a core:testing CLEANUP, never as a trailing
// statement, so the session list is restored on the failure path too. That is
// exactly when it matters and exactly when a trailing statement does not run.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

import support ".."
import app "../../../src/app"

SNAPSHOT_TIMEOUT :: 10 * time.Second
DESTROY_TIMEOUT  :: 15 * time.Second

// Names :: a sorted, settled snapshot of the session list.
//
// Sorted so two snapshots compare by equality rather than by whatever order
// herdr returned. Comparing unordered sets as ordered lists turns a stable
// system into a flaky one, and a flaky teardown assertion is one that gets
// loosened.
//
// `ok` is the honest tri-state: a capture that FAILED and a capture that came
// back EMPTY are different facts, and collapsing them is how the RCH-3 trap
// (moving XDG_CONFIG_HOME moves herdr's own state dir, so `session list`
// returns empty) would turn "the harness is broken" into "restored to empty,
// PASS".
Names :: struct {
	list : [dynamic]string,
	raw  : string,
	ok   : bool,
	note : string,
}

names_snapshot :: proc() -> Names {
	out : Names = {}
	rc := app.run_capture(app.list_argv(), SNAPSHOT_TIMEOUT)
	if !rc.spawned {
		out.ok = false
		out.note = "the herdr capture never spawned"
		return out
	}
	if rc.timed_out {
		out.ok = false
		out.note = "the herdr capture timed out"
		return out
	}
	if rc.code != 0 {
		out.ok = false
		out.note = fmt.tprintf("herdr session list exit={}", rc.code)
		return out
	}
	payload := transmute([]byte)(string(rc.out))
	if !app.has_sessions_field(payload) {
		out.ok = false
		out.note = "herdr answered but carried no `sessions` array"
		return out
	}
	sessions, pok := app.parse_session_list(payload, app.DEVICE_LOCAL, "local")
	if !pok {
		out.ok = false
		out.note = "the sessions array did not parse"
		return out
	}
	for s in sessions { append(&out.list, s.name) }
	sort_strings(out.list[:])
	out.raw, _ = strings.join(out.list[:], ",")
	out.ok = true
	return out
}

// sort_strings — insertion sort. The list is a handful of sessions, and this
// keeps an allocator-dependent comparator out of a module whose correctness the
// whole teardown rests on.
sort_strings :: proc(xs: []string) {
	for i := 1; i < len(xs); i += 1 {
		j := i
		for j > 0 {
			if xs[j-1] <= xs[j] { break }
			tmp := xs[j-1]
			xs[j-1] = xs[j]
			xs[j] = tmp
			j -= 1
		}
	}
}

// Scratch :: one fixture block's claim on the session namespace.
Scratch :: struct {
	label   : string,
	before  : Names,
	created : [dynamic]string,
	t       : ^testing.T,
	armed   : bool,
	closed  : bool,
}

// begin snapshots the session list and registers the teardown.
//
// The snapshot is asserted to have SUCCEEDED, not merely to exist. Without
// that, a snapshot that came back empty because herdr is missing returns
// `raw == ""` and "restored to ''" then passes against a harness that never
// talked to anything.
begin :: proc(t: ^testing.T, label: string) -> Scratch {
	s : Scratch = {}
	s.label = label
	s.t = t
	s.before = names_snapshot()

	support.check(t, fmt.tprintf("{}: pre-snapshot of the herdr session list taken", label),
		s.before.ok,
		fmt.tprintf("before = [{}] {}", s.before.raw, s.before.note))

	// Registered only when there is something to restore. An unarmed block has
	// no claim on the namespace and must not run a teardown that acts on a
	// snapshot it never validly took.
	if s.before.ok {
		// cast, not transmute: pointer -> pointer (see ledger.odin).
	testing.cleanup(t, teardown_cb, cast(rawptr)(&s))
		s.armed = true
	}
	return s
}

teardown_cb :: proc(raw: rawptr) {
	s := cast(^Scratch)(raw)
	if s == nil { return }
	end(s)
}

// create records a session this block is about to make, and REFUSES a name the
// prefix does not vouch for before anything is created. Checking after the
// create would mean the mistake is only discoverable at teardown — by which
// time it is a live session the guard will not let us remove.
create :: proc(s: ^Scratch, name: string) -> bool {
	if !s.armed || s.closed {
		support.check(s.t, fmt.tprintf("{}: create outside an open scratch block", s.label), false,
			fmt.tprintf("armed={} closed={}", s.armed, s.closed))
		return false
	}
	if !support.is_scratch(name) {
		support.check(s.t, fmt.tprintf("{}: scratch name rejected before creation", s.label), false,
			fmt.tprintf("'{}' does not start with '{}'", name, support.SCRATCH_PREFIX))
		return false
	}
	append(&s.created, name)
	return true
}

// destroy is the only place a session is destroyed, and the guard runs on every
// single call — not "once, when the name was minted". If a bug ever puts a real
// user's name into `created`, this is the last line that stops it.
destroy :: proc(s: ^Scratch, name: string) -> bool {
	if !support.is_scratch(name) {
		support.check(s.t, fmt.tprintf("{}: REFUSED to destroy a non-scratch session", s.label), false,
			fmt.tprintf("'{}' is not '{}-…' — treated as a real session, never touched",
				name, support.SCRATCH_PREFIX))
		return false
	}

	// stop then delete, each routed through the product's own argv builder so a
	// remote scratch name reaches the right host the same way the UI does it.
	stop := app.run_capture(app.control_argv(app.DEVICE_LOCAL, {"stop", name}), DESTROY_TIMEOUT)
	del := app.run_capture(app.control_argv(app.DEVICE_LOCAL, {"delete", name}), DESTROY_TIMEOUT)

	gone := session_gone(name)
	support.check(s.t, fmt.tprintf("{}: scratch session {} is gone", s.label, name), gone,
		fmt.tprintf("stop exit={} delete exit={} still-present={}",
			stop.code, del.code, !gone))
	return gone
}

session_gone :: proc(name: string) -> bool {
	now := names_snapshot()
	if !now.ok { return false }
	for n in now.list {
		if n == name { return false }
	}
	return true
}

// end restores the list and asserts the round trip. This is the counted
// assertion that makes the safety story falsifiable: not "we tried to clean
// up" but "the list is what it was, byte for byte".
end :: proc(s: ^Scratch) {
	if s.closed { return }
	s.closed = true
	if !s.armed { return }

	for n in s.created {
		if support.is_scratch(n) { destroy(s, n) }
	}

	after := names_snapshot()
	if !after.ok {
		support.check(s.t, fmt.tprintf("{}: post-snapshot of the herdr session list taken", s.label),
			false, fmt.tprintf("post-snapshot failed: {}", after.note))
		return
	}
	support.eq(s.t,
		fmt.tprintf("{}: the herdr session list is restored byte-for-byte", s.label),
		after.raw, s.before.raw)
}
