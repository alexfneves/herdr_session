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
	unit_tty_version_tolerance()
	unit_machine_gate()
	unit_cleanup()
	unit_argv()
	unit_detach_carries_device()
	unit_device_option_injection()
	unit_control_budget()
	unit_stopped_attach_is_legal()

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
		// Two placeholders, two arguments. The previous version passed only `name`
		// into `"name {} -> {}"`, so every one of these lines printed
		// `%!(MISSING ARGUMENT)` in place of the verdict — 13 cases of evidence
		// that looked present but said nothing. Caught by the `%!` guard added to
		// dev/app-smoke.sh.
		check(fmt.tprintf("name '{}' -> ok={}", name, got.ok), got.ok == want,
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

// unit_tty_version_tolerance — RCH-2 / O12: the no-terminal failure has TWO
// shapes in the wild and the product must answer BOTH the same way.
//
// Both payloads below are captured, byte for byte, from real herdr binaries on
// this box:
//
//   0.8.2  -> exit 101 + a Rust panic that never was JSON
//   0.9.5  -> exit  1  + one clean human sentence, also not JSON
//
// The failure this exists to prevent is a map keyed on the code alone: code 1
// is BOTH "herdr refused, read the envelope" and (0.9.3+) "there was no
// terminal". The discriminator is the envelope, so both directions are pinned
// here — the refusal that must NOT be swallowed, and the refusal that must be.
unit_tty_version_tolerance :: proc() {
	say("  — the no-terminal failure across herdr versions (RCH-2 / O12)")

	// ---- 0.8.2: the panic path ------------------------------------------------
	p82 := app.Capture{
		code    = 101,
		spawned = true,
		err = to_bytes("thread 'main' panicked at src/ui/init.rs:299:11:\nfailed to initialize terminal: IoError(Os { code: 25, kind: Uncategorized, message: \"Inappropriate ioctl for device\" })\nnote: run with `RUST_BACKTRACE=1` for a backtrace\n"),
	}
	k82, p_ok82, h82 := app.outcome(&p82)
	say(fmt.tprintf("    0.8.2 exit 101  -> {}", app.outcome_label(k82)))
	check("0.8.2: exit 101 is a terminal failure",
		app.outcome_needs_terminal(k82), app.outcome_label(k82))
	check("0.8.2: the panic is never parsed as a herdr error envelope",
		!h82.present && p_ok82 == nil,
		fmt.tprintf("present={} payload_nil={}", h82.present, p_ok82 == nil))

	// ---- 0.9.5: the clean-message path ---------------------------------------
	// VERBATIM from `env -u HERDR_ENV herdr --session x < /dev/null` on herdr
	// 0.9.5 (RCH-2's capture; the whole line is 116 bytes).
	p95 := app.Capture{
		code = 1,
		spawned = true,
		err = to_bytes("herdr: cannot attach without a usable terminal: Inappropriate ioctl for device (os error 25); run inside a terminal\n"),
	}
	k95, p95_payload, h95 := app.outcome(&p95)
	say(fmt.tprintf("    0.9.5 exit 1    -> {}", app.outcome_label(k95)))
	check("0.9.5: exit 1 with no envelope and a terminal message is a terminal failure",
		app.outcome_needs_terminal(k95), app.outcome_label(k95))
	check("0.9.5: it is NOT mislabelled as the generic herdr error",
		k95 != .herdr_error, fmt.tprintf("kind={}", app.outcome_label(k95)))
	check("0.9.5: nothing was parsed as an envelope (there is none)",
		!h95.present, fmt.tprintf("present={}", h95.present))
	check("0.9.5: the human sentence IS the payload — safe to show the user",
		len(p95_payload) > 0 && strings.contains(string(p95_payload), "terminal"),
		fmt.tprintf("{} bytes, mentions the terminal", len(p95_payload)))

	// ---- THE PAIR: one answer, two codes -------------------------------------
	check("both herdr generations reach the SAME verdict",
		app.outcome_needs_terminal(k82) == app.outcome_needs_terminal(k95) &&
		app.outcome_needs_terminal(k82),
		fmt.tprintf("101 -> {} · 1 -> {}", app.outcome_label(k82), app.outcome_label(k95)))

	// ---- the negative half: exit 1 must NOT become a terminal refusal ---------
	// This is the rule that keeps `nested herdr is disabled`, a failed `stop`,
	// and a rejected session name readable. Each arrives at exit 1 WITH an
	// envelope; if the marker check ran first, or ran without the envelope check,
	// every one of those would tell the user to go find a terminal.
	enveloped := []string{
		`{"error":{"code":"session_stop_failed","message":"session x is not running"}}`,
		`{"error":{"code":"invalid_session_name","message":"name may contain only [A-Za-z0-9._-]"}}`,
	}
	for body in enveloped {
		c := app.Capture{code = 1, spawned = true, err = to_bytes(body)}
		k, _, h := app.outcome(&c)
		check("exit 1 WITH an envelope stays a herdr error (never 'no terminal')",
			k == .herdr_error && h.present,
			fmt.tprintf("kind={} code={}", app.outcome_label(k), h.code))
	}

	// A nested-herdr refusal is plain text on some builds and mentions nothing
	// terminal-shaped; still not a tty failure.
	nested := app.Capture{code = 1, spawned = true,
		err = to_bytes("error: nested herdr is disabled by default.\nsee configuration if you want to enable it.\n")}
	kn, _, _ := app.outcome(&nested)
	check("the nesting refusal is not read as a terminal problem",
		!app.outcome_needs_terminal(kn), app.outcome_label(kn))

	// Exit 1 with an EMPTY stderr is a herdr error with no detail — not a tty
	// failure. (The marker check must not fire on nothing.)
	empty := app.Capture{code = 1, spawned = true}
	ke, _, _ := app.outcome(&empty)
	check("exit 1 with no stderr at all is NOT a terminal refusal",
		ke == .herdr_error, app.outcome_label(ke))

	// A NEW version that invents a third code still has to be answerable. It is:
	// unknown is not terminal, which means a future code cannot silently inherit
	// "go find a terminal" — and if herdr changes the WORDS rather than the code,
	// TTY_REFUSAL_MARKERS is the one list to extend.
	future := app.Capture{code = 137, spawned = true,
		err = to_bytes("herdr: something entirely new happened\n")}
	kf, _, _ := app.outcome(&future)
	check("an unknown code is never misread as a terminal refusal",
		kf == .unknown && !app.outcome_needs_terminal(kf), app.outcome_label(kf))

	// The two terminal kinds stay DISTINCT (the panic and the refusal are
	// different facts and the UI may want different words) while sharing the ONE
	// predicate every caller actually asks.
	check("tty_panic and tty_unavailable are distinct kinds but one answer",
		app.outcome_label(.tty_panic) != app.outcome_label(.tty_unavailable) &&
		app.outcome_needs_terminal(.tty_panic) && app.outcome_needs_terminal(.tty_unavailable),
		fmt.tprintf("{} / {}", app.outcome_label(.tty_panic),
			app.outcome_label(.tty_unavailable)))

	// And neither is a device outage: a host whose herdr cannot find a terminal
	// is a config fact about the whole app, not "that host is down".
	check("a terminal failure is still a per-host 'failed', never 'unreachable'",
		app.device_status_label(app.device_status_of(.tty_unavailable, "")) == "failed" &&
		app.device_status_label(app.device_status_of(.tty_unavailable, "")) !=
		app.device_status_label(.unreachable),
		app.device_status_label(app.device_status_of(.tty_unavailable, "")))
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
	check("registry + config both contributed -> .merged",
		d.source == .merged, app.machine_source_label(d.source))
	check("local is never in the remote list",
		!contains_device(d.remotes, app.DEVICE_LOCAL), "the local group is implicit")
	// The dedup key is the VERBATIM device string, so the registry entry and a
	// config entry with the same string collapse; nothing else does.
	eq_int("registry + config merge, deduped on the device string", len(d.remotes), 3)
	eq("registry entry first, device verbatim from ssh_target", d.remotes[0].device,
	   "alice@workbox.example")
	eq("registry label wins over the config label", d.remotes[0].label, "Work")
	eq("config-only entries follow the registry", d.remotes[1].device, "cfgbox")
	eq_int("the merge reports 1 from the registry", d.from_registry, 1)
	eq_int("the merge reports 2 from the config", d.from_config, 2)

	// Fallback when the gate fails.
	d2 := app.discover_resolved(eight_o_two, cfg)
	check("gate fails -> config fallback", d2.source == .config_fallback,
		app.machine_source_label(d2.source))
	eq_i("fallback carries the config remotes", i64(len(d2.remotes)), 2)
	eq("fallback drops local too", d2.remotes[0].device, "cfgbox")
	eq_int("nothing came from a registry that never answered", d2.from_registry, 0)

	// Registry present but empty -> the configured remotes still stand. This was
	// always true; O13 makes it the RULE rather than a fallback, and the counts
	// below are what distinguish it from "the user configured nothing".
	empty := to_bytes(`{"machines":[]}`)
	d3 := app.discover_resolved(empty, cfg)
	check("empty {machines:[]} registry does NOT suppress the configured remotes",
		len(d3.remotes) == 2, fmt.tprintf("{} remotes, {} from the registry",
			len(d3.remotes), d3.from_registry))
	eq_int("…and the accounting says the registry contributed zero",
		d3.from_registry, 0)
	eq_int("…while the config contributed both", d3.from_config, 2)
	check("…and the gate still KNOWS the registry exists (it is not " +
		"confused with 0.8.2)", d3.registry, fmt.tprintf("registry={}", d3.registry))

	// ---- O13: the shape herdr 0.9.5 ACTUALLY returns ------------------------
	// VERBATIM: `herdr machine list --json` on 0.9.5 prints `[]` — a bare array,
	// not an object. A gate written against the documented `{machines:[…]}` shape
	// reads that as "no registry", which is survivable; a gate that reads it as
	// "registry available, zero machines" and RETURNS that empty set silently
	// drops every host in the user's config. Both halves are pinned here.
	zero_nine_five := to_bytes("[]\n")
	check("0.9.5's bare `[]` IS recognised as a registry answer",
		app.machine_registry_available(zero_nine_five),
		"bare array, not {machines:[…]} — the gate has to accept both shapes")
	z := app.discover_resolved(zero_nine_five, cfg)
	check("O13: machine list == [] + non-empty config -> the config is still there",
		len(z.remotes) == 2,
		fmt.tprintf("{} remote(s): {}", len(z.remotes), devices_of_remotes(z.remotes)))
	eq_int("O13: zero came from the empty registry", z.from_registry, 0)
	eq_int("O13: two came from the config", z.from_config, 2)
	check("O13: and they are the CONFIGURED devices, verbatim",
		z.remotes[0].device == "cfgbox" && z.remotes[1].device == "workbox",
		devices_of_remotes(z.remotes))
	check("O13: the gate reports the registry as PRESENT (not the 0.8.2 path)",
		z.registry, fmt.tprintf("registry={} source={}", z.registry,
			app.machine_source_label(z.source)))

	// A bare array WITH entries must merge too, not just its empty case — otherwise
	// "empty works" would be masking "non-empty ignored".
	bare_full := to_bytes(`[{"label":"Box A","ssh_target":"a@example"},{"label":"Box B","ssh_target":"b@example"}]`)
	check("bare array WITH entries is a registry", app.machine_registry_available(bare_full),
		"same shape rule, non-empty")
	bf := app.discover_resolved(bare_full, cfg)
	eq_i("both bare-array machines merged", i64(len(bf.remotes)), 4)
	eq_int("…2 from the registry", bf.from_registry, 2)
	eq_int("…2 from the config", bf.from_config, 2)
	eq("…registry first, verbatim", bf.remotes[0].device, "a@example")

	// `enabled: false` is respected; absent means enabled.
	off := to_bytes(`[{"ssh_target":"off@example","enabled":false},{"ssh_target":"on@example"}]`)
	offs, _ := app.parse_machine_list(off)
	eq_i("disabled entries are skipped", i64(len(offs)), 1)
	eq("…and the enabled one survives verbatim", offs[0].device, "on@example")

	// Nothing configured AND an empty registry: an empty set, said out loud rather
	// than implied. There must be no state that looks like "we have remotes".
	none := app.discover_resolved(zero_nine_five, []app.Remote{})
	eq_i("empty registry + empty config -> empty set", i64(len(none.remotes)), 0)
	check("…and that is distinguishable from a registry that answered with hosts",
		none.from_registry == 0 && none.source != .merged,
		fmt.tprintf("source={}", app.machine_source_label(none.source)))

	// The table's device groups: local implicit + one group per remote.
	groups := app.devices_for_table(d2)
	gstr := ""
	gparts := make([dynamic]string, 0, 8)
	for g in groups { append(&gparts, g.target) }
	gstr, _ = strings.join(gparts[:], ",")
	eq("table groups: local first, then the fallback remotes", gstr, "local,cfgbox,workbox")
}

// devices_of_remotes renders a remote list for check details, in order.
devices_of_remotes :: proc(rs: []app.Remote) -> string {
	parts := make([dynamic]string, 0, len(rs))
	for r in rs { append(&parts, r.device) }
	body, _ := strings.join(parts[:], " ")
	return body
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


// ---------------------------------------------------------------------------
// P1 — cleanup must carry the DEVICE it belongs to
// ---------------------------------------------------------------------------

// unit_detach_carries_device is the P1 proof, and it is a proof about ARGV
// because that is the only place the bug could ever have been: `cleanup_policy =
// "always"` after detaching from a REMOTE row used to run the BARE local
// `herdr session stop/delete <name>`, which destroyed the LOCAL session that
// happened to share the name. (device, name) is the identity (D8); dropping the
// device half of the pair deletes the wrong session.
//
// Both halves are pinned, because a test that only checked the remote case would
// still pass if someone made the LOCAL case ssh-wrapped too.
unit_detach_carries_device :: proc() {
	say("  — detach cleanup routes through the row's device (P1)")

	// The remote row: both commands must be OUR ssh, aimed at the row's device.
	r_stop, r_del := app.cleanup_argv("alice@build-box.example", "hs-t-p1")
	eq("remote cleanup stop argv", app_argv_text(r_stop),
	   "ssh -T -o BatchMode=yes -o ConnectTimeout=5 alice@build-box.example 'herdr session stop --json hs-t-p1'")
	eq("remote cleanup delete argv", app_argv_text(r_del),
	   "ssh -T -o BatchMode=yes -o ConnectTimeout=5 alice@build-box.example 'herdr session delete --json hs-t-p1'")

	// The device in the HOST slot, verbatim — not the label, not a resolved
	// address, not "local". Index 6 is the operand right after `ssh` + the 5
	// mandatory base args.
	host_i := len(app.SSH_BASE_ARGS) + 1
	eq("remote cleanup stop: host operand is the device verbatim", r_stop[host_i], "alice@build-box.example")
	eq("remote cleanup delete: host operand is the device verbatim", r_del[host_i], "alice@build-box.example")
	eq("remote cleanup runs ssh, not herdr", r_stop[0], "ssh")

	// The local row: bare herdr, no ssh anywhere near it.
	l_stop, l_del := app.cleanup_argv(app.DEVICE_LOCAL, "hs-t-p1")
	eq("local cleanup stop argv carries NO device wrapper", app_argv_text(l_stop),
	   "herdr session stop --json hs-t-p1")
	eq("local cleanup delete argv carries NO device wrapper", app_argv_text(l_del),
	   "herdr session delete --json hs-t-p1")
	eq("local cleanup runs herdr, not ssh", l_stop[0], "herdr")

	// THE regression assertion, stated as the bug itself: the remote cleanup
	// argv must never equal the bare local argv it used to use.
	bare_stop := app.stop_argv("hs-t-p1")
	bare_del := app.delete_argv("hs-t-p1")
	check("remote cleanup is NOT the bare local stop argv (the P1 bug)",
		app_argv_text(r_stop) != app_argv_text(bare_stop),
		fmt.tprintf("remote=%q bare=%q", app_argv_text(r_stop), app_argv_text(bare_stop)))
	check("remote cleanup is NOT the bare local delete argv (the P1 bug)",
		app_argv_text(r_del) != app_argv_text(bare_del),
		fmt.tprintf("remote=%q bare=%q", app_argv_text(r_del), app_argv_text(bare_del)))
	check("…and the two halves of the pair are independently routed",
		r_stop[host_i] == r_del[host_i] && r_stop[host_i] != app.DEVICE_LOCAL,
		fmt.tprintf("stop.host=%q delete.host=%q", r_stop[host_i], r_del[host_i]))

	// A device alias must not be substituted either: the same string goes out
	// that came in, exactly like the attach path's ISC-4 rule.
	// TEST-NET-3 (RFC 5737) documentation space: a numeric target that is not
	// this machine. The loopback literals stay out of src/ on purpose — a test
	// that names the fixture's host is a test that cannot be read as generic.
	a_stop, a_del := app.cleanup_argv("203.0.113.9", "hs-t-p1")
	eq("a numeric device travels verbatim through cleanup stop", a_stop[host_i], "203.0.113.9")
	eq("a numeric device travels verbatim through cleanup delete", a_del[host_i], "203.0.113.9")

	// The notice wording: the user has to be able to tell WHICH machine was
	// cleaned up, which is the whole point of the fix.
	eq("cleanup label for the local device", app.cleanup_target_label(app.DEVICE_LOCAL), "local")
	eq("cleanup label for a remote device", app.cleanup_target_label("build-box"), "build-box")
}

// ---------------------------------------------------------------------------
// P2-7 — a device that starts with `-` is an option, not a host
// ---------------------------------------------------------------------------

unit_device_option_injection :: proc() {
	say("  — a leading `-` device is option injection and is refused (P2-7)")

	bad_targets := []string{
		"-F/tmp/evil",          // ssh -F: read an attacker-chosen CONFIG file
		"-oProxyCommand=nc evil 80", // ssh -o: run an arbitrary command
		"-p2222",
		"-lroot",
		"-",
	}
	for t in bad_targets {
		r := app.Remote{device = t}
		reason := app.remote_invalid_reason(r)
		check(fmt.tprintf("device %q is refused", t),
			!app.remote_is_valid(r), fmt.tprintf("reason=%q", reason))
		check(fmt.tprintf("…with a message that says WHY (option injection): %q", t),
			strings.contains(reason, "OPTION"), fmt.tprintf("reason=%q", reason))
		check(fmt.tprintf("…and names the offending device: %q", t),
			strings.contains(reason, t), fmt.tprintf("reason=%q", reason))
	}

	// The class must not swallow legal targets. `@` mid-string is normal ssh
	// syntax and `:` shows up in `host:port`-style targets people write.
	good := []string{"build-box", "alice@workbox.example", "10.0.0.7", "hub.example"}
	for t in good {
		r := app.Remote{device = t}
		check(fmt.tprintf("legal device %q still passes", t),
			app.remote_is_valid(r), app.remote_invalid_reason(r))
	}

	// Discovery must drop it, so it can never become a row or an argv even if a
	// config file already contains it.
	cfg := []app.Remote{app.Remote{device = "build-box"}, app.Remote{device = "-F/tmp/evil"}}
	kept := 0
	dropped := false
	for r in cfg {
		if app.remote_is_valid(r) {
			kept += 1
		} else if r.device == "-F/tmp/evil" {
			dropped = true
		}
	}
	eq_int("the good remote survives discovery", kept, 1)
	check("the option-shaped remote is dropped", dropped, "")

	// And the CONFIG parser must say so out loud rather than skip silently: a
	// silently-dropped remote looks like a remote that never existed.
	c := app.config_parse_json(
		`{"remotes":["build-box","-F/tmp/evil"],"theme":"gruvbox-dark"}`, "/tmp/hs-inject")
	eq_int("config keeps the one legal remote", len(c.remotes), 1)
	if len(c.remotes) > 0 {
		eq("config's surviving remote is the legal one", c.remotes[0].device, "build-box")
	}
	check("config WARNS about the option-shaped remote", len(c.warnings) > 0,
		fmt.tprintf("warnings={}", len(c.warnings)))
	warned := false
	for w in c.warnings {
		if strings.contains(w, "OPTION") && strings.contains(w, "-F/tmp/evil") { warned = true }
	}
	check("…and the warning names it and says OPTION", warned,
		fmt.tprintf("warnings={}", c.warnings))
}

// ---------------------------------------------------------------------------
// P2-5 — the control budget is derived from the transport, not picked
// ---------------------------------------------------------------------------

unit_control_budget :: proc() {
	say("  — the delete/control budget sits just above ssh's own bound (P2-5)")

	// Read the bound out of the REAL argv rather than hardcoding 5: if someone
	// changes SSH_BASE_ARGS this check moves with it, which is the whole point of
	// deriving the budget from the transport.
	ssh_bound := -1.0
	base: [5]string = app.SSH_BASE_ARGS
	for idx in 0 ..< len(base) {
		a := base[idx]
		if strings.has_prefix(a, "ConnectTimeout=") {
			ssh_bound = f64(parse_int(a[len("ConnectTimeout="):]))
		}
	}
	check("SSH_BASE_ARGS actually carries ConnectTimeout", ssh_bound > 0,
		fmt.tprintf("parsed={}", ssh_bound))

	cb := f64(app.CONTROL_TIMEOUT / time.Second)
	cap_b := f64(app.CAPTURE_TIMEOUT / time.Second)
	check("CONTROL_TIMEOUT > ssh ConnectTimeout (never pre-empts the honest answer)",
		cb > ssh_bound, fmt.tprintf("control={}s ssh={}s", cb, ssh_bound))
	check("CONTROL_TIMEOUT < ssh ConnectTimeout + 2s (never waits much longer than advertised)",
		cb < ssh_bound + 2.0, fmt.tprintf("control={}s ssh={}s", cb, ssh_bound))
	check("CONTROL_TIMEOUT < CAPTURE_TIMEOUT (control is the tight one)",
		cb < cap_b, fmt.tprintf("control={}s capture={}s", cb, cap_b))

	// The worst honest wait: two commands (stop, then delete), each capped.
	worst := 2 * cb
	check("worst-case delete wait (stop+delete) is bounded by 2x the control budget",
		worst <= 2 * cb + 0.001, fmt.tprintf("worst={}s", worst))
	check("…and that is under the OLD 2x CAPTURE_TIMEOUT (20s) the review measured",
		worst < 2 * cap_b, fmt.tprintf("new worst={}s vs old 2x capture={}s", worst, 2 * cap_b))
}

// ---------------------------------------------------------------------------
// P2-4 override — a STOPPED session is still attachable
// ---------------------------------------------------------------------------

// unit_stopped_attach_is_legal pins the deliberate override: the review asked
// for `running == true` on a local attach, and that is NOT what this tool should
// do. `herdr session attach` RESUMES a stopped session; requiring `running`
// would disable resume, which is a core action. The freshness concern is answered
// by re-reading the list (on entering the state and again before the spawn), not
// by forbidding the target.
unit_stopped_attach_is_legal :: proc() {
	say("  — OVERRIDE: attach targets a KNOWN session, stopped or not (P2-4)")

	rows := []app.Session{
		mk(app.DEVICE_LOCAL, "hs-t-stopped", false),
		mk("build-box", "hs-t-stopped", false),
		mk(app.DEVICE_LOCAL, "hs-t-live", true),
	}

	g_local := app.attach_guard(rows, app.DEVICE_LOCAL, "hs-t-stopped")
	check("a STOPPED LOCAL session passes attach_guard (resume is legal)",
		g_local.ok, fmt.tprintf("reason=%q", g_local.reason))
	g_remote := app.attach_guard(rows, "build-box", "hs-t-stopped")
	check("a STOPPED REMOTE session passes attach_guard too",
		g_remote.ok, fmt.tprintf("reason=%q", g_remote.reason))

	// The last-moment re-check agrees, on the same freshest view.
	r_local := app.revalidate_attach(rows, app.DEVICE_LOCAL, "hs-t-stopped")
	check("revalidate_attach agrees: stopped is not a refusal",
		r_local.ok, fmt.tprintf("reason=%q", r_local.reason))

	// What DOES still fail closed: a name the (fresh) model does not have. That
	// is the real hazard — attach creates what it cannot find.
	g_gone := app.attach_guard(rows, app.DEVICE_LOCAL, "hs-t-deleted-elsewhere")
	check("a name missing from the fresh model is STILL refused",
		!g_gone.ok, fmt.tprintf("reason=%q", g_gone.reason))
	r_gone := app.revalidate_attach(rows, app.DEVICE_LOCAL, "hs-t-deleted-elsewhere")
	check("…and revalidate_attach refuses it identically",
		!r_gone.ok && r_gone.reason == g_gone.reason,
		fmt.tprintf("revalidate=%q guard=%q", r_gone.reason, g_gone.reason))
	check("…the refusal says the name is unknown, never `not running`",
		strings.contains(r_gone.reason, "not running on"),
		fmt.tprintf("reason=%q", r_gone.reason))

	// The running row passes both too, so nothing regressed for the common case.
	check("a live session passes both checks",
		app.attach_guard(rows, app.DEVICE_LOCAL, "hs-t-live").ok &&
		app.revalidate_attach(rows, app.DEVICE_LOCAL, "hs-t-live").ok, "")

	// And the refresh predicate: entering the two pick-a-session states is when
	// the loop re-reads. Everything else must NOT trigger a refresh, or a stray
	// keystroke would churn the fan-out.
	check("entering {Attach} requires a refresh", app.state_needs_refresh(.attach), "")
	check("entering {Delete} requires a refresh", app.state_needs_refresh(.delete_session), "")
	no_refresh := []app.State{.mode_selection, .name_local, .remote_server,
		.name_remote_named, .theme, .error}
	for s in no_refresh {
		check(fmt.tprintf("{} does NOT force a refresh", app.state_label(s)),
			!app.state_needs_refresh(s), "")
	}
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
