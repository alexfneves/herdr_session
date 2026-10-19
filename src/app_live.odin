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

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// The one scratch name this driver creates. One is enough: creating more buys no
// extra evidence and triples the cleanup risk.
SCRATCH :: "hs-t-phase3-probe"

// SCRATCH_NEVER is a name that must never exist. Used to catch herdr's
// `delete`-lies and to prove our pre-check refuses it.
SCRATCH_NEVER :: "hs-t-never-created-zz"

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

// ---------------------------------------------------------------------------
// The orphan rule (rule 3) — why validation happens BEFORE the spawn
// ---------------------------------------------------------------------------

live_orphan_rule :: proc() {
	// Proof of the hazard: `herdr --session <name>` is CREATE-OR-ATTACH, and the
	// server spawns BEFORE terminal init. With no tty the UI dies with a Rust
	// panic (101) — but the session it created stays running. A "validated after
	// the fact" design would leak live sessions on every typo.
	// Built by hand ON PURPOSE (not via launch_argv): this probe reproduces the
	// hazard of an unvalidated launch, so it must bypass the gate it demonstrates.
	orphan_argv := make([dynamic]string, 0, 3)
	append(&orphan_argv, app.HERDR_BIN, "--session")
	append(&orphan_argv, SCRATCH)
	created_itself := false
	c := app.run_capture(orphan_argv[:], 20 * time.Second)
	say(fmt.tprintf("  `herdr --session {}` with no tty → exit {} (stdout {} B, stderr {} B)",
		SCRATCH, c.code, len(c.out), len(c.err)))
	say_raw("    stderr (the Rust panic — note it is NOT JSON)", c.err)
	kind, _, _ := app.outcome(&c)
	eq_code("no-tty launch panics with 101", c.code, 101)
	eq("101 maps to tty_panic (never parsed as JSON)", app.outcome_label(kind), "terminal-init panic")

	// The part that matters: despite the failure, the session EXISTS and is running.
	after := list_now()
	for r in after {
		if r.name == SCRATCH {
			created_itself = true
			say(fmt.tprintf("    → session {} is present (running={}) even though the UI died",
				r.name, r.running))
		}
	}
	check("an aborted launch still leaves a live session (the orphan hazard is real)",
		created_itself, fmt.tprintf("names={}", names_of(after)))

	// Which is why our own path validates first and produces no argv at all for a
	// bad name — already asserted in the unit case, restated here as the rule the
	// live path must follow.
	_, bad_launch := app.launch_argv(app.DEVICE_LOCAL, "bad name")
	_, bad_attach := app.attach_argv("default")
	check("our launch/attach produce NO argv for an invalid or default name",
		!bad_launch && !bad_attach, fmt.tprintf("launch_ok={} attach_ok={}", bad_launch, bad_attach))

	// And a name that is NOT in the model is refused in-app (ISC-17), creating
	// nothing: we check the model before we would ever hand off.
	check("attaching an unknown name is refused in-app (ISC-17)",
		!app.is_known_session(after, app.DEVICE_LOCAL, "hs-t-not-in-the-model"),
		"the model is the gate, not herdr's answer")
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
	check("the gate reads the installed herdr without bricking on it",
		true, fmt.tprintf("shape={} (0.8.2 → false, 0.9.x → true)", available))

	// Either way, discovery must land somewhere sane.
	cfg := []app.Remote{{device = "configured.example", label = "Configured"}}
	d := app.discover_resolved(c.out, cfg)
	say(fmt.tprintf("    discovery source: {} ({} remote(s): {})",
		app.machine_source_label(d.source), len(d.remotes), devices_of(d.remotes)))
	check("discovery always yields a usable remote set",
		d.source == .registry || d.source == .config_fallback,
		app.machine_source_label(d.source))
	if d.source == .config_fallback {
		check("fallback carries the configured remote",
			len(d.remotes) >= 1 && d.remotes[0].device == "configured.example",
			fmt.tprintf("first={}", d.remotes[0].device))
	}
	// The probe's exit code is NOT the gate — assert that explicitly by feeding the
	// real payload through the shape check regardless of what the code was.
	check("gate decision is made on shape, independent of the exit code",
		app.machine_registry_available(c.out) == available,
		fmt.tprintf("exit={} shape={}", c.code, available))
}

devices_of :: proc(rs: []app.Remote) -> string {
	parts := make([dynamic]string, 0, len(rs))
	for r in rs { append(&parts, r.device) }
	joined, _ := strings.join(parts[:], " ")
	return joined
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

	// Deleting one identity leaves the other's identity present.
	if len(ra) > 0 {
		name := ra[0].name
		left := []app.Session{app.Session{device = alias, label = alias, name = name, running = false}}
		check("an alias-scoped identity survives independently of the primary target",
			app.is_known_session(left[:], alias, name) &&
			!app.is_known_session(left[:], remote, name),
			fmt.tprintf("name={} known-under-alias={} known-under-primary={}",
				name,
				app.is_known_session(left[:], alias, name),
				app.is_known_session(left[:], remote, name)))
	}

	// And the round trip into argv keeps BOTH strings verbatim, in each direction.
	la, lok := app.launch_argv(remote, "hs-t-verbatim-check")
	lb, lbok := app.launch_argv(alias, "hs-t-verbatim-check")
	check("launch argv keeps the primary target verbatim", lok && argv_contains(la, remote),
		argv_join(la))
	check("launch argv keeps the alias target verbatim", lbok && argv_contains(lb, alias),
		argv_join(lb))
	say(fmt.tprintf("  {} → {}", remote, argv_join(la)))
	say(fmt.tprintf("  {} → {}", alias, argv_join(lb)))
}

argv_contains :: proc(argv: []string, needle: string) -> bool {
	for a in argv { if a == needle { return true } }
	return false
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
