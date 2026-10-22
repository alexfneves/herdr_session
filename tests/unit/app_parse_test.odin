package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_parse_test.odin — T10 port of `unit_parse_list` (src/app_cases.odin:342).
//
// The `--json` reader. Three properties, in order of how much damage each
// prevents:
//
//   1. D12 — `default` never enters the model. Not by name matching: by the
//      `default:true` FLAG, so an entry renamed "weird" but flagged default is
//      still filtered.
//   2. The device is carried by the PARSER, not inferred later. A row that
//      forgets its device is a row that will be acted on locally.
//   3. An unexpected payload DEGRADES. ok=false, zero rows, no partial rows,
//      no crash. A coloured banner from a shell startup file must not brick
//      the list.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import app "../../src/app"
import support "../support"

AU_REAL_LIST :: `{"sessions":` +
	`[{"default":true,"name":"default","running":false,"session_dir":"/h","socket_path":"/h/herdr.sock"},` +
	`{"default":false,"name":"2026-08-11-23-37-41-812","running":true,"session_dir":"/a","socket_path":"/a/herdr.sock"},` +
	`{"default":false,"name":"2026-08-30-14-59-10-730","running":true,"session_dir":"/b","socket_path":"/b/herdr.sock"}]}`

@(test)
app_parse_real_payload :: proc(t: ^testing.T) {
	c := au_live(t)
	rows, ok := app.parse_session_list(au_to_bytes(AU_REAL_LIST),
		app.DEVICE_LOCAL, app.DEVICE_LOCAL)
	au_check(&c, "parse ok", ok, fmt.tprintf("{} rows", len(rows)))
	au_eq(&c, "default filtered out (D12), two live rows remain",
		au_names_of(rows), "2026-08-11-23-37-41-812,2026-08-30-14-59-10-730")
	au_check(&c, "every row is tagged local",
		rows[0].device == app.DEVICE_LOCAL && rows[1].device == app.DEVICE_LOCAL,
		"device is carried by the parser, not inferred later")
	au_check(&c, "running passthrough is the live probe value",
		rows[0].running && rows[1].running,
		fmt.tprintf("{} {}", rows[0].running, rows[1].running))
	au_check(&c, "ts parsed from name during parse", app.ts_is_known(rows[0].ts),
		app.ts_display(rows[0].ts))
	au_check(&c, "has_sessions_field accepts the real payload",
		app.has_sessions_field(au_to_bytes(AU_REAL_LIST)), "object with a sessions array")
}

@(test)
app_parse_default_flag_not_default_name :: proc(t: ^testing.T) {
	c := au_live(t)
	// A `default:true` entry with a DIFFERENT name must still be filtered:
	// the rule is the flag, not the name.
	flagged := `{"sessions":[{"default":true,"name":"weird","running":true}]}`
	rows2, ok2 := app.parse_session_list(au_to_bytes(flagged), app.DEVICE_LOCAL, "")
	au_check(&c, "default:true filtered even under another name",
		ok2 && len(rows2) == 0, fmt.tprintf("{} rows", len(rows2)))
}

@(test)
app_parse_bad_payloads_degrade :: proc(t: ^testing.T) {
	c := au_live(t)
	// Garbage in -> ok=false, no rows, no crash, no partial rows.
	bad := []string{
		`not json at all`,
		``,
		`{"sessions": "nope"}`,
		`{"sessions": [1,2,3]}`,
		`[1,2,3]`,
		"\x1b[31mcolour banner\x1b[0m",
	}
	for b in bad {
		r, o := app.parse_session_list(au_to_bytes(b), app.DEVICE_LOCAL, "")
		au_check(&c, fmt.tprintf("bad payload degrades: %q", b), !o && len(r) == 0,
			fmt.tprintf("ok={} rows={}", o, len(r)))
	}
	au_check(&c, "has_sessions_field rejects a non-object",
		!app.has_sessions_field(au_to_bytes(`[1,2]`)), "array is not our shape")
	au_check(&c, "has_sessions_field rejects a wrong-typed sessions key",
		!app.has_sessions_field(au_to_bytes(`{"sessions":"x"}`)), "not an array")
}

@(test)
app_parse_unknown_fields_are_ignored :: proc(t: ^testing.T) {
	c := au_live(t)
	// Forward compatibility: unknown extra keys are ignored, not fatal. A new
	// herdr that adds a field must not take the list down.
	fwd := `{"sessions":[{"default":false,"name":"x","running":true,"brand_new_field":42}],"extra":{"a":1}}`
	r3, o3 := app.parse_session_list(au_to_bytes(fwd), "box", "box")
	au_check(&c, "unknown extra JSON fields do not break parsing", o3 && len(r3) == 1,
		fmt.tprintf("ok={} rows={}", o3, len(r3)))
}
