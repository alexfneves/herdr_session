package hsfixture

// fixture_test.odin — the gate's positive fixture: exactly ONE test making
// exactly ONE counted assertion.
//
// Deliberately minimal. This binary exists so the gate can be shown passing
// against a real ledger with a real `HS_TALLY` line, and so "the gate passed"
// is not the same sentence as "nothing ran".

import "core:testing"

import support "../../../support"

@(test)
one_counted_assertion :: proc(t: ^testing.T) {
	support.check(t, "the fixture asserts exactly one true thing", true,
		"true is true, and it was counted")
}
