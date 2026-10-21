package support

// ─────────────────────────────────────────────────────────────────────────────
// scratch.odin — the hs-t-* NAMING INTERLOCK.
//
// This file deliberately imports NOTHING from the product. The live snapshot /
// create / destroy plumbing lives in `tests/support/sessionfix`, a separate
// package, because `app` pulls `src/terminal`, whose `package terminal` clause
// collides with `core:terminal` (pulled by core:testing -> core:log) and makes
// ANY test binary that imports `support` fail to link. Keeping the interlock
// app-free means every agent can assert the rule without inheriting that.
//
// These suites run against the developer's REAL herdr install. Live user
// sessions were named untouchable before this work started, and the whole
// safety story rests on one rule:
//
//     A scratch session is named hs-t-* and nothing else is ever destroyed.
//
// So the prefix test is not a naming convention, it is the safety interlock,
// and it lives in exactly one place. `destroy` refuses anything the prefix does
// not vouch for, at run time, every time — including names this block believes
// it created itself. A rule enforced only by documentation is a rule that fails
// the first time someone is tired.
//
// Teardown is registered as a core:testing CLEANUP, never as a trailing
// statement. A suite that creates a scratch session and then fails an assertion
// without restoring it leaves the session list changed for every suite that
// runs afterwards — which is the "a later case inherits an earlier case's
// state" failure the no-log-concatenation rule is about, one level down.
// ─────────────────────────────────────────────────────────────────────────────


SCRATCH_PREFIX :: "hs-t-"

// is_scratch is the interlock predicate. Deliberately total: the bare prefix,
// `hs-t` without the dash, and a name with a space or slash in it are all
// rejected, because each is a plausible typo that would otherwise be aimed at a
// real session.
is_scratch :: proc(name: string) -> bool {
	if len(name) <= len(SCRATCH_PREFIX) { return false }
	pfx := SCRATCH_PREFIX
	for i := 0; i < len(pfx); i += 1 {
		if name[i] != pfx[i] { return false }
	}
	for i := len(SCRATCH_PREFIX); i < len(name); i += 1 {
		if name[i] == '/' || name[i] == ' ' || name[i] == '\n' { return false }
	}
	return true
}

