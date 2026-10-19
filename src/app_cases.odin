package main

// PHASE 3 DRIVER — the herdr integration, proven before any UI exists.
//
// Two cases, because the two halves of Phase 3 need different evidence:
//
//   app-unit  pure functions, no subprocess. Every rule that can be pinned down
//             with a table: name validation, the timestamp parsed out of the name
//             (D3), the (device,name) identity rule, `default` filtering (D12),
//             the exit-code contract, the `machine` feature gate (D1), and the
//             parked cleanup policy (D2). Deterministic, offline, runs anywhere.
//
//   app-live  the same rules against the real herdr binary and a real ssh hop.
//             Anything that could differ between "our model of herdr" and "what
//             herdr does" is checked here, with the raw byte-level capture printed
//             into the typescript so a human can re-read the evidence later.
//
// SAFETY: every session this creates is named `hs-t-*` and is torn down by
// dev/app-smoke.sh's trap, which runs even on failure. The session hosting this
// agent is never touched — see the guard in case_app_live.

import app "./app"

import "core:fmt"
import "core:sort"
import "core:strings"
import "core:time"

// scratch_prefix is the ONLY name prefix this driver may create.
SCRATCH_PREFIX :: "hs-t-"

// to_bytes turns a literal into the []byte a Capture or parser wants.
// (`transmute` refuses untyped expressions, so every call site goes through here.)
to_bytes :: proc(s: string) -> []byte {
	return transmute([]byte)(s)
}

// ---------------------------------------------------------------------------
// Tiny assertion helpers layered on main.odin's check()
// ---------------------------------------------------------------------------

// eq checks string equality with both sides quoted in the detail, because a
// one-character difference (a stray dash in a timestamp) is invisible otherwise.
eq :: proc(name: string, got, want: string) {
	check(name, got == want, fmt.tprintf("got %q want %q", got, want))
}

eq_i :: proc(name: string, got, want: i64) {
	check(name, got == want, fmt.tprintf("got {} want {}", got, want))
}

eq_int :: proc(name: string, got, want: int) {
	check(name, got == want, fmt.tprintf("got {} want {}", got, want))
}

ne_i :: proc(name: string, got, not_want: i64) {
	check(name, got != not_want, fmt.tprintf("got {} (must differ from {})", got, not_want))
}

say_raw :: proc(label: string, data: []byte) {
	say(fmt.tprintf("  %s: %q ({} bytes)", label, string(data), len(data)))
}

// ---------------------------------------------------------------------------
// app-unit — pure model + contract checks
// ---------------------------------------------------------------------------

case_app_unit :: proc() -> bool {
	say("case app-unit — model, validation, and the exit-code contract")

	unit_scrub()
	unit_names()
	unit_timestamp()
	unit_identity()
	unit_parse_list()
	unit_exit_contract()
	unit_machine_gate()
	unit_cleanup()
	unit_argv()

	return !any_failed
}

// unit_scrub — ISC-2: the scrubbed map has no HERDR_* key but keeps TERM.
unit_scrub :: proc() {
	env, err := app.env_snapshot()
	if err != nil {
		check("env_snapshot", false, fmt.tprintf("{}", err))
		return
	}
	leaked := make([dynamic]string, 0, 8)
	for k, _ in env {
		if app.env_is_herdr_namespace(k) { append(&leaked, k) }
	}
	sort_strings(to_slice_of_strings(leaked))
	say(fmt.tprintf("  live env carries {} HERDR_* key(s): {}", len(leaked), to_slice_of_strings(leaked)))

	clean := app.scrub_env(env)
	still := make([dynamic]string, 0, 8)
	for k, _ in clean {
		if app.env_is_herdr_namespace(k) { append(&still, k) }
	}
	check("scrub_env removes every HERDR_* key", len(still) == 0,
		fmt.tprintf("{} leaked: {}", len(still), to_slice_of_strings(still)))
	check("scrub_env keeps TERM", "TERM" in clean,
		fmt.tprintf("TERM={}", clean["TERM"]))

	// The scrub is prefix-based, so HERDRTHING is also gone while TERM/COLORTERM
	// survive: assert on the namespace boundary, not a hand-picked list.
	synthetic := make(map[string]string)
	synthetic["HERDR_ENV"] = "1"
	synthetic["HERDR_SESSION"] = "2026-08-11-23-37-41-812"
	synthetic["HERDR_SOCKET_PATH"] = "/x/herdr.sock"
	synthetic["HERDR_CLIENT_SOCKET_PATH"] = "/x/client.sock"
	synthetic["HERDR_PANE_ID"] = "p1"
	synthetic["HERDR_TAB_ID"] = "t1"
	synthetic["HERDR_WORKSPACE_ID"] = "w1"
	synthetic["TERM"] = "xterm-256color"
	synthetic["COLORTERM"] = "truecolor"
	c := app.scrub_env(synthetic)
	kept := 0
	for k, _ in c {
		kept += 1
		if app.env_is_herdr_namespace(k) {
			check(fmt.tprintf("synthetic scrub drops {}", k), false, "still present")
		}
	}
	check("synthetic scrub keeps exactly TERM + COLORTERM", kept == 2,
		fmt.tprintf("kept {} keys", kept))
	eq("TERM survives verbatim", c["TERM"], "xterm-256color")
	eq("COLORTERM survives verbatim", c["COLORTERM"], "truecolor")
}

sort_strings :: proc(s: []string) {
	less :: proc(a, b: string) -> int {
		if a < b { return -1 }
		if a > b { return 1 }
		return 0
	}
	sort.quick_sort_proc(s, less)
}

to_slice_of_strings :: proc(d: [dynamic]string) -> []string { return d[:] }

// unit_names — the charset rule, and the `default` / `.` / `..` refusals.
unit_names :: proc() {
	name_case :: struct {
		name : string,
		want : bool,
		why  : string,
	}
	cases := []name_case{
		{"2026-10-18-20-30-45-123", true,  "a bare herdr-cycle name"},
		{"api-2026-10-18-20-30-45-123", true, "a named new session"},
		{"mydb", true, "plain name"},
		{"a_b.c-d9", true, "all legal punctuation"},
		{"", false, "empty is refused"},
		{"default", false, "D12: never default"},
		{".", false, "path component"},
		{"..", false, "path component"},
		{"bad name", false, "space"},
		{"bad:name", false, "colon — NOT in the charset"},
		{"bad/name", false, "slash"},
		{"bad$name", false, "dollar"},
		{"bad\u00e9name", false, "non-ASCII"},
	}
	for c in cases {
		name, want, why := c.name, c.want, c.why
		got := app.validate_name(name)
		want_reason := ""
		if !want { want_reason = got.reason }
		check(fmt.tprintf("name {} -> {}", name), got.ok == want,
			fmt.tprintf("{} ({}); reason={}", want, why, want_reason))
	}

	// Length bound: NAME_MAX_LEN is inclusive-safe on both sides.
	edge_ok, _ := strings.repeat("a", app.NAME_MAX_LEN)
	edge_big, _ := strings.repeat("a", app.NAME_MAX_LEN + 1)
	check("name of exactly NAME_MAX_LEN is accepted", app.name_is_ok(edge_ok),
		fmt.tprintf("len={}", len(edge_ok)))
	check("name of NAME_MAX_LEN+1 is refused", !app.name_is_ok(edge_big),
		fmt.tprintf("len={}", len(edge_big)))
}

// unit_timestamp — D3: the timestamp comes out of the NAME, and its absence sorts last.
unit_timestamp :: proc() {
	eq("bare cycle ts parses", ts_text("2026-10-18-20-30-45-123"),
	   "2026-10-18 20:30:45.123")
	eq("named cycle ts parses", ts_text("api-2026-10-18-20-30-45-123"),
	   "2026-10-18 20:30:45.123")
	eq("no ts -> em dash", ts_text("mydb"), app.UNKNOWN_TIMESTAMP_MARK)
	eq("too short -> em dash", ts_text("2026"), app.UNKNOWN_TIMESTAMP_MARK)

	// The separator rule: without the dash the tail is part of a longer word and
	// must NOT be read as a timestamp.
	eq("no separator -> em dash", ts_text("mydb2026-10-18-20-30-45-12"),
	   app.UNKNOWN_TIMESTAMP_MARK)
	// One character off the millis width breaks the fixed-shape match.
	eq("wrong width -> em dash", ts_text("2026-10-18-20-30-45-12"),
	   app.UNKNOWN_TIMESTAMP_MARK)
	// Right shape, impossible moment: components_to_time rejects, no silent rollover.
	eq("impossible calendar date -> em dash", ts_text("2026-13-45-99-99-99-000"),
	   app.UNKNOWN_TIMESTAMP_MARK)
	eq("feb 30 -> em dash", ts_text("2026-02-30-12-00-00-000"),
	   app.UNKNOWN_TIMESTAMP_MARK)

	// Ordering: ascending by ts, unknown LAST, within one device group.
	sessions := [dynamic]app.Session{}
	append(&sessions,
		mk("local", "zzz-no-ts", false),
		mk("local", "b-2026-10-18-20-30-45-123", true),
		mk("local", "a-2026-10-17-20-30-45-123", true),
		mk("local", "aaa-no-ts", false),
	)
	app.sort_sessions(sessions[:])
	got := names_of(sessions[:])
	eq("ts ascending, unknown last within group", got,
	   "a-2026-10-17-20-30-45-123,b-2026-10-18-20-30-45-123,aaa-no-ts,zzz-no-ts")

	// new_session_name (D11) generates the exact parseable format and avoids collisions.
	taken := []string{"2026-01-01-00-00-00-000"}
	name, ok := app.new_session_name("", taken)
	check("new_session_name generates", ok && len(name) > 0, fmt.tprintf("%q ok={}", name, ok))
	check("generated name parses as a timestamp", app.ts_is_known(app.ts_from_name(name)),
		fmt.tprintf("{} -> {}", name, app.ts_display(app.ts_from_name(name))))
	named, nok := app.new_session_name("api", taken)
	check("new_session_name with prefix", nok && strings.has_prefix(named, "api-"),
		fmt.tprintf("%q", named))
	check("prefixed generated name parses", app.ts_is_known(app.ts_from_name(named)),
		fmt.tprintf("{} -> {}", named, app.ts_display(app.ts_from_name(named))))

	// A generated name must never collide with the taken set.
	busy := make([dynamic]string, 0, 4)
	for _ in 0..<3 {
		n, _ := app.new_session_name("", busy[:])
		append(&busy, n)
	}
	dup := 0
	for i in 0..<len(busy) {
		for j in i + 1..<len(busy) { if busy[i] == busy[j] { dup += 1 } }
	}
	check("successively generated names are distinct", dup == 0,
		fmt.tprintf("{} generated, {} collisions", len(busy), dup))
}

// mk builds a Session the way `parse_session_list` does — ts derived from the
// name, never hand-set — so a test cannot accidentally assert on a row shape the
// product never produces.
mk :: proc(device: string, name: string, running: bool) -> app.Session {
	return app.Session{
		device = device,
		label = device,
		name = name,
		running = running,
		ts = app.ts_from_name(name),
	}
}

ts_text :: proc(name: string) -> string {
	return app.ts_display(app.ts_from_name(name))
}

names_of :: proc(sessions: []app.Session) -> string {
	out := make([dynamic]string, 0, len(sessions))
	for s in sessions { append(&out, s.name) }
	joined, _ := strings.join(out[:], ",")
	return joined
}

// unit_identity — the (device, name) rule, which is the one bug a single-host
// test suite can never catch.
unit_identity :: proc() {
	sessions: [dynamic]app.Session = {}
	append(&sessions,
		// The SAME session name on two DIFFERENT devices. These are two sessions.
		mk("workbox", "api", true),
		mk("homebox", "api", false),
		mk(app.DEVICE_LOCAL, "api", true),
	)
	eq("three rows survive because device differs", names_of(sessions[:]), "api,api,api")
	eq_int("local/api is found by (device,name)",
		app.index_of_identity(sessions[:], app.DEVICE_LOCAL, "api"), 2)
	eq_int("workbox/api is found by (device,name)",
		app.index_of_identity(sessions[:], "workbox", "api"), 0)
	eq_int("homebox/api is found by (device,name)",
		app.index_of_identity(sessions[:], "homebox", "api"), 1)
	check("a device the model does not know is NOT found",
		!app.is_known_session(sessions[:], "otherbox", "api"),
		"identity is the pair, not the name")

	// Key() is the identity accessor, not a display field.
	kd, kn := app.Key(&sessions[0])
	eq("Key().device", kd, "workbox")
	eq("Key().name", kn, "api")
	check("same_identity distinguishes devices with equal names",
		!app.same_identity(&sessions[0], &sessions[1]),
		"workbox/api != homebox/api")
	check("same_identity matches an exact pair",
		app.same_identity(&sessions[0], &sessions[0]), "same row")

	// Ordering: the local group always leads, remotes sort by device string, and
	// one device's group is never interleaved with another's.
	mixed: [dynamic]app.Session = {}
	append(&mixed,
		mk("zeta", "x-2026-10-19-00-00-00-000", true),
		mk(app.DEVICE_LOCAL, "y-2026-10-20-00-00-00-000", true),
		mk("alpha", "x-2026-10-18-00-00-00-000", true),
		mk("zeta", "a-2026-10-17-00-00-00-000", true),
	)
	app.sort_sessions(mixed[:])
	groups := ""
	for s in mixed { groups = fmt.tprintf("{}{}/", groups, s.device) }
	eq("local first, groups contiguous, ts ascending inside each", groups,
	   "local/alpha/zeta/zeta/")

	// names_for_device is per-device, for collision checks at creation time.
	// names_for_device projects in insertion order (it is a filter, not a sort),
	// and it must include ONLY that device's names.
	nz := app.names_for_device(mixed[:], "zeta")
	joined_nz, _ := strings.join(nz, "+")
	eq("names_for_device is scoped to one device", joined_nz,
	   "a-2026-10-17-00-00-00-000+x-2026-10-19-00-00-00-000")
	eq_int("names_for_device excludes every other device",
		len(app.names_for_device(mixed[:], "nosuchhost")), 0)
}

// unit_parse_list — the --json reader, including the D12 filter and the
// "unexpected payload degrades, never bricks" rule.
unit_parse_list :: proc() {
	real := `{` +
		`"sessions":[` +
		`{"default":true,"name":"default","running":false,"session_dir":"/h","socket_path":"/h/herdr.sock"},` +
		`{"default":false,"name":"2026-08-11-23-37-41-812","running":true,"session_dir":"/a","socket_path":"/a/herdr.sock"},` +
		`{"default":false,"name":"2026-08-30-14-59-10-730","running":true,"session_dir":"/b","socket_path":"/b/herdr.sock"}` +
		`]}`
	rows, ok := app.parse_session_list(to_bytes(real), app.DEVICE_LOCAL, app.DEVICE_LOCAL)
	check("parse ok", ok, fmt.tprintf("{} rows", len(rows)))
	eq("default filtered out (D12), two live rows remain", names_of(rows),
	   "2026-08-11-23-37-41-812,2026-08-30-14-59-10-730")
	check("every row is tagged local", rows[0].device == app.DEVICE_LOCAL &&
		rows[1].device == app.DEVICE_LOCAL, "device is carried by the parser, not inferred later")
	check("running passthrough is the live probe value",
		rows[0].running && rows[1].running, fmt.tprintf("{} {}", rows[0].running, rows[1].running))
	check("ts parsed from name during parse", app.ts_is_known(rows[0].ts),
		app.ts_display(rows[0].ts))
	check("has_sessions_field accepts the real payload",
		app.has_sessions_field(to_bytes(real)), "object with a sessions array")

	// A `default:true` entry with a DIFFERENT name must still be filtered: the rule
	// is the flag, not the name.
	flagged := `{"sessions":[{"default":true,"name":"weird","running":true}]}`
	rows2, ok2 := app.parse_session_list(to_bytes(flagged), app.DEVICE_LOCAL, "")
	check("default:true filtered even under another name",
		ok2 && len(rows2) == 0, fmt.tprintf("{} rows", len(rows2)))

	// Degradation: garbage in -> ok=false, no rows, no crash, no partial rows.
	bad := []string{
		`not json at all`,
		``,
		`{"sessions": "nope"}`,
		`{"sessions": [1,2,3]}`,
		`[1,2,3]`,
		"\x1b[31mcolour banner\x1b[0m",
	}
	for b in bad {
		r, o := app.parse_session_list(to_bytes(b), app.DEVICE_LOCAL, "")
		check(fmt.tprintf("bad payload degrades: %q", b), !o && len(r) == 0,
			fmt.tprintf("ok={} rows={}", o, len(r)))
	}
	check("has_sessions_field rejects a non-object",
		!app.has_sessions_field(to_bytes(`[1,2]`)), "array is not our shape")
	check("has_sessions_field rejects a wrong-typed sessions key",
		!app.has_sessions_field(to_bytes(`{"sessions":"x"}`)), "not an array")
	// Forward compatibility: unknown extra keys are ignored, not fatal.
	fwd := `{"sessions":[{"default":false,"name":"x","running":true,"brand_new_field":42}],"extra":{"a":1}}`
	r3, o3 := app.parse_session_list(to_bytes(fwd), "box", "box")
	check("unknown extra JSON fields do not break parsing", o3 && len(r3) == 1,
		fmt.tprintf("ok={} rows={}", o3, len(r3)))
}

// unit_exit_contract — every code in the contract maps to a distinct kind, and the
// authoritative stream is chosen by the code and nothing else.
unit_exit_contract :: proc() {
	// code -> expected kind (contract table from herdr.odin's header).
	exit_case :: struct { code : i32, want : string }
	// The label column is what the UI would print, so the table spells the
	// human-readable strings `outcome_label` returns.
	expect := []exit_case{
		{0, "ok"},
		{1, "herdr error"},
		{2, "bad command line"},
		{101, "terminal-init panic"},
		{124, "timed out"},
		{127, "herdr not installed there"},
		{255, "ssh failed"},
		{7, "unknown error"},
	}
	for e in expect {
		code := e.code
		c := app.Capture{code = code, spawned = true}
		if code == 124 { c.timed_out = true }
		kind, payload, _ := app.outcome(&c)
		label := app.outcome_label(kind)
		eq(fmt.tprintf("exit {} maps to", code), label, e.want)

		// The split: exit 0 reads STDOUT, every other code reads STDERR.
		c.out = to_bytes(`{"stdout_marker":1}`)
		c.err = to_bytes(`{"error":{"code":"boom","message":"stderr marker"}}`)
		kind2, payload2, herr2 := app.outcome(&c)
		if code == 0 {
			check("exit 0 → STDOUT is authoritative",
				strings.contains(string(payload2), "stdout_marker"),
				fmt.tprintf("payload={}", string(payload2)))
			check("exit 0 → no error envelope parsed", !herr2.present, "")
		} else if kind2 == .tty_panic {
			check("exit 101 → NO payload parsed (Rust panic is not JSON)",
				payload2 == nil && !herr2.present,
				fmt.tprintf("payload={}", payload2 == nil))
		} else if code == 124 {
			// Our own timeout has no child stream to be authoritative about: the
			// kind is the answer, and the payload stays empty.
			check("exit 124 → no payload claimed from either stream",
				len(payload2) == 0, fmt.tprintf("payload={}", string(payload2)))
		} else {
			check(fmt.tprintf("exit {} → STDERR is authoritative", code),
				strings.contains(string(payload2), "stderr marker"),
				fmt.tprintf("payload={}", string(payload2)))
			if e.code == 1 {
				check("exit 1 → error code+message parsed out of stderr",
					herr2.present && herr2.code == "boom",
					fmt.tprintf("present={} code={} message={}", herr2.present, herr2.code, herr2.message))
			}
		}
		_ = payload
	}

	// 101 must not be mistaken for a parseable error even when stderr *contains*
	// JSON-shaped text — the panic text is not an envelope.
	c := app.Capture{
		code = 101,
		spawned = true,
		err = to_bytes("thread 'main' panicked at init.rs:299: failed to initialize terminal"),
	}
	k, p, h := app.outcome(&c)
	check("panic text is never presented as a herdr error",
		k == .tty_panic && !h.present && p == nil,
		fmt.tprintf("kind={} present={}", app.outcome_label(k), h.present))

	// not-spawned is distinct from every child answer.
	c2 := app.Capture{code = 127, spawned = false}
	k2, _, _ := app.outcome(&c2)
	eq("we could not spawn → its own kind", app.outcome_label(k2), "herdr not found")

	// A timeout is OUR code and outranks whatever the child's status was.
	c3 := app.Capture{code = 0, spawned = true, timed_out = true}
	k3, _, _ := app.outcome(&c3)
	eq("our timeout outranks the child", app.outcome_label(k3), "timed out")

	// Distinctness: 8 codes, 8 distinct labels — a collapse here would hide errors.
	seen := make(map[string]bool)
	codes := []i32{0, 1, 2, 101, 124, 127, 255, 7}
	for code in codes {
		cx := app.Capture{code = code, spawned = true, timed_out = code == 124}
		kx, _, _ := app.outcome(&cx)
		seen[app.outcome_label(kx)] = true
	}
	eq_i("all 8 exit codes map to distinct meanings", i64(len(seen)), 8)
}

// unit_machine_gate — D1: gate on JSON SHAPE, never on the exit code.
unit_machine_gate :: proc() {
	// herdr 0.8.2: no `machine` subcommand at all.
	eight_o_two := to_bytes("unknown command: machine\nrun 'herdr --help' for usage\n")
	check("0.8.2 'unknown command' text → NO registry",
		!app.machine_registry_available(eight_o_two), "plain text, no JSON")

	// The trap this gate exists for: help banner on STDOUT with EXIT 0. A
	// code-only check would call that a registry.
	help_banner := to_bytes(
		"herdr — terminal workspace manager\n\nUsage: herdr [options]\n  machine list  List machines\n")
	code_zero_help := app.Capture{code = 0, spawned = true, out = help_banner}
	k, payload, _ := app.outcome(&code_zero_help)
	check("exit 0 + help banner: outcome says ok (it is only exit-code truth)",
		k == .ok, "the shape check is what saves us, downstream of outcome")
	check("help banner with exit 0 is NOT a registry",
		!app.machine_registry_available(payload), "no machines array in a help banner")

	// 0.9-style registry: object with a machine array (both plausible key names).
	with_machines := to_bytes(
		`{"machines":[{"id":"workbox","label":"Work","ssh_target":"alice@workbox.example"}]}`)
	check("object with machines array → registry",
		app.machine_registry_available(with_machines), "the gate passes on shape alone")

	remotes_key := to_bytes(
		`{"remotes":[{"id":"x","ssh_target":"y"}]}`)
	check("object WITHOUT a machines array → no registry",
		!app.machine_registry_available(remotes_key),
		"a differently-shaped object is not the registry")

	// Registry entries parse; junk entries are skipped rather than fatal.
	mixed := to_bytes(`{"machines":[
		{"name":"workbox","label":"Work","host":""},
		{"name":"","host":"bob@homebox"},
		{"name":"","host":"","alias":""}]}`)
	rs, ok := app.parse_machine_list(mixed)
	check("parse_machine_list ok", ok, fmt.tprintf("{} remotes", len(rs)))
	eq("entry 1 device verbatim", rs[0].device, "workbox")
	eq("entry 2 falls back to host", rs[1].device, "bob@homebox")
	eq_i("empty entries are dropped, not fatal", i64(len(rs)), 2)

	// The VERBATIM rule: no normalisation anywhere on the device string.
	v := to_bytes(`{"machines":[{"name":"Alice@Work.Box.Example:2222"}]}`)
	vs, _ := app.parse_machine_list(v)
	eq("device string is never normalised", vs[0].device, "Alice@Work.Box.Example:2222")

	// Discovery precedence.
	cfg := []app.Remote{
		{device = "cfgbox", label = "Config Box"},
		{device = "workbox", label = "duplicate-of-registry"},
		{device = "local", label = "should be dropped from the remote list"},
	}
	d := app.discover_resolved(with_machines, cfg)
	check("registry wins as the source", d.source == .registry,
		app.machine_source_label(d.source))
	check("local is never in the remote list",
		!contains_device(d.remotes, app.DEVICE_LOCAL), "the local group is implicit")
	// The dedup key is the VERBATIM device string, so the registry entry and a
	// config entry with the same string collapse; nothing else does.
	eq_int("registry + config merge, deduped on the device string", len(d.remotes), 3)
	eq("registry entry first, device verbatim from ssh_target", d.remotes[0].device,
	   "alice@workbox.example")
	eq("registry label wins over the config label", d.remotes[0].label, "Work")
	eq("config-only entries follow the registry", d.remotes[1].device, "cfgbox")

	// Fallback when the gate fails.
	d2 := app.discover_resolved(eight_o_two, cfg)
	check("gate fails → config fallback", d2.source == .config_fallback,
		app.machine_source_label(d2.source))
	eq_i("fallback carries the config remotes", i64(len(d2.remotes)), 2)
	eq("fallback drops local too", d2.remotes[0].device, "cfgbox")

	// Registry present but empty → still fall back rather than show no remotes.
	empty := to_bytes(`{"machines":[]}`)
	d3 := app.discover_resolved(empty, cfg)
	check("empty registry → config fallback", d3.source == .config_fallback,
		fmt.tprintf("{} / {} remotes", app.machine_source_label(d3.source), len(d3.remotes)))

	// The table's device groups: local implicit + one group per remote.
	groups := app.devices_for_table(d2)
	gstr := ""
	gparts := make([dynamic]string, 0, 8)
	for g in groups { append(&gparts, g.target) }
	gstr, _ = strings.join(gparts[:], ",")
	eq("table groups: local first, then the fallback remotes", gstr, "local,cfgbox,workbox")
}

contains_device :: proc(rs: []app.Remote, device: string) -> bool {
	for r in rs { if r.device == device { return true } }
	return false
}

// unit_cleanup — D2 is PARKED: nothing gets destroyed by default.
unit_cleanup :: proc() {
	eq("default policy is 'never'", policy_text(app.DEFAULT_CLEANUP_POLICY), "never")
	eq("current policy is the default", policy_text(app.cleanup_policy()), "never")

	check("never → nothing destroyed, even for a session we created",
		!app.cleanup_should_run(.never, "hs-t-x", true), "")
	check("never → nothing destroyed, even for the user's own session",
		!app.cleanup_should_run(.never, "user-session", false), "")
	check("only_created → destroys only what we created",
		app.cleanup_should_run(.only_created, "hs-t-x", true) &&
		!app.cleanup_should_run(.only_created, "user-session", false), "")
	check("always → destroys (available but not the default)",
		app.cleanup_should_run(.always, "anything", false), "")
	check("D12 outranks EVERY policy: default is never destroyed",
		!app.cleanup_should_run(.always, "default", true) &&
		!app.cleanup_should_run(.only_created, "default", true), "")

	// The seam is settable, so un-parking D2 is one assignment and nothing else.
	app.set_cleanup_policy(.only_created)
	eq("policy is settable at runtime (the seam works)",
		policy_text(app.cleanup_policy()), "only_created")
	app.set_cleanup_policy(app.DEFAULT_CLEANUP_POLICY)
	eq("policy restored to the parked default",
		policy_text(app.cleanup_policy()), "never")
}

policy_text :: proc(p: app.Cleanup_Policy) -> string {
	#partial switch p {
	case .never: return "never"
	case .only_created: return "only_created"
	case .always: return "always"
	}
	return "?"
}

// unit_argv — the launch round-trip must carry the device string verbatim.
unit_argv :: proc() {
	la, ok := app.launch_argv(app.DEVICE_LOCAL, "mydb")
	check("local launch argv built", ok, app_argv_text(la))
	eq("local launch is `herdr --session <name>`", app_argv_text(la), "herdr --session mydb")

	ra, rok := app.launch_argv("alice@workbox.example", "mydb")
	check("remote launch argv built", rok, app_argv_text(ra))
	eq("remote launch carries --remote VERBATIM", app_argv_text(ra),
	   "herdr --remote alice@workbox.example --session mydb")

	// The same device string must be what our ssh fetch uses — one string, three uses.
	fa := app.remote_list_argv("Alice@Work.Box.Example")
	eq("ssh fetch uses the same verbatim device string", app_argv_text(fa),
	   "ssh -T -o BatchMode=yes -o ConnectTimeout=5 Alice@Work.Box.Example herdr session list --json")

	aa, aok := app.attach_argv("2026-10-18-20-30-45-123")
	check("attach argv built", aok, "")
	eq("attach argv", app_argv_text(aa), "herdr session attach 2026-10-18-20-30-45-123")

	eq("stop argv is --json", app_argv_text(app.stop_argv("x")), "herdr session stop --json x")
	eq("delete argv is --json", app_argv_text(app.delete_argv("x")), "herdr session delete --json x")
	eq("list argv is --json", app_argv_text(app.list_argv()), "herdr session list --json")
	eq("machine probe argv", app_argv_text(app.machine_probe_argv()), "herdr machine list --json")

	// Validation gate: a bad name must produce NO argv at all.
	bad_names := []string{"", "default", "bad name", "bad:name", ".", ".."}
	for n in bad_names {
		bad_l, bad_launch_ok := app.launch_argv(app.DEVICE_LOCAL, n)
		bad_a, bad_attach_ok := app.attach_argv(n)
		check(fmt.tprintf("invalid name %q produces no launch/attach argv", n),
			!bad_launch_ok && !bad_attach_ok && len(bad_l) == 0 && len(bad_a) == 0,
			fmt.tprintf("launch_ok={} attach_ok={}", bad_launch_ok, bad_attach_ok))
	}

	// delete_session's pre-check refuses WITHOUT invoking herdr: there is nothing
	// to delete, and invoking it would put `deleted:true` in our own logs for a
	// session that never existed.
	res := app.delete_session([]app.Session{}, app.DEVICE_LOCAL, "hs-never-existed-zz-99", 2 * time.Second)
	check("delete of an unknown session is refused by the pre-check",
		res.refused && !res.deleted && !res.existed,
		fmt.tprintf("refused={} deleted={} existed={} reason={}",
			res.refused, res.deleted, res.existed, res.reason))

	dres := app.delete_session([]app.Session{}, app.DEVICE_LOCAL, "default", 2 * time.Second)
	check("delete of `default` is refused by name (D12)",
		dres.refused && !dres.deleted, fmt.tprintf("reason={}", dres.reason))
}

app_argv_text :: proc(argv: []string) -> string {
	joined, _ := strings.join(argv, " ")
	return joined
}

parse_int :: proc(s: string) -> i32 {
	n := 0
	for c in s { n = n * 10 + int(c - '0') }
	return i32(n)
}
