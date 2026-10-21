package unit

// ─────────────────────────────────────────────────────────────────────────────
// state_safety_test.odin — T6 port of dev/state-smoke.sh section 4.
//
// ONE counted assertion: the real `herdr session list` is byte-identical after
// the battery has run. Plus one ADDITIVE assertion that the snapshot was not
// EMPTY, because an equality between two empty lists proves nothing at all.
//
// WHY THIS IS SELF-CONTAINED
//
// The bash harness took its "before" snapshot, then re-ran `$BIN state-machine`
// as a child, then took its "after". That shape depends on the child actually
// having run: drop the re-run and the two snapshots bracket nothing while still
// printing green. Here the SAME proc both drives the battery and takes the two
// snapshots, so the assertion cannot be separated from the thing it is about.
//
// The battery is driven through st_render_machine() — the full
// transition-driving pass rendered with NO ledger. That matters for two
// reasons: it keeps this file's counted total at exactly its own two
// assertions (no double-tallying the machine group), and it still exercises
// every (state x key) pair against the real machine, because `render` only
// suppresses reporting, not the driving.
//
// WHY A FAILED CAPTURE IS A FAILURE AND NOT A SKIP
//
// dev/state-smoke.sh printed "no herdr on PATH — nothing COULD have been
// touched. Skipped." and counted nothing. That was affordable when the suite's
// total was whatever the shell happened to add up. It is not affordable under a
// gate that treats an undeclared skip as red and a shortfall as a regression:
// the honest reading is that the safety proof DID NOT RUN, which is a failure
// with a reason attached, not a pass and not a silent hole. The 259 floor was
// measured with a reachable herdr; a box without one is a different box and
// should say so out loud.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import support "../support"
import sessionfix "../support/sessionfix"

@(test)
state_safety_real_session_list_untouched :: proc(t: ^testing.T) {
	before := sessionfix.names_snapshot()

	// The run whose side effects we are measuring. Render mode = every
	// transition driven, nothing reported.
	driven := st_render_machine()

	after := sessionfix.names_snapshot()

	why := ""
	if !before.ok { why = fmt.tprintf("{} [before capture: {}]", why, before.note) }
	if !after.ok { why = fmt.tprintf("{} [after capture: {}]", why, after.note) }

	support.check(t, "the real herdr session list is byte-identical after the run",
		before.ok && after.ok && before.raw == after.raw,
		fmt.tprintf("before.ok={} after.ok={} before=[{}] after=[{}] ({} bytes of battery output driven between them){}",
			before.ok, after.ok, before.raw, after.raw, len(driven), why))
}

@(test)
state_safety_snapshot_is_not_vacuous :: proc(t: ^testing.T) {
	snap := sessionfix.names_snapshot()
	// The headline assertion above compares two lists. Two EMPTY lists are
	// byte-identical too, and a safety check that can be satisfied by the
	// harness being broken is worse than no check.
	support.check(t, "ADDITIVE: the session snapshot was non-empty, so the identity above is not vacuous",
		snap.ok && len(snap.list) > 0,
		fmt.tprintf("ok={} sessions={} raw=[{}]", snap.ok, len(snap.list), snap.raw))
}
