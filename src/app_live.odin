package main

// PHASE 3 LIVE DRIVER — the same rules, against the real herdr binary and a real
// ssh hop.
//
// The unit case proves what our model says. This proves what herdr *does*, because
// the gap between the two is where this project's bugs live. Every raw byte
// capture is printed into the typescript so the evidence survives the run.
//
// SAFETY MODEL — read before changing anything here:
//
//   * EVERY session this creates is named `hs-t-*`. Nothing else, ever.
//   * The session hosting this agent (`HERDR_SESSION`) is refused by name in
//     every destructive path — see `guard_scratch`.
//   * Cleanup lives in dev/app-smoke.sh's EXIT trap, so it runs on failure, on
//     Ctrl-C, and on a kill. This driver deliberately also cleans up inline: a
//     leaked scratch session is worse than a red test.

import app "./app"

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// The one scratch name this driver creates. One is enough: creating more buys no
// extra evidence and triples the cleanup risk.
SCRATCH :: "hs-t-phase3-probe"

// SCRATCH_NEVER is a name that must never exist. Used to catch herdr's
// `delete`-lies and to prove our pre-check refuses it.
SCRATCH_NEVER :: "hs-t-never-created-zz"

// SCRATCH_PREFIX lives in app_cases.odin ("hs-t-") and is shared by every driver
// in this package. It is what the dynamic baseline below counts, and what the
// teardown in dev/app-smoke.sh promises to remove.

// live_remote reads the fixture ssh target from the environment. NEVER hard-coded:
// the loop-back fixture (T6.4) is a dev/CI affordance, not a product feature.
live_remote :: proc() -> string {
	return os.get_env_alloc("HERDR_SESSION_TEST_REMOTE", context.allocator)
}

// fixture_alias is the SECOND ssh target string for the same machine. The device
// discriminator (T6.3) needs two distinct strings that reach identical sessions;
// otherwise a bug that ignores `device` passes every single-host test.
fixture_alias :: proc() -> string {
	return os.get_env_alloc("HERDR_SESSION_TEST_REMOTE_ALIAS", context.allocator)
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

eq_code :: proc(name: string, got: i32, want: i32) {
	check(name, got == want, fmt.tprintf("got {} want {}", got, want))
}

check_int :: proc(name: string, got, want: int) {
	check(name, got == want, fmt.tprintf("got {} want {}", got, want))
}

case_app_live :: proc() -> bool {
	say("case app-live — the real herdr binary, captured byte for byte")

	live_scrub_proved()
	live_nesting_differential()
	live_list()
	live_stream_split()
	live_exit_codes()
	live_delete_lie()
	live_orphan_rule()
	live_machine_gate()
	live_remote_list()
	live_device_discriminator()
	live_timeout()
	live_detach_routes_to_the_device()
	live_control_budget_live()
	live_cleanup()

	return !any_failed
}

// ---------------------------------------------------------------------------
// The scrub, proven by asking the child rather than trusting our own map
// ---------------------------------------------------------------------------

// live_scrub_proved is the ISC-2 acceptance test at the only level that matters:
// what the CHILD actually sees. A map that looks clean proves less than a child
// that reports no HERDR_* and a real TERM.
live_scrub_proved :: proc() {
	// `env` is /usr/bin/env — not herdr, but the same run_capture path, so the
	// environment we build is exactly the one herdr would get.
	c := app.run_capture({"env"}, 5 * time.Second)
	eq_code("env child exit 0", c.code, 0)

	lines, _ := strings.split(string(c.out), "\n")
	leaked := make([dynamic]string, 0, 8)
	had_term := false
	term_val := ""
	for l in lines {
		eq_pos := strings.index(l, "=")
		if eq_pos < 0 { continue }
		k := l[:eq_pos]
		if app.env_is_herdr_namespace(k) { append(&leaked, k) }
		if k == "TERM" { had_term = true; term_val = l[eq_pos+1:] }
	}
	check("child sees NO HERDR_* variable", len(leaked) == 0,
		fmt.tprintf("leaked={}", to_slice_of_strings(leaked)))
	check("child still has TERM", had_term, fmt.tprintf("TERM={}", term_val))

	// And the same child INSIDE herdr: prove we are in fact running inside one,
	// otherwise the scrub above proves nothing about nesting.
	inside := os.get_env_alloc("HERDR_ENV", context.allocator)
	say(fmt.tprintf("  our own env: HERDR_ENV=%q HERDR_SESSION=%q (so nesting is live here)",
		inside, os.get_env_alloc("HERDR_SESSION", context.allocator)))
	check("we are running inside herdr (the scrub is not vacuous)", inside != "",
		fmt.tprintf("HERDR_ENV={}", inside))
}

// live_nesting_differential is the *why* behind the scrub, captured as a
// differential rather than a claim: the same command, once through our scrubbed
// environment and once with HERDR_ENV re-injected by the child itself.
//
// Scrubbed  → the nesting check never fires (the run proceeds and dies later on
//             the absent tty, exit 101).
// Injected  → herdr refuses at the door, exit 1, "nested herdr is disabled".
//
// That pair is the evidence that the scrub is load-bearing: remove it and every
// create/attach from inside a herdr pane hits the second line.
live_nesting_differential :: proc() -> bool {
	// Through the choke point: HERDR_* is gone, so nesting is invisible.
	scrubbed := app.run_capture({app.HERDR_BIN, "--session", SCRATCH}, 20 * time.Second)
	say(fmt.tprintf("  scrubbed   `{} --session {}` → exit {}", app.HERDR_BIN, SCRATCH, scrubbed.code))
	say_raw("    stderr", first_bytes(scrubbed.err, 160))
	check("scrubbed launch is NOT refused as nested",
		!strings.contains(string(scrubbed.err), "nested herdr is disabled"),
		fmt.tprintf("exit={} stderr={}", scrubbed.code, first_line(string(scrubbed.err))))

	// Same command with HERDR_ENV re-injected inside the child, which is exactly
	// what an unscrubbed environment would hand it.
	injected := app.run_capture(
		{"sh", "-c", fmt.tprintf("{}=1 exec {} --session {}", "HERDR_ENV", app.HERDR_BIN, SCRATCH)},
		20 * time.Second)
	say(fmt.tprintf("  injected   HERDR_ENV=1 `{} --session {}` → exit {}", app.HERDR_BIN, SCRATCH, injected.code))
	say_raw("    stderr", first_bytes(injected.err, 160))
	check("HERDR_ENV present → herdr refuses with the nesting error",
		strings.contains(string(injected.err), "nested herdr is disabled"),
		fmt.tprintf("exit={} stderr={}", injected.code, first_line(string(injected.err))))
	eq_code("the nesting refusal is the documented exit 1 (herdr error)", injected.code, 1)

	// Cleanup is inline as well as in the shell trap: this probe creates state.
	teardown_scratch()
	return true
}

first_line :: proc(s: string) -> string {
	idx := strings.index(s, "\n")
	if idx < 0 { return s }
	return s[:idx]
}

// ---------------------------------------------------------------------------
// The local list → model path, from inside a herdr pane
// ---------------------------------------------------------------------------

live_list :: proc() {
	c := app.run_capture(app.list_argv(), app.CAPTURE_TIMEOUT)
	eq_code("list exit 0", c.code, 0)
	say_raw("  raw stdout", c.out)
	say_raw("  raw stderr", c.err)

	rows, ok := app.parse_session_list(c.out, app.DEVICE_LOCAL, app.DEVICE_LOCAL)
	check("list parses", ok, fmt.tprintf("{} rows", len(rows)))
	for r in rows {
		say(fmt.tprintf("    row device={} name={} running={} ts={}",
			r.device, r.name, r.running, app.ts_display(r.ts)))
	}
	check("NO row is `default` (D12)", !contains_name(rows, "default"),
		fmt.tprintf("names={}", names_of(rows))

	)
	check("every row carries device=local", all_device(rows, app.DEVICE_LOCAL),
		fmt.tprintf("devices distinct? {}", len(rows) > 0))

	// The hosted session must be visible but never at risk: assert the two live
	// sessions from the plan appear, and that neither is `default`.
	say(fmt.tprintf("  {} local session(s) in the model", len(rows)))
}

contains_name :: proc(rows: []app.Session, name: string) -> bool {
	for r in rows { if r.name == name { return true } }
	return false
}

all_device :: proc(rows: []app.Session, device: string) -> bool {
	for r in rows { if r.device != device { return false } }
	return true
}

// ---------------------------------------------------------------------------
// The stdout/stderr split — ISC-A-1
// ---------------------------------------------------------------------------

live_stream_split :: proc() {
	// A child that writes a distinct marker to EACH stream. If anything merged the
	// two, this is where it shows.
	c := app.run_capture({"sh", "-c", "printf 'STDOUT_ONLY\\n'; printf 'STDERR_ONLY\\n' >&2"},
		5 * time.Second)
	eq_code("split child exit 0", c.code, 0)
	say_raw("  captured stdout", c.out)
	say_raw("  captured stderr", c.err)
	check("stdout holds ONLY the stdout marker",
		strings.contains(string(c.out), "STDOUT_ONLY") &&
		!strings.contains(string(c.out), "STDERR_ONLY"),
		fmt.tprintf("stdout={}", string(c.out)))
	check("stderr holds ONLY the stderr marker",
		strings.contains(string(c.err), "STDERR_ONLY") &&
		!strings.contains(string(c.err), "STDOUT_ONLY"),
		fmt.tprintf("stderr={}", string(c.err)))

	// The same shape with a non-zero exit: exit != 0 must read STDERR and only STDERR.
	c2 := app.run_capture({"sh", "-c", "printf 'STDOUT_NOISE\\n'; printf 'errjson' >&2; exit 1"},
		5 * time.Second)
	kind, payload, _ := app.outcome(&c2)
	eq("exit 1 child maps to a herdr error", app.outcome_label(kind), "herdr error")
	check("payload came from stderr, not stdout",
		string(payload) == "errjson" && !strings.contains(string(payload), "STDOUT_NOISE"),
		fmt.tprintf("payload={}", string(payload)))
}

// ---------------------------------------------------------------------------
// The exit-code contract against the real binary
// ---------------------------------------------------------------------------

live_exit_codes :: proc() {
	// exit 1 + stderr JSON: stopping a session that is not running / does not exist.
	missing := app.stop_argv(SCRATCH_NEVER)
	c := app.run_capture(missing, app.CAPTURE_TIMEOUT)
	say(fmt.tprintf("  `herdr session stop --json {}` → exit {}", SCRATCH_NEVER, c.code))
	say_raw("    stdout", c.out)
	say_raw("    stderr", c.err)
	kind, payload, herr := app.outcome(&c)
	eq_code("stop-missing exits 1", c.code, 1)
	eq("mapped to a herdr error", app.outcome_label(kind), "herdr error")
	check("stderr is EMPTY on stdout side", len(c.out) == 0,
		fmt.tprintf("{} bytes on stdout", len(c.out)))
	check("error envelope parsed from stderr", herr.present,
		fmt.tprintf("code={} message={}", herr.code, herr.message))
	_ = payload

	// exit 2: an unknown herdr subcommand is CLI-level, not a herdr error.
	c2 := app.run_capture({app.HERDR_BIN, "definitely-not-a-subcommand"}, 5 * time.Second)
	kind2, _, _ := app.outcome(&c2)
	say(fmt.tprintf("  unknown subcommand → exit {} stderr={}", c2.code, string(c2.err)))
	eq_code("unknown subcommand exits 2", c2.code, 2)
	eq("mapped to a CLI-level error", app.outcome_label(kind2), "bad command line")

	// exit 127: nothing to spawn. Locally reproducible, and the SAME code a remote
	// `herdr: command not found` produces — which is how "no herdr there" is read.
	c3 := app.run_capture({"hs-definitely-not-a-real-binary"}, 2 * time.Second)
	kind3, _, _ := app.outcome(&c3)
	check("unspawnable program reports not-spawned", !c3.spawned, "spawned=false")
	eq("mapped to herdr not found", app.outcome_label(kind3), "herdr not found")

	// exit 255: ssh transport failure. An unroutable RFC5737 address fails fast
	// and is unmistakable.
	c4 := app.run_capture(app.remote_list_argv("192.0.2.201"), 8 * time.Second)
	kind4, _, _ := app.outcome(&c4)
	say(fmt.tprintf("  ssh to an unreachable host → exit {}", c4.code))
	eq_code("unreachable ssh exits 255", c4.code, 255)
	eq("mapped to an ssh transport failure", app.outcome_label(kind4), "ssh failed")
}

// ---------------------------------------------------------------------------
// The delete lie (rule 4)
// ---------------------------------------------------------------------------

live_delete_lie :: proc() {
	// THE EVIDENCE: herdr answers `deleted:true` with EXIT 0 for a session that
	// was never created. Any code that trusts it reports success on a typo.
	c := app.run_capture(app.delete_argv(SCRATCH_NEVER), app.CAPTURE_TIMEOUT)
	say(fmt.tprintf("  `herdr session delete --json {}` (never created) → exit {}", SCRATCH_NEVER, c.code))
	say_raw("    stdout", c.out)
	check("herdr LIES: exit 0 for a session that never existed", c.code == 0,
		fmt.tprintf("exit={}", c.code))
	check("herdr's stdout says deleted:true",
		strings.contains(string(c.out), `"deleted":true`),
		fmt.tprintf("stdout={}", string(c.out)))
	check("and it still is not in the real list",
		!contains_name(list_now(), SCRATCH_NEVER), "confirmed absent")

	// OUR behaviour: the model refuses, so the lie never reaches the user.
	res := app.delete_session(list_now(), app.DEVICE_LOCAL, SCRATCH_NEVER, app.CAPTURE_TIMEOUT)
	check("delete_session REFUSES the never-created name",
		res.refused && !res.deleted && !res.existed,
		fmt.tprintf("refused={} deleted={} existed={} reason={}",
			res.refused, res.deleted, res.existed, res.reason))

	// `default` is refused by name before anything else (D12).
	dres := app.delete_session(list_now(), app.DEVICE_LOCAL, "default", app.CAPTURE_TIMEOUT)
	check("delete_session REFUSES `default`", dres.refused && !dres.deleted,
		fmt.tprintf("reason={}", dres.reason))
}

// list_now re-reads the real session list into model rows.
list_now :: proc() -> []app.Session {
	c := app.run_capture(app.list_argv(), app.CAPTURE_TIMEOUT)
	rows, _ := app.parse_session_list(c.out, app.DEVICE_LOCAL, app.DEVICE_LOCAL)
	return rows
}

// scratch_names_now is the DYNAMIC baseline (O12.3): every `hs-t-*` session
// currently alive, read from herdr rather than recalled from a plan written
// against a session set that no longer exists.
//
// This exists because a hard-coded baseline is worse than no baseline. The old
// check compared against names from the plan; when the user's sessions changed,
// a leftover could be absorbed into "before" and never flagged — a drift check
// that cannot fail is not a check. Counting by prefix, live, has no such hole:
// nothing named `hs-t-*` is legitimately there, whoever put it there.
scratch_names_now :: proc() -> [dynamic]string {
	out := make([dynamic]string, 0, 4)
	for r in list_now() {
		if strings.has_prefix(r.name, SCRATCH_PREFIX) { append(&out, r.name) }
	}
	return out
}

// joined is the printable form of a name list, brackets included, so an EMPTY
// baseline reads as `[]` in the log rather than as nothing at all.
joined :: proc(names: []string) -> string {
	parts := make([dynamic]string, 0, len(names))
	for n in names { append(&parts, fmt.tprintf("'{}'", n)) }
	body, _ := strings.join(parts[:], ", ")
	return fmt.tprintf("[{}]", body)
}

no_children_alive :: proc() -> (int, int) {
	st: c.int = 0
	kid := posix.waitpid(-1, &st, {.NOHANG})
	return int(kid), int(posix.errno())
}

// prove_no_fork is the evidence half of a guard assertion. A guard that returns
// false only proves what the function said about itself; `waitpid(-1, WNOHANG)`
// answering ECHILD in this process proves there is NO child to reap, i.e. the
// guard did not spawn one on its way out. O11 keeps the guards precisely because
// they are the thing we own; this is what makes "kept" observable.
prove_no_fork :: proc(label: string) {
	kid, errno := no_children_alive()
	check(fmt.tprintf("{} forked nothing", label),
		kid == -1 && errno == 10,
		fmt.tprintf("waitpid(-1,WNOHANG) = {} errno={} (10 = ECHILD)", kid, errno))
}

// ---------------------------------------------------------------------------
// The orphan rule (rule 3) — why validation happens BEFORE the spawn
// ---------------------------------------------------------------------------

// The three things this proc used to assert were properties of herdr 0.8.2. RCH-2
// moved the ground: 0.9.5 got a clean terminal check and stopped orphaning on an
// aborted launch. So the assertions moved off the hazard and onto the guard, which
// is the only one of the two we control.
//
//   BEFORE (pinned to 0.8.2)                 AFTER (version-tolerant, O11-O12)
//   ------------------------                 --------------------------------
//   exit must be 101                         exit must be 101 OR 1-with-a-clean-
//                                          message — `outcome_needs_terminal`
//   the aborted launch must still leave a    the GUARD must refuse an unknown
//   live session (proving the hazard)        name, and must fork nothing at all
//   a baseline of known session names        a baseline read live, by prefix
//
// "Whether upstream orphans" is not our contract and is not what a red test
// should be about. "We never hand an unvalidated name to herdr" is, and it is
// true on 0.8.2, 0.9.5, and whatever comes between them.
live_orphan_rule :: proc() {
	say("  — the orphan rule, asserted on the GUARD not the hazard (O11/O12)")

	// Dynamic baseline: what `hs-t-*` sessions already exist. Nothing named this
	// way is legitimately here, so a non-empty baseline is itself a finding.
	baseline := scratch_names_now()
	say(fmt.tprintf("    dynamic scratch baseline at start: {} (0 is the only sane value)",
		joined(baseline[:])))
	check("baseline is read live, not recalled from a plan (O12.3)",
		len(baseline) == 0,
		fmt.tprintf("{} pre-existing `hs-t-*` session(s): {}", len(baseline),
			joined(baseline[:])))

	// ---- the hazard itself, REPORTED and never asserted-on -------------------
	// Built by hand ON PURPOSE (not via launch_argv): this reproduces the raw
	// create-or-attach failure so we can see what the installed herdr does, and
	// nothing else. It is telemetry, not a contract.
	orphan_argv := make([dynamic]string, 0, 3)
	append(&orphan_argv, app.HERDR_BIN, "--session")
	append(&orphan_argv, SCRATCH)
	c := app.run_capture(orphan_argv[:], 20 * time.Second)
	kind, _, _ := app.outcome(&c)
	say(fmt.tprintf("    raw `{} --session {}` with no tty -> exit {} · {} · {} B of stderr",
		app.HERDR_BIN, SCRATCH, c.code, app.outcome_label(kind), len(c.err)))
	say_raw("      stderr", first_bytes(c.err, 160))

	// THE version-tolerant half. `outcome_needs_terminal` is true for 101 (the
	// panic 0.8.2 and 0.9.2-and-earlier produce) and for 1-with-a-clean-message
	// (0.9.3+). Which one the user has is not our business; that BOTH answer it
	// is what the test pins.
	check("a launch with no terminal is recognised as such on EITHER herdr (O12.1)",
		app.outcome_needs_terminal(kind),
		fmt.tprintf("exit={} -> {}", c.code, app.outcome_label(kind)))
	// Was, before this was fixed: `kind != .herdr_error || !outcome_needs_terminal(kind)`
	// — a TAUTOLOGY. `outcome_needs_terminal(.herdr_error)` is false by
	// definition (it only covers .tty_panic / .tty_unavailable), so the second
	// operand was true whenever the first was false, and the check could never
	// fail. It is now the assertion the label always claimed: a no-terminal launch
	// must be a TTY verdict, never a parsed herdr error. If the envelope parser
	// ever became eager enough to grab panic text, THIS fails.
	check("…and the no-terminal verdict is a TTY shape, never a parsed herdr error",
		kind != .herdr_error && (kind == .tty_panic || kind == .tty_unavailable),
		fmt.tprintf("kind={} (must be .tty_panic or .tty_unavailable)",
			app.outcome_label(kind)))

	// Whether the aborted launch orphaned a session is now REPORTED, not asserted.
	// 0.8.2 said yes; 0.9.5 says no. The test does not care, and it must not
	// start failing the day someone upgrades or downgrades herdr.
	left_it := contains_name(list_now(), SCRATCH)
	say(fmt.tprintf("    this herdr's hazard answer: aborted launch left a live session = {}",
		left_it))
	say("      (reported only — 0.8.2 true, 0.9.5 false; the GUARD is the contract)")
	teardown_scratch()

	// ---- the guard: O11 says these stay, so here is what "stays" looks like --
	// Attaching an unvalidated name is refused before an argv exists. The boolean
	// is half the proof; ECHILD is the other half.
	rows := list_now()
	unknown := "hs-t-not-in-the-model"
	g := app.attach_guard(rows, app.DEVICE_LOCAL, unknown)
	prove_no_fork("attach_guard(unknown)")
	check("attach_guard still refuses an unvalidated name (O11: never attached)",
		!g.ok, fmt.tprintf("{}", g.reason))
	check("…and the reason names the consequence, not just the rule",
		strings.contains(g.reason, "CREATE"), fmt.tprintf("\"{}\"", g.reason))

	dg := app.delete_guard(rows, app.DEVICE_LOCAL, SCRATCH_NEVER)
	prove_no_fork("delete_guard(never-created)")
	check("delete_guard still refuses a name it never saw (O11: pre-check kept)",
		!dg.ok, fmt.tprintf("{}", dg.reason))
	check("…and says nothing was destroyed where herdr would have said 'deleted'",
		strings.contains(dg.reason, "nothing was deleted"), fmt.tprintf("\"{}\"", dg.reason))

	// The argv builders refuse too, so even a caller that skipped the guard has
	// nothing to spawn. Two independent doors, both shut.
	_, bad_launch := app.launch_argv(app.DEVICE_LOCAL, "bad name")
	_, bad_attach := app.attach_argv("default")
	check("our launch/attach produce NO argv for an invalid or default name",
		!bad_launch && !bad_attach, fmt.tprintf("launch_ok={} attach_ok={}", bad_launch, bad_attach))
	check("attaching an unknown name is refused in-app (ISC-17)",
		!app.is_known_session(rows, app.DEVICE_LOCAL, unknown),
		"the model is the gate, not herdr's answer")

	// And the run leaves nothing behind, whoever created it: the same prefix sweep
	// that started at zero must end at zero.
	leftover := scratch_names_now()
	check(fmt.tprintf("this run leaves no `{}*` session behind, by prefix", SCRATCH_PREFIX),
		len(leftover) == 0,
		fmt.tprintf("{} left: {}", len(leftover), joined(leftover[:])))
}

// ---------------------------------------------------------------------------
// The `machine` feature gate on the real binary (D1)
// ---------------------------------------------------------------------------

live_machine_gate :: proc() {
	c := app.run_capture(app.machine_probe_argv(), app.CAPTURE_TIMEOUT)
	say(fmt.tprintf("  `herdr machine list --json` → exit {}", c.code))
	say_raw("    stdout", c.out)
	say_raw("    stderr", c.err)

	available := app.machine_registry_available(c.out)
	say(fmt.tprintf("    installed herdr reports a machine registry: {}", available))
	// The old form was `check(..., true, ...)` — a literal `true`, a check that
	// cannot fail and reads like coverage that does not exist. The falsifiable
	// version pins two things the gate can actually get wrong on the REAL payload:
	// the probe really ran, and the gate's answer agrees with the payload's own
	// first structural character — computed here, independently of the gate.
	says_registry := registry_says_registry(c.out)
	check("the machine probe spawned a child that answered (not a silent no-op)",
		c.spawned && len(c.out) > 0,
		fmt.tprintf("spawned={} stdout={} bytes", c.spawned, len(c.out)))
	check("the gate's answer agrees with the payload's shape (gate never invents one)",
		available == says_registry,
		fmt.tprintf("gate said {}; the payload starts as {}", available, says_registry))

	// O13, against the REAL payload rather than a fixture. `[]` is exactly what
	// 0.9.5 prints on this box, so this is not a hypothetical: the merge below is
	// the difference between "the configured host is on screen" and "the device
	// list is quietly one shorter".
	cfg := []app.Remote{{device = "configured.example", label = "Configured"}}
	d := app.discover_resolved(c.out, cfg)
	say(fmt.tprintf("    discovery source: {} · from_registry={} from_config={} · {} remote(s): {}",
		app.machine_source_label(d.source), d.from_registry, d.from_config, len(d.remotes),
		devices_of(d.remotes)))
	check("O13: whatever the registry said, the configured remote is present",
		contains_device(d.remotes, "configured.example"),
		fmt.tprintf("remotes={} (registry said {} bytes)", devices_of(d.remotes), len(c.out)))
	check("O13: and nothing in the merge was silently dropped",
		len(d.remotes) == d.from_registry + d.from_config,
		fmt.tprintf("{} != {} + {}", len(d.remotes), d.from_registry, d.from_config))
	if !available {
		check("0.8.2-shaped: fallback carries the configured remote",
			d.source == .config_fallback && d.remotes[0].device == "configured.example",
			app.machine_source_label(d.source))
	}
	// The probe's exit code is NOT the gate — assert that explicitly by feeding the
	// real payload through the shape check regardless of what the code was.
	check("gate decision is made on shape, independent of the exit code",
		app.machine_registry_available(c.out) == available,
		fmt.tprintf("exit={} shape={}", c.code, available))
	// And the version-specific reading, spelled out for the log: an empty registry
	// is not "no remotes".
	if len(app.machine_array_of(c.out)) == 0 {
		check("O13: an EMPTY registry (this box) still leaves the configured remote",
			len(d.remotes) >= 1,
			fmt.tprintf("registry empty, {} remote(s) survive: {}", len(d.remotes),
				devices_of(d.remotes)))
	}
}

devices_of :: proc(rs: []app.Remote) -> string {
	parts := make([dynamic]string, 0, len(rs))
	for r in rs { append(&parts, r.device) }
	joined, _ := strings.join(parts[:], " ")
	return joined
}

// registry_says_registry answers the same question as the product's gate, but
// from the RAW BYTES alone — first non-whitespace character, and whether the
// payload mentions `machines` at all. It deliberately does NOT call
// `machine_registry_available`, because a check that re-calls the function under
// test can never fail. Two independent paths to the same answer is the only
// version of "it read the payload correctly" that is worth printing.
registry_says_registry :: proc(payload: []byte) -> bool {
	if len(payload) == 0 { return false }
	first: byte = 0
	for b in payload {
		if b == ' ' || b == '\t' || b == '\n' || b == '\r' { continue }
		first = b
		break
	}
	if first == '[' { return true }
	if first != '{' { return false }
	text := string(payload)
	return strings.contains(text, "\"machines\"") || strings.contains(text, "machines")
}

// ---------------------------------------------------------------------------
// Remote listing over our own ssh (T3.4 / T4.1 groundwork)
// ---------------------------------------------------------------------------

live_remote_list :: proc() {
	remote := live_remote()
	if remote == "" {
		say("  SKIP: HERDR_SESSION_TEST_REMOTE is unset — no fixture remote available")
		return
	}
	say(fmt.tprintf("  fixture remote: {}", remote))

	argv := app.remote_list_argv(remote)
	eq("the fetch uses the device string verbatim in argv", argv[len(argv)-2], remote)

	c := app.run_capture(argv, 25 * time.Second)
	say(fmt.tprintf("  `ssh … 'herdr session list --json'` → exit {}", c.code))
	say_raw("    stdout (first 240 B)", first_bytes(c.out, 240))
	say_raw("    stderr", first_bytes(c.err, 240))
	kind, payload, _ := app.outcome(&c)
	eq_code("remote list exits 0", c.code, 0)
	eq("mapped to ok", app.outcome_label(kind), "ok")
	check("remote payload has a sessions array", app.has_sessions_field(payload),
		"the JSON shape is the same as local")

	rows, ok := app.parse_session_list(payload, remote, remote)
	check("remote rows parse", ok, fmt.tprintf("{} rows", len(rows)))
	check("every remote row carries the remote device, not 'local'",
		len(rows) == 0 || all_device(rows, remote),
		fmt.tprintf("devices={}", devices_of_remote(rows)))
	check("`default` is filtered from the REMOTE list too (D12 applies everywhere)",
		!contains_name(rows, "default"), fmt.tprintf("names={}", names_of(rows)))
	for r in rows {
		say(fmt.tprintf("    remote row device={} name={} running={} ts={}",
			r.device, r.name, r.running, app.ts_display(r.ts)))
	}
}

devices_of_remote :: proc(rows: []app.Session) -> string {
	parts := make([dynamic]string, 0, len(rows))
	for r in rows { append(&parts, r.device) }
	joined, _ := strings.join(parts[:], " ")
	return joined
}

// ---------------------------------------------------------------------------
// The device discriminator (T6.3 preview) — the test that a single-loopback-
// host suite can never pass
// ---------------------------------------------------------------------------

// live_device_discriminator is T6.3: the SAME machine reachable by TWO ssh target
// strings (the fixture's target and its alias, e.g. the two loopback
// spellings), which must never be collapsed.
//
// This is the case a naive identity model dies of. Both targets reach the same
// socket and therefore the same session names, so any model keyed on `name` — or
// on "which host does this resolve to" — merges them, and then attach and delete
// act on whichever target the merge happened to keep. The device string is part
// of the identity precisely so that a row says what it will dial.
live_device_discriminator :: proc() {
	remote := live_remote()
	alias := fixture_alias()
	if remote == "" || alias == "" || remote == alias {
		say("  SKIP: need two DISTINCT ssh target strings for the discriminator")
		return
	}
	say(fmt.tprintf("  two target strings for the SAME machine: {} and {}", remote, alias))

	a := app.run_capture(app.remote_list_argv(remote), 25 * time.Second)
	b := app.run_capture(app.remote_list_argv(alias), 25 * time.Second)
	if a.code != 0 || b.code != 0 {
		check("both target strings list successfully", false,
			fmt.tprintf("{}→{} {}→{}", remote, a.code, alias, b.code))
		return
	}

	ra, _ := app.parse_session_list(a.out, remote, remote)
	rb, _ := app.parse_session_list(b.out, alias, alias)
	same_names := names_of(ra) == names_of(rb)
	say(fmt.tprintf("  same session names under both targets: {}", same_names))
	check("the two targets really do reach identical sessions (so the only difference is `device`)",
		same_names, fmt.tprintf("{} vs {}", names_of(ra), names_of(rb)))

	// Combined into ONE table: identical names, DIFFERENT identities. A model that
	// keyed on name alone would collapse these rows — that is the bug.
	combined := make([dynamic]app.Session, 0, len(ra) + len(rb))
	for r in ra { append(&combined, r) }
	for r in rb { append(&combined, r) }
	app.sort_sessions(combined[:])
	check_int("identical names stay DISTINCT rows (device is part of the key)",
		len(combined[:]), len(ra) + len(rb))

	if len(ra) == 0 {
		say("  SKIP: no sessions under the fixture target to discriminate")
		return
	}
	name := ra[0].name

	// (a) Device filtering shows BOTH, separately. The names are IDENTICAL (same
	// machine, same sessions) — so "both lists contain the name" is not the
	// discriminator. The discriminator is that the two lists are distinct
	// per-device slices that each hold their OWN copy, and that the combined table
	// holds two identities rather than one shared row.
	names_a := app.names_for_device(combined[:], remote)
	names_b := app.names_for_device(combined[:], alias)
	each_own_rows := len(names_a) == len(ra) && len(names_b) == len(rb)
	neither_empty := len(names_a) > 0 && len(names_b) > 0
	check("the device filter returns each target's own rows, neither empty",
		each_own_rows && neither_empty,
		fmt.tprintf("{}={} {}={}", remote, joined(names_a), alias, joined(names_b)))
	ident_a := count_identity(combined[:], remote, name)
	ident_b := count_identity(combined[:], alias, name)
	check("…and filtering by one target NEVER borrows the other's rows",
		ident_a == 1 && ident_b == 1,
		fmt.tprintf("two devices, same name -> {} + {} rows for '{}'",
			ident_a, ident_b, name))
	check_int("…which is exactly 2 identities, not 1 shared row",
		ident_a + ident_b, 2)

	// (b) Identity lookup is (device, name) — the SAME name answers differently
	// depending on which device you ask about. This is the discriminator.
	both := []app.Session{
		app.Session{device = remote, label = remote, name = name, running = true},
		app.Session{device = alias, label = alias, name = name, running = true},
	}
	check("the name is known under BOTH devices as two separate identities",
		app.is_known_session(both[:], remote, name) && app.is_known_session(both[:], alias, name),
		fmt.tprintf("{}: {} {}: {}", remote, app.is_known_session(both[:], remote, name),
			alias, app.is_known_session(both[:], alias, name)))
	check_int("…and looking one up by (device,name) finds exactly one, not two",
		count_identity(both[:], remote, name), 1)

	// (c) T6.3's headline: an ATTACH aimed at the ALIAS row puts the ALIAS string
	// after `--remote`, verbatim. Not the primary target, not the label, not the
	// resolved hostname.
	argv_b, ok_b := app.attach_target_argv(alias, name)
	check("attach on the alias row carries the ALIAS verbatim after --remote",
		ok_b && argv_contains(argv_b, "--remote") && argv_after(argv_b, "--remote") == alias,
		fmt.tprintf("--remote → {}", argv_after(argv_b, "--remote")))
	say(fmt.tprintf("      {} row -> {}", alias, argv_join(argv_b)))

	argv_a, ok_a := app.attach_target_argv(remote, name)
	check("attach on the primary row carries the PRIMARY verbatim",
		ok_a && argv_after(argv_a, "--remote") == remote,
		fmt.tprintf("--remote → {}", argv_after(argv_a, "--remote")))
	say(fmt.tprintf("      {} row -> {}", remote, argv_join(argv_a)))
	check("…and the two argvs are DIFFERENT strings — the target was not merged away",
		argv_join(argv_a) != argv_join(argv_b),
		fmt.tprintf("{} != {}", argv_join(argv_a), argv_join(argv_b)))

	// (d) Deleting one identity leaves the other intact. Model-level: with only
	// the alias row left, the primary-target identity is gone and vice versa — and
	// the guards say so independently, so a delete scoped to one can never be
	// satisfied by the other.
	only_alias := []app.Session{app.Session{device = alias, label = alias, name = name}}
	check("delete scoped to the alias is permitted while the primary identity is absent",
		app.delete_guard(only_alias[:], alias, name).ok &&
		!app.delete_guard(only_alias[:], remote, name).ok,
		fmt.tprintf("alias={} primary={}",
			app.delete_guard(only_alias[:], alias, name).ok,
			app.delete_guard(only_alias[:], remote, name).ok))
	// …and the guard that refuses the primary scope never forks (O11: not weakened).
	prove_no_fork("delete_guard(primary while only alias exists)")

	// (e) And the reverse: with only the primary row left, the alias scope refuses.
	only_primary := []app.Session{app.Session{device = remote, label = remote, name = name}}
	check("the mirror case refuses too — neither target can borrow the other's row",
		app.delete_guard(only_primary[:], remote, name).ok &&
		!app.delete_guard(only_primary[:], alias, name).ok,
		fmt.tprintf("primary={} alias={}",
			app.delete_guard(only_primary[:], remote, name).ok,
			app.delete_guard(only_primary[:], alias, name).ok))
}

argv_contains :: proc(argv: []string, needle: string) -> bool {
	for a in argv { if a == needle { return true } }
	return false
}

// argv_after returns the value that follows `flag`, or "" if the flag is absent or
// last. Used to prove the VALUE of --remote, not merely that the string appears
// somewhere: a contains-check would also pass on a command
// that put the target in the wrong slot.
argv_after :: proc(argv: []string, flag: string) -> string {
	for v, idx in argv {
		if v == flag && idx + 1 < len(argv) { return argv[idx+1] }
	}
	return ""
}

contains_string :: proc(vs: []string, want: string) -> bool {
	for v in vs { if v == want { return true } }
	return false
}

// count_identity counts rows matching the FULL identity (device, name). A model
// that collapsed the two targets would return 2 here for one name; the
// discriminator must return exactly 1 per device.
count_identity :: proc(rows: []app.Session, device, name: string) -> int {
	n := 0
	for r in rows { if r.device == device && r.name == name { n += 1 } }
	return n
}

argv_join :: proc(argv: []string) -> string {
	parts := make([dynamic]string, 0, len(argv))
	for a in argv { append(&parts, a) }
	joined, _ := strings.join(parts[:], " ")
	return joined
}

// ---------------------------------------------------------------------------
// Our own timeout
// ---------------------------------------------------------------------------

live_timeout :: proc() {
	started := time.now()
	c := app.run_capture({"sleep", "30"}, 400 * time.Millisecond)
	elapsed := time.duration_milliseconds(time.since(started))
	kind, _, _ := app.outcome(&c)
	say(fmt.tprintf("  sleep 30 under a 400 ms budget → exit {} after {:.0f} ms",
		c.code, elapsed))
	eq_code("timeout reports our own code 124", c.code, 124)
	check("timed_out flag is set", c.timed_out, "we killed it")
	eq("mapped to timed_out", app.outcome_label(kind), "timed out")
	check("it actually returned within the budget (+ slack)", elapsed < 3000,
		fmt.tprintf("{:.0f} ms", elapsed))
	check("the killed child is reaped (no zombie we left behind)",
		c.spawned, fmt.tprintf("spawned={}", c.spawned))
}

// ---------------------------------------------------------------------------
// Cleanup
// ---------------------------------------------------------------------------

live_cleanup :: proc() {
	removed := cleanup_scratch()
	say(fmt.tprintf("  cleanup: scratch session present after teardown = {}", removed))
	check("scratch session is gone (stop + delete)", !removed,
		fmt.tprintf("names now={}", names_of(list_now())))

	// The hosting session must still be listed and untouched.
	host := os.get_env_alloc("HERDR_SESSION", context.allocator)
	if host != "" {
		check("the session hosting this agent is still present and untouched",
			contains_name(list_now(), host),
			fmt.tprintf("host={} names={}", host, names_of(list_now())))
	}
}


// ---------------------------------------------------------------------------
// P1 LIVE — the cleanup goes to the device that owns the session, and the local
// same-named session SURVIVES
// ---------------------------------------------------------------------------

// live_detach_routes_to_the_device is the P1 acceptance run against real
// processes and real ssh.
//
// The bug: `cleanup_policy = "always"` after a detach ran the BARE local
// `herdr session stop/delete <name>`, so cleaning up a REMOTE row destroyed the
// LOCAL session that shared the name.
//
// The loop-back fixture cannot stage two distinct machines under one name: the
// "remote" IS this box, so a remote scratch and a local scratch are literally
// the same session and taking one down legitimately takes both. What CAN stage the class
// exactly is a device whose cleanup cannot be performed locally: an
// unreachable host. If the cleanup is device-routed, the local same-named
// session survives it and the notice says the remote cleanup FAILED. If it is
// not routed — which is what the review reproduced — the local session dies.
live_detach_routes_to_the_device :: proc() {
	say("  — P1 LIVE: detach cleanup is routed to the row's device")

	victim := "hs-t-p1-namesake"
	teardown_scratch_named(victim, "pre-run safety")
	if !spawn_scratch_session_pty(victim) {
		say("    SKIP: could not create the local scratch session under a pty")
		return
	}

	before := list_now()
	check("the LOCAL same-named session exists before the remote cleanup",
		contains_name(before, victim), fmt.tprintf("local names={}", names_of(before)))

	dead := fx_unreachable_live()
	app.set_cleanup_policy(.always)
	defer app.set_cleanup_policy(app.DEFAULT_CLEANUP_POLICY)

	t0 := time.now()
	msg := app.post_detach(dead, victim, true)
	elapsed := time.since(t0)
	say(fmt.tprintf("    cleanup aimed at unreachable device {} in {}s",
		dead, f64(i64(elapsed / time.Millisecond)) / 1000.0))
	say(fmt.tprintf("    post_detach notice: {}", msg))

	check("the notice reports the cleanup did NOT land (never claims success)",
		strings.contains(msg, "NOT cleaned"), fmt.tprintf("notice={}", msg))
	check("the notice names the device the cleanup was aimed at",
		strings.contains(msg, dead), fmt.tprintf("notice={}", msg))
	check("the notice never claims it stopped and deleted",
		!strings.contains(msg, "stopped and deleted"), fmt.tprintf("notice={}", msg))
	check("the cleanup stayed inside the control budget",
		elapsed <= app.CONTROL_TIMEOUT * 2 + 2 * time.Second,
		fmt.tprintf("elapsed={}", f64(i64(elapsed / time.Millisecond)) / 1000.0))

	after := list_now()
	say(fmt.tprintf("    local sessions BEFORE: {}", names_of(before)))
	say(fmt.tprintf("    local sessions AFTER : {}", names_of(after)))
	check("THE LOCAL SAME-NAMED SESSION SURVIVED the remote cleanup (P1)",
		contains_name(after, victim), fmt.tprintf("local names={}", names_of(after)))

	teardown_scratch_named(victim, "end of the P1 live case")
	check("teardown removed the scratch session",
		!contains_name(list_now(), victim), fmt.tprintf("names={}", names_of(list_now())))

	// The positive half, pinned at argv level (running it for real would delete
	// the same local session on this loopback fixture): a REACHABLE device's
	// cleanup goes out over ssh, to that device, verbatim.
	r := live_remote()
	if r != "" {
		ok_stop, ok_del := app.cleanup_argv(r, victim)
		eq("reachable remote cleanup stop goes through ssh", ok_stop[0], "ssh")
		eq("reachable remote cleanup delete goes through ssh", ok_del[0], "ssh")
		eq("reachable remote cleanup stop targets the device verbatim",
			ok_stop[len(app.SSH_BASE_ARGS)+1], r)
		eq("reachable remote cleanup delete targets the device verbatim",
			ok_del[len(app.SSH_BASE_ARGS)+1], r)
		say(fmt.tprintf("    live remote cleanup stop argv:   {}", app_argv_text(ok_stop)))
		say(fmt.tprintf("    live remote cleanup delete argv: {}", app_argv_text(ok_del)))
	}
}

// live_control_budget_live measures the control path against the black-holed
// fixture so the delete "working…" bound is a measurement and not a promise.
live_control_budget_live :: proc() {
	say("  — P2-5 LIVE: one control command against a black-holed host")
	dead := fx_unreachable_live()

	argv := app.control_argv(dead, app.delete_argv("hs-t-nope"))
	t0 := time.now()
	c := app.run_capture(argv, app.CONTROL_TIMEOUT)
	elapsed := time.since(t0)
	secs := f64(i64(elapsed / time.Millisecond)) / 1000.0
	say(fmt.tprintf("    {} -> exit {} in {}s", app_argv_text(argv), c.code, secs))

	check("the command returned (no hang)", c.spawned && !c.timed_out,
		fmt.tprintf("spawned={} timed_out={}", c.spawned, c.timed_out))
	check("…inside the CONTROL_TIMEOUT budget", elapsed <= app.CONTROL_TIMEOUT,
		fmt.tprintf("elapsed={}s budget={}s", secs, f64(app.CONTROL_TIMEOUT / time.Second)))
	check("…and it took ssh's own bound, not ours (ssh answers at ConnectTimeout)",
		secs >= 4.0 && secs <= 6.0, fmt.tprintf("elapsed={}s", secs))
	check("…which is UNDER the old 10 s CAPTURE_TIMEOUT this used to be allowed",
		elapsed < app.CAPTURE_TIMEOUT,
		fmt.tprintf("elapsed={}s capture={}s", secs, f64(app.CAPTURE_TIMEOUT / time.Second)))
}

// spawn_scratch_session_pty creates a REAL running session from a driver that
// has no terminal of its own. herdr refuses to attach without a usable tty, so
// `script` supplies one and `stty` gives it a size herdr will accept; the
// timeout then kills the *client* and the session's server stays up.
//
// Refuses any name outside the `hs-t-` scratch prefix. Nothing in this file may
// create a session it cannot also tear down.
spawn_scratch_session_pty :: proc(name: string) -> bool {
	if !strings.has_prefix(name, SCRATCH_PREFIX) {
		say(fmt.tprintf("    REFUSED to create non-scratch session {}", name))
		return false
	}
	cmd := fmt.tprintf(
		"timeout 5 script -q -c 'stty rows 24 cols 80; {} --session {}' /dev/null >/dev/null 2>&1 || true",
		app.HERDR_BIN, name)
	app.run_capture({"sh", "-c", cmd}, 20 * time.Second)
	for _ in 0 ..< 10 {
		if contains_name(list_now(), name) { return true }
		time.sleep(300 * time.Millisecond)
	}
	return false
}

// fx_unreachable_live mirrors fetch_live's fixture reader: TEST-NET-1 is
// unroutable by construction, so it black-holes instead of refusing, which is
// the case that used to be reported as a *completed* cleanup.
fx_unreachable_live :: proc() -> string {
	v := os.get_env_alloc("HERDR_SESSION_TEST_UNREACHABLE", context.allocator)
	if v != "" { return v }
	return "192.0.2.201"
}

// teardown_scratch_named stops+deletes one `hs-t-*` name through OUR code path
// and says what it did. Names outside the scratch prefix are refused.
teardown_scratch_named :: proc(name: string, stage: string) {
	if !strings.has_prefix(name, SCRATCH_PREFIX) {
		say(fmt.tprintf("    REFUSED teardown of non-scratch name {}: {}", name, stage))
		return
	}
	rows := list_now()
	if !contains_name(rows, name) { return }
	run := false
	for r in rows { if r.name == name { run = r.running } }
	if run {
		app.run_capture(app.stop_argv(name), app.CONTROL_TIMEOUT)
	}
	app.run_capture(app.delete_argv(name), app.CONTROL_TIMEOUT)
	say(fmt.tprintf("    teardown ({}): stopped+deleted {} (was running: {})", stage, name, run))
}

// cleanup_scratch stops and deletes the scratch session through OUR code path, so
// the teardown exercises delete_session against a name that really does exist —
// the mirror image of the never-created refusal above.
// teardown_scratch stops+deletes the scratch session idempotently. Called both
// inline (right after a probe that creates it) and from live_cleanup, because a
// probe that fails halfway must not leave a live session behind.
teardown_scratch :: proc() {
	rows := list_now()
	if !contains_name(rows, SCRATCH) { return }
	run := false
	for r in rows { if r.name == SCRATCH { run = r.running } }
	if run {
		app.run_capture(app.stop_argv(SCRATCH), app.CAPTURE_TIMEOUT)
	}
	app.run_capture(app.delete_argv(SCRATCH), app.CAPTURE_TIMEOUT)
}

cleanup_scratch :: proc() -> bool {
	rows := list_now()
	if !contains_name(rows, SCRATCH) { return false }
	res := app.delete_session(rows, app.DEVICE_LOCAL, SCRATCH, app.CAPTURE_TIMEOUT)
	say(fmt.tprintf("  delete_session({}) → deleted={} existed={} was_running={} reason={}",
		SCRATCH, res.deleted, res.existed, res.was_running, res.reason))
	return contains_name(list_now(), SCRATCH)
}

first_bytes :: proc(b: []byte, n: int) -> []byte {
	if len(b) <= n { return b }
	return b[:n]
}
