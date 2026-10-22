package main

// ─────────────────────────────────────────────────────────────────────────────
// handoff_app — standalone build of the T11 handoff suite's app-role/probe
// roles. The suite itself does NOT need this binary: it re-execs its own test
// binary through the @(init) dispatcher in tests/it/handoff_roles_init.odin,
// which reaches the same code in package hsapp.
//
// This wrapper exists so a human can run a role directly while debugging:
//
//   odin build ./tests/it/probes/handoff_app -out:/tmp/handoff_app
//   HS_EVIDENCE=/tmp/e.log HS_ROLE=handoff  /tmp/handoff_app
//   HS_EVIDENCE=/tmp/e.log HS_ROLE=child HS_CHILD_ROLE=env-probe \
//     HS_CHILD_CWD=/tmp HS_LEAK='HERDR_ENV=1;HERDR_SESSION=x' /tmp/handoff_app
//
// Role names are in hsapp.run_role. They are taken from $HS_ROLE (same as the
// suite's) or, as a convenience for hand runs, from argv[1].
// ─────────────────────────────────────────────────────────────────────────────

import hsapp "../hsapp"

import "core:fmt"
import "core:os"

main :: proc() {
	role := os.get_env_alloc(hsapp.ROLE_ENV, context.allocator)
	args := os.args
	if len(role) == 0 && len(args) > 1 {
		role = args[1]
		os.set_env(hsapp.ROLE_ENV, role)
	}
	if len(role) == 0 {
		fmt.eprintln("usage: HS_ROLE={abi|double|handoff|child|sig-term|env-probe|sig-probe|exit7} handoff_app")
		os.exit(2)
	}
	code := hsapp.run_role(role)
	if code < 0 {
		os.exit(2)
	}
	os.exit(int(code))
}
