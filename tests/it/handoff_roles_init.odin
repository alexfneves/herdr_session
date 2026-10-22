package it

// ─────────────────────────────────────────────────────────────────────────────
// handoff_roles_init.odin — lets the TEST BINARY re-exec ITSELF as the app and
// as the child probes of the T11 handoff suite.
//
// Why: a handoff test has three kinds of process — the one that owns the pty and
// makes the counted assertions, the one that owns the terminal while the handoff
// runs, and the child that the terminal is handed to. If those were three
// separately built binaries the test would have to locate them at run time, and
// "we could not find the probe binary" is the classic way a suite quietly turns
// into skips. With the role code reachable from this package, the test process
// knows exactly one path — its own — and `os.get_executable_path` answers it.
//
// HOW IT IS SAFED: this init proc runs on EVERY start of this binary, so it is
// a no-op unless $HS_ROLE is set to a non-empty value. The test process never
// has it set for itself; it is set only in the environment of a spawn, by the
// harness, immediately before the fork and unset immediately after. An unknown
// role name exits 2 loudly rather than falling through to "the tests ran fine".
//
// `proc "contextless"` is required by the language for @(init); a context is
// installed locally before doing anything that allocates.
// ─────────────────────────────────────────────────────────────────────────────

import hsapp "../probes/hsapp"

import "core:fmt"
import "core:os"

import "base:runtime"

@(init)
handoff_role_dispatch :: proc "contextless" () {
	context = runtime.default_context()
	role := os.get_env_alloc(hsapp.ROLE_ENV, context.allocator)
	if len(role) == 0 { return }
	code := hsapp.claim_and_run()
	if code < 0 { return }
	fmt.eprintf("[hsrole] role '{}' exited {}\n", role, code)
	os.exit(code)
}
