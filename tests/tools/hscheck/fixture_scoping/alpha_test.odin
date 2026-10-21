package scoping_fixture

import "core:testing"

import support "../../../support"

// alpha_test.odin — the group the row under test CLAIMS. 3 assertions.
//
// Paired with beta_test.odin in the same package: one binary, two ledger
// groups, only one claimed. That is the minimum setup that can tell
// "the gate counted my suite" apart from "the gate counted the log".
//
// Before claims.odin, one parity row pointed at a multi-group binary reported
// the SUM of every group against that one row's floor. Per-suite parity was
// then unfalsifiable -- the number did not describe the thing it named.
//
// The group name comes from this FILE's basename via the ledger. The fixture
// deliberately does not pass a label to the gate: the derivation from the
// filename is the mechanism under test.

@(test)
alpha_one :: proc(t: ^testing.T) {
	support.eq(t, "alpha assertion 1", "a", "a")
}

@(test)
alpha_two :: proc(t: ^testing.T) {
	support.eq(t, "alpha assertion 2", "b", "b")
}

@(test)
alpha_three :: proc(t: ^testing.T) {
	support.eq(t, "alpha assertion 3", "c", "c")
}
