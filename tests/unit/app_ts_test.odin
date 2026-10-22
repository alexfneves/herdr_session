package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_ts_test.odin — T10 port of `unit_timestamp` (src/app_cases.odin:199).
//
// D3: the timestamp comes out of the NAME. There is no stat() and no sidecar
// file; the name IS the record, so the parse has to be strict — a loose parse
// shows a wrong time next to a session instead of "unknown", and a wrong time
// sorted into the list is worse than an honest em dash.
//
// THE REJECTIONS ARE THE REAL CONTENT
//
// `2026-13-45-99-99-99-000` has the right SHAPE and cannot exist. `2026-02-30`
// likewise. Both must land on UNKNOWN_TIMESTAMP_MARK rather than rolling over
// into a plausible March date — components_to_time rejecting is the property,
// and a silent rollover would sort a nonexistent moment into the list.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

app_ts_battery_app_ts_parses_from_the_name :: proc(c: ^AU_Ctx) {
	au_eq(c, "bare cycle ts parses", au_ts_text("2026-10-18-20-30-45-123"),
		"2026-10-18 20:30:45.123")
	au_eq(c, "named cycle ts parses", au_ts_text("api-2026-10-18-20-30-45-123"),
		"2026-10-18 20:30:45.123")
	au_eq(c, "no ts -> em dash", au_ts_text("mydb"), app.UNKNOWN_TIMESTAMP_MARK)
	au_eq(c, "too short -> em dash", au_ts_text("2026"), app.UNKNOWN_TIMESTAMP_MARK)
}
@(test)
app_ts_parses_from_the_name :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_ts_battery_app_ts_parses_from_the_name(&__c)
}

app_ts_battery_app_ts_rejects_near_misses :: proc(c: ^AU_Ctx) {
	// The separator rule: without the dash the tail is part of a longer word
	// and must NOT be read as a timestamp.
	au_eq(c, "no separator -> em dash", au_ts_text("mydb2026-10-18-20-30-45-12"),
		app.UNKNOWN_TIMESTAMP_MARK)
	// One character off the millis width breaks the fixed-shape match.
	au_eq(c, "wrong width -> em dash", au_ts_text("2026-10-18-20-30-45-12"),
		app.UNKNOWN_TIMESTAMP_MARK)
	// Right shape, impossible moment: components_to_time rejects, no rollover.
	au_eq(c, "impossible calendar date -> em dash",
		au_ts_text("2026-13-45-99-99-99-000"), app.UNKNOWN_TIMESTAMP_MARK)
	au_eq(c, "feb 30 -> em dash", au_ts_text("2026-02-30-12-00-00-000"),
		app.UNKNOWN_TIMESTAMP_MARK)
}
@(test)
app_ts_rejects_near_misses :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_ts_battery_app_ts_rejects_near_misses(&__c)
}

app_ts_battery_app_ts_sorts_ascending_unknown_last :: proc(c: ^AU_Ctx) {
	sessions: [dynamic]app.Session = {}
	append(&sessions,
		au_mk("local", "zzz-no-ts", false),
		au_mk("local", "b-2026-10-18-20-30-45-123", true),
		au_mk("local", "a-2026-10-17-20-30-45-123", true),
		au_mk("local", "aaa-no-ts", false),
	)
	app.sort_sessions(sessions[:])
	au_eq(c, "ts ascending, unknown last within group", au_names_of(sessions[:]),
		"a-2026-10-17-20-30-45-123,b-2026-10-18-20-30-45-123,aaa-no-ts,zzz-no-ts")
}
@(test)
app_ts_sorts_ascending_unknown_last :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_ts_battery_app_ts_sorts_ascending_unknown_last(&__c)
}

app_ts_battery_app_ts_new_session_name_generates_parseably :: proc(c: ^AU_Ctx) {
	taken := []string{"2026-01-01-00-00-00-000"}
	name, ok := app.new_session_name("", taken)
	au_check(c, "new_session_name generates", ok && len(name) > 0,
		fmt.tprintf("%q ok={}", name, ok))
	au_check(c, "generated name parses as a timestamp",
		app.ts_is_known(app.ts_from_name(name)),
		fmt.tprintf("{} -> {}", name, app.ts_display(app.ts_from_name(name))))

	named, nok := app.new_session_name("api", taken)
	au_check(c, "new_session_name with prefix", nok && strings.has_prefix(named, "api-"),
		fmt.tprintf("%q", named))
	au_check(c, "prefixed generated name parses", app.ts_is_known(app.ts_from_name(named)),
		fmt.tprintf("{} -> {}", named, app.ts_display(app.ts_from_name(named))))
}
@(test)
app_ts_new_session_name_generates_parseably :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_ts_battery_app_ts_new_session_name_generates_parseably(&__c)
}

app_ts_battery_app_ts_generated_names_never_collide :: proc(c: ^AU_Ctx) {
	// A generated name must never collide with the taken set. Three draws, all
	// pairwise distinct — the same construction the product uses when a create
	// is issued twice in one millisecond.
	busy: [dynamic]string = {}
	for _ in 0 ..< 3 {
		n, _ := app.new_session_name("", busy[:])
		append(&busy, n)
	}
	dup := 0
	for i in 0 ..< len(busy) {
		for j in i + 1 ..< len(busy) {
			if busy[i] == busy[j] { dup += 1 }
		}
	}
	au_check(c, "successively generated names are distinct", dup == 0,
		fmt.tprintf("{} generated, {} collisions", len(busy), dup))
}
@(test)
app_ts_generated_names_never_collide :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_ts_battery_app_ts_generated_names_never_collide(&__c)
}

