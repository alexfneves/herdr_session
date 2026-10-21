package support

// ─────────────────────────────────────────────────────────────────────────────
// ledger.odin — THE reason this file exists.
//
// `core:testing` reports TESTS. The migration's governing rule is about
// ASSERTIONS: "fewer assertions after the move is a REGRESSION". A runner that
// answers "how many tests ran" cannot falsify that claim, and `odin test` on a
// package with no `@(test)` procs exits **0**. So the pass/fail verdict alone is
// not evidence — the count is.
//
// The ledger emits two things:
//
//   [HS] PASS|FAIL|SKIP <group>.<name> — <detail>   one per assertion
//   HS_TALLY <group> pass=N fail=N skip=N            cumulative per group
//
// HS_TALLY carries the **cumulative** counter of its group at the moment it is
// written, so the gate reads the MAXIMUM of each field rather than the last
// line. Monotonic counters + max() is what makes the reading correct under
// concurrent tests: with `-define:ODIN_TEST_THREADS=n` the cleanup windows of
// two tests overlap, so per-test *deltas* would be double-counted or dropped.
// Absolute counters cannot be double-counted. That is the whole reason the line
// is a cumulative snapshot and not a diff.
//
// A suite that never calls `check` emits no tally line at all. The gate treats a
// missing line as a failure, so "nothing asserted" can never look like "all
// passed". See tests/tools/hscheck.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "base:runtime"

// Sizing. Both are generous against what these suites actually hold (~20 test
// files, ~150 tests) and EXCEEDING is a loud failure rather than a silent
// merge: the table traps.
MAX_GROUPS        :: 256
MAX_REGISTRATIONS :: 4096
MAX_GROUP_NAME    :: 64

Group :: struct {
	name : [MAX_GROUP_NAME]u8, // the caller's file basename, extension stripped
	nlen : int,
	pass : int,
	fail : int,
	skip : int,
	used : bool,
}

Registration :: struct {
	t     : ^testing.T,
	group : ^Group,
	used  : bool,
}

Ledger :: struct {
	mu       : sync.Mutex,
	groups   : [MAX_GROUPS]Group,
	n_groups : int,
	regs     : [MAX_REGISTRATIONS]Registration,
	n_regs   : int,
	// Totals across every group, kept so the global count is checkable against
	// the sum of the per-group tallies. If they ever disagree the ledger itself
	// is broken and the gate says so rather than picking one of the two.
	pass : int,
	fail : int,
	skip : int,
}

// STATIC, deliberately. A heap-allocated ledger is allocated against whichever
// test's context allocator happened to run first, and `core:testing` frees that
// allocator when that test ends — leaving every later `^Group` handed to a
// cleanup pointing at freed memory. That is a real segfault, found here, not a
// hypothetical. A zero-initialised global has process lifetime, cannot leak, and
// costs nothing.
led : Ledger = {}

//-----------------------------------------------------------------------------
// Groups
//-----------------------------------------------------------------------------

// group_label is the identity a set of assertions is tallied under. It comes
// from THE CALLER'S FILE NAME (basename, extension stripped) rather than from a
// string each test has to remember to pass. A declaration a test can forget is
// not a contract; a file name is.
//
// `tests/unit/diag_test.odin` -> `diag_test`. The gate maps a group to a
// `tests/parity.tsv` row by longest-prefix match on the `files` column, so the
// suite named `diag` owns `diag_test`, `diag_head_test`, … and any group no row
// claims is reported as UNACCOUNTED instead of quietly landing in some other
// suite's total.
group_label :: proc(loc: runtime.Source_Code_Location) -> string {
	path := loc.file_path
	base := path
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			base = path[i+1:]
			break
		}
	}
	dot := -1
	for i := len(base) - 1; i >= 0; i -= 1 {
		if base[i] == '.' {
			dot = i
			break
		}
	}
	if dot > 0 { base = base[:dot] }
	return base
}

// group returns the table entry for `label`, creating it on first use.
group :: proc(label: string) -> ^Group {
	sync.mutex_lock(&led.mu)
	defer sync.mutex_unlock(&led.mu)

	for i in 0 ..< led.n_groups {
		g := &led.groups[i]
		if g.used && name_is(g, label) { return g }
	}
	if led.n_groups >= MAX_GROUPS {
		fmt.eprintfln("[HS] FATAL ledger group table full (MAX_GROUPS={}) — assertions would be silently dropped", MAX_GROUPS)
		trap()
	}
	g := &led.groups[led.n_groups]
	g.used = true
	g.nlen = len(label)
	for i in 0 ..< len(label) { g.name[i] = label[i] }
	led.n_groups += 1
	return g
}

group_name :: proc(g: ^Group) -> string {
	return string(g.name[:g.nlen])
}

name_is :: proc(g: ^Group, label: string) -> bool {
	if g.nlen != len(label) { return false }
	for i in 0 ..< g.nlen {
		if g.name[i] != label[i] { return false }
	}
	return true
}

//-----------------------------------------------------------------------------
// The tally line
//-----------------------------------------------------------------------------

// ensure_tally registers, once per (test, group), the cleanup that emits that
// group's cumulative tally when the test ends. core:testing runs cleanups even
// after a fault, so a segfaulting test still reports how far it got instead of
// reporting nothing.
//
// Registering twice for the same (test, group) is avoided rather than merely
// tolerated: the line is cumulative so a duplicate would be harmless, but it
// would grow the log for no reason.
ensure_tally :: proc(t: ^testing.T, g: ^Group) {
	sync.mutex_lock(&led.mu)
	defer sync.mutex_unlock(&led.mu)

	for i in 0 ..< led.n_regs {
		r := &led.regs[i]
		if r.used && r.t == t && r.group == g { return }
	}
	if led.n_regs >= MAX_REGISTRATIONS {
		fmt.eprintfln("[HS] FATAL ledger registration table full (MAX_REGISTRATIONS={}) — the tally would stop being emitted for new tests", MAX_REGISTRATIONS)
		trap()
	}
	r := &led.regs[led.n_regs]
	r.used = true
	r.t = t
	r.group = g
	// The cleanup's ONLY job is a formatted write of counters that already
	// exist. It must never fault (core:testing runs it as the last thing that
	// will ever run for this test) and it must not allocate, so it reads a
	// pointer we hand it rather than closing over anything.
	testing.cleanup(t, tally_cleanup, transmute(rawptr)(g))
}

tally_cleanup :: proc(raw: rawptr) {
	g := transmute(^Group)(raw)
	if g == nil { return }
	fmt.printfln("HS_TALLY {} pass={} fail={} skip={}",
		group_name(g),
		sync.atomic_load(&g.pass),
		sync.atomic_load(&g.fail),
		sync.atomic_load(&g.skip))
}

// tally_line writes a tally for one group right now. Public so a driver can
// force a checkpoint mid-run; the gate's max() rule makes an extra line
// harmless and a missing one fatal.
tally_line :: proc(label: string) {
	g := group(label)
	fmt.printfln("HS_TALLY {} pass={} fail={} skip={}",
		label,
		sync.atomic_load(&g.pass),
		sync.atomic_load(&g.fail),
		sync.atomic_load(&g.skip))
}

Totals :: struct {
	pass   : int,
	fail   : int,
	skip   : int,
	groups : int,
}

// totals is the whole-ledger picture.
totals :: proc() -> Totals {
	sync.mutex_lock(&led.mu)
	defer sync.mutex_unlock(&led.mu)
	return Totals{pass = led.pass, fail = led.fail, skip = led.skip, groups = led.n_groups}
}

// sum_groups walks the table. `totals()` and `sum_groups()` MUST agree; the gate
// asserts it. Kept separate so a mismatch is observable rather than smoothed
// over by one accessor that picks a number.
sum_groups :: proc() -> Totals {
	sync.mutex_lock(&led.mu)
	defer sync.mutex_unlock(&led.mu)
	out : Totals = {}
	out.groups = led.n_groups
	for i in 0 ..< led.n_groups {
		g := &led.groups[i]
		if !g.used { continue }
		out.pass += g.pass
		out.fail += g.fail
		out.skip += g.skip
	}
	return out
}

//-----------------------------------------------------------------------------
// The assertion primitive
//-----------------------------------------------------------------------------

// check is the one counted assertion. It gives `core:testing` the pass/fail
// verdict AND records the assertion so the outer gate can count them.
//
// `detail` is always passed to fmt as a VALUE, never as the format string. A
// caller-supplied format string is how `%!` gets into an evidence line that
// still reads as a pass; fmtguard catches that, this avoids producing it.
check :: proc(t: ^testing.T, name: string, cond: bool, detail: string, loc := #caller_location) {
	label := group_label(loc)
	g := group(label)
	ensure_tally(t, g)

	if cond {
		sync.mutex_lock(&led.mu)
		g.pass += 1
		led.pass += 1
		sync.mutex_unlock(&led.mu)
		fmt.printfln("[HS] PASS {}.{} — {}", label, name, detail)
	} else {
		sync.mutex_lock(&led.mu)
		g.fail += 1
		led.fail += 1
		sync.mutex_unlock(&led.mu)
		fmt.printfln("[HS] FAIL {}.{} — {}", label, name, detail)
	}
	testing.expectf(t, cond, "{}.{} — {}", label, name, detail)
}

// skip records a check that did NOT run. Skipping is not passing: the gate
// turns a non-zero skip red unless the run declares the suite optional
// (--allow-skip). The reason is mandatory because "skipped" with no sentence
// beside it is how a missing fixture becomes invisible.
skip :: proc(t: ^testing.T, name: string, reason: string, loc := #caller_location) {
	label := group_label(loc)
	g := group(label)
	ensure_tally(t, g)

	sync.mutex_lock(&led.mu)
	g.skip += 1
	led.skip += 1
	sync.mutex_unlock(&led.mu)
	fmt.printfln("[HS] SKIP {}.{} — {}", label, name, reason)
}

// note replaces the old `say()`. It writes to STDOUT with a stable prefix
// instead of `log.info` on purpose: ODIN_TEST_LOG_LEVEL can silence the logging
// package, and an evidence line that can be silenced by an environment variable
// is not evidence.
note :: proc(t: ^testing.T, msg: string, loc := #caller_location) {
	label := group_label(loc)
	fmt.printfln("[HS] NOTE {} — {}", label, msg)
}

// note_raw is the `say_raw` equivalent: the line goes out exactly as given, no
// prefix, no reformatting, for table output where the indentation carries
// meaning.
note_raw :: proc(t: ^testing.T, line: string) {
	fmt.println(line)
}

//-----------------------------------------------------------------------------
// Thin counted comparators — the B6 mapping targets
//-----------------------------------------------------------------------------
//
// The pre-migration harness had `eq`/`eq_i`/`ne_i` alongside `check`. These are
// the counted equivalents so a port is a mechanical prefix, not a rewrite.

eq :: proc(t: ^testing.T, name: string, got, want: string, loc := #caller_location) {
	check(t, name, got == want, fmt.tprintf("got '{}' want '{}'", got, want), loc=loc)
}

ne :: proc(t: ^testing.T, name: string, got, not_want: string, loc := #caller_location) {
	check(t, name, got != not_want, fmt.tprintf("got '{}' want anything but '{}'", got, not_want), loc=loc)
}

eq_i :: proc(t: ^testing.T, name: string, got, want: int, loc := #caller_location) {
	check(t, name, got == want, fmt.tprintf("got {} want {}", got, want), loc=loc)
}

ne_i :: proc(t: ^testing.T, name: string, got, not_want: int, loc := #caller_location) {
	check(t, name, got != not_want, fmt.tprintf("got {} want anything but {}", got, not_want), loc=loc)
}

//-----------------------------------------------------------------------------
// B3 — the `any_failed` replacement
//-----------------------------------------------------------------------------
//
// The pre-migration harness kept a package-level `any_failed : bool`, and
// several suites (the save/restore pattern at src/state_cases.odin:1349-1358)
// READ it mid-suite to decide whether an enclosing block had already gone red,
// so they could roll it back and keep going. `core:testing` has no
// process-wide failure flag by design — failure lives on the `^testing.T`, per
// test.
//
// DECISION: `any_failed` is NOT ported. It is replaced by the test's own
// `error_count` read across a block, which is strictly better on three counts:
//
//   1. It is per-test, so a failure in test A can no longer poison test B's
//      block — a cross-contamination the global made possible.
//   2. It needs no restore. The old shape was
//          saved = any_failed; any_failed = false; …run…; had = any_failed;
//          any_failed = saved
//      which is a try/finally hand-written in the wrong language, and one
//      missed restore line silently makes every later block in the suite look
//      broken. `mark` + `block_failed` is the same shape with nothing to put
//      back.
//   3. It counts. `error_count` moves only when a real assertion fires, so a
//      block cannot "fail" without a counted assertion behind it.
//
// Porting the save/restore sites:
//          before := support.mark(t)
//          …the inner battery…
//          if support.block_failed(t, before) { …the "something above failed"
//          branch… }
// with the surrounding suite becoming one `@(test)` proc per formerly-shared
// block, which removes the shared-state reason the global existed.

// mark snapshots the test's failure count.
mark :: proc(t: ^testing.T) -> int {
	return t.error_count
}

// block_failed is true when any assertion since `before` failed.
block_failed :: proc(t: ^testing.T, before: int) -> bool {
	return t.error_count != before
}

// trap stops the process now, for a harness-inconsistent state where continuing
// would report numbers that are not true. 70 is not a test-failure code: the
// gate reads a non-zero exit with no tally as "the harness broke", which is the
// honest answer.
trap :: proc() {
	fmt.eprintfln("[HS] ledger trap — aborting rather than reporting unsound numbers")
	os.exit(70)
}
