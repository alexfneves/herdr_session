package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_identity_test.odin — T10 port of `unit_identity` (src/app_cases.odin:285).
//
// The (device, name) rule is the one bug a single-host test suite can never
// catch. On one box every session name is unique, so a lookup keyed on the
// name alone passes 100% of single-host tests and then deletes someone else's
// session the first time two machines share a name. Every assertion here needs
// at least TWO devices holding the SAME name.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

app_identity_battery_app_identity_pair_not_name :: proc(c: ^AU_Ctx) {
	sessions: [dynamic]app.Session = {}
	append(&sessions,
		// The SAME session name on two DIFFERENT devices. These are two sessions.
		au_mk("workbox", "api", true),
		au_mk("homebox", "api", false),
		au_mk(app.DEVICE_LOCAL, "api", true),
	)
	au_eq(c, "three rows survive because device differs",
		au_names_of(sessions[:]), "api,api,api")
	au_eq_int(c, "local/api is found by (device,name)",
		app.index_of_identity(sessions[:], app.DEVICE_LOCAL, "api"), 2)
	au_eq_int(c, "workbox/api is found by (device,name)",
		app.index_of_identity(sessions[:], "workbox", "api"), 0)
	au_eq_int(c, "homebox/api is found by (device,name)",
		app.index_of_identity(sessions[:], "homebox", "api"), 1)
	au_check(c, "a device the model does not know is NOT found",
		!app.is_known_session(sessions[:], "otherbox", "api"),
		"identity is the pair, not the name")
}
@(test)
app_identity_pair_not_name :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_identity_battery_app_identity_pair_not_name(&__c)
}

app_identity_battery_app_identity_key_accessors :: proc(c: ^AU_Ctx) {
	sessions: [dynamic]app.Session = {}
	append(&sessions, au_mk("workbox", "api", true), au_mk("homebox", "api", false))

	// Key() is the identity accessor, not a display field.
	kd, kn := app.Key(&sessions[0])
	au_eq(c, "Key().device", kd, "workbox")
	au_eq(c, "Key().name", kn, "api")
	au_check(c, "same_identity distinguishes devices with equal names",
		!app.same_identity(&sessions[0], &sessions[1]), "workbox/api != homebox/api")
	au_check(c, "same_identity matches an exact pair",
		app.same_identity(&sessions[0], &sessions[0]), "same row")
}
@(test)
app_identity_key_accessors :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_identity_battery_app_identity_key_accessors(&__c)
}

app_identity_battery_app_identity_sort_groups_are_contiguous :: proc(c: ^AU_Ctx) {
	mixed: [dynamic]app.Session = {}
	append(&mixed,
		au_mk("zeta", "x-2026-10-19-00-00-00-000", true),
		au_mk(app.DEVICE_LOCAL, "y-2026-10-20-00-00-00-000", true),
		au_mk("alpha", "x-2026-10-18-00-00-00-000", true),
		au_mk("zeta", "a-2026-10-17-00-00-00-000", true),
	)
	app.sort_sessions(mixed[:])
	groups := ""
	for s in mixed { groups = fmt.tprintf("{}{}/", groups, s.device) }
	au_eq(c, "local first, groups contiguous, ts ascending inside each", groups,
		"local/alpha/zeta/zeta/")
}
@(test)
app_identity_sort_groups_are_contiguous :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_identity_battery_app_identity_sort_groups_are_contiguous(&__c)
}

app_identity_battery_app_identity_names_for_device_is_scoped :: proc(c: ^AU_Ctx) {
	mixed: [dynamic]app.Session = {}
	append(&mixed,
		au_mk("zeta", "x-2026-10-19-00-00-00-000", true),
		au_mk(app.DEVICE_LOCAL, "y-2026-10-20-00-00-00-000", true),
		au_mk("alpha", "x-2026-10-18-00-00-00-000", true),
		au_mk("zeta", "a-2026-10-17-00-00-00-000", true),
	)
	// Sorted first, exactly as the old section did: names_for_device projects
	// in whatever order the slice is in, so the expected string is the SORTED
	// order. Without the sort this asserts on insertion order by accident.
	app.sort_sessions(mixed[:])
	// names_for_device is per-device, for collision checks at creation time.
	// It projects in INSERTION order (it is a filter, not a sort), and it must
	// include ONLY that device's names.
	nz := app.names_for_device(mixed[:], "zeta")
	joined_nz, _ := strings.join(nz, "+")
	au_eq(c, "names_for_device is scoped to one device", joined_nz,
		"a-2026-10-17-00-00-00-000+x-2026-10-19-00-00-00-000")
	au_eq_int(c, "names_for_device excludes every other device",
		len(app.names_for_device(mixed[:], "nosuchhost")), 0)
}
@(test)
app_identity_names_for_device_is_scoped :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_identity_battery_app_identity_names_for_device_is_scoped(&__c)
}

