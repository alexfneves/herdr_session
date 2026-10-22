package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_cleanup_test.odin — T10 port of `unit_cleanup` (src/app_cases.odin:764).
//
// The shipped default is `only_created` (RCH-3/R1, resolving the parked D2):
// sessions THIS app created are destroyed after the handoff returns; sessions
// it merely attached to are left alone.
//
// ONE MUTATION, RESTORED IN THE SAME PROC
//
// `set_cleanup_policy` is a process-wide seam and this binary runs its tests
// concurrently-by-file. The set/restore pair therefore lives inside a single
// @(test) proc — it cannot leak across a group boundary the way the old
// driver's ordering implied. support.set_int below restores unconditionally.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import app "../../src/app"
import support "../support"

@(test)
app_cleanup_default_policy :: proc(t: ^testing.T) {
	c := au_live(t)
	au_eq(&c, "default policy is 'only_created' (R1)",
		au_policy_text(app.DEFAULT_CLEANUP_POLICY), "only_created")
	au_eq(&c, "current policy is the default",
		au_policy_text(app.cleanup_policy()), "only_created")
}

@(test)
app_cleanup_should_run_table :: proc(t: ^testing.T) {
	c := au_live(t)
	au_check(&c, "never → nothing destroyed, even for a session we created",
		!app.cleanup_should_run(.never, "hs-t-x", true), "")
	au_check(&c, "never → nothing destroyed, even for the user's own session",
		!app.cleanup_should_run(.never, "user-session", false), "")
	au_check(&c, "only_created → destroys only what we created",
		app.cleanup_should_run(.only_created, "hs-t-x", true) &&
			!app.cleanup_should_run(.only_created, "user-session", false), "")
	au_check(&c, "always → destroys (available but not the default)",
		app.cleanup_should_run(.always, "anything", false), "")
	au_check(&c, "D12 outranks EVERY policy: default is never destroyed",
		!app.cleanup_should_run(.always, "default", true) &&
			!app.cleanup_should_run(.only_created, "default", true), "")
}

@(test)
app_cleanup_policy_seam_is_reversible :: proc(t: ^testing.T) {
	c := au_live(t)
	// The seam is settable, so un-parking D2 is one assignment and nothing
	// else. Restored in the same proc whether or not the assertions passed:
	// a leaked policy would change what every later test in this binary sees.
	app.set_cleanup_policy(.only_created)
	set_ok := au_policy_text(app.cleanup_policy()) == "only_created"
	app.set_cleanup_policy(app.DEFAULT_CLEANUP_POLICY)
	restored_ok := au_policy_text(app.cleanup_policy()) == "only_created"

	au_check(&c, "policy is settable at runtime (the seam works)", set_ok,
		fmt.tprintf("after set: {}", au_policy_text(app.cleanup_policy())))
	au_check(&c, "policy restored to the shipped default", restored_ok,
		fmt.tprintf("after restore: {}", au_policy_text(app.cleanup_policy())))
}
