package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_env_test.odin — T10 port of `unit_scrub` (src/app_cases.odin:93).
//
// ISC-2: the scrubbed environment carries no HERDR_* key but keeps TERM.
//
// The old section read the LIVE environment of the driver process, which is
// only interesting when that process is inside a herdr pane. That is why the
// first two assertions take the live map and the rest use a SYNTHETIC one:
// the synthetic block is the part that holds with no herdr on the box at all,
// and it is where the namespace boundary is actually pinned.
//
// WHY THE BOUNDARY AND NOT A LIST
//
// The scrub is prefix-based. An enumerated list of the three keys the product
// reads today would keep passing when a fourth HERDR_* variable is added and
// the test stops covering it. Asserting on the PREFIX keeps the rule honest.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:testing"

import app "../../src/app"
import support "../support"

app_env_battery_app_scrub_live_env_has_no_herdr_keys :: proc(c: ^AU_Ctx) {
	// THE SAME DEFECT THE SPAWN TEST HAD, IN ITS MAP-LEVEL FORM
	//
	// "scrub_env removes every HERDR_* key" over a LIVE snapshot is true of
	// any environment that happens to carry none — and the gate strips the
	// whole HERDR_* namespace before this suite runs. An assertion that
	// cannot fail on the box that runs it most is not an assertion. So the
	// live half arms the shared sentinel first (support/sentinel.odin) and
	// names the armed keys in BOTH halves: present before the scrub, absent
	// after. Removing the scrub turns this red; not arming turns it red.
	//
	// The synthetic half below is untouched and still covers the namespace
	// boundary with values this file owns outright; that is what makes this
	// file hold on a box with no herdr in it at all.
	probe := support.Scrub_Probe{}
	support.probe_arm(&probe)
	defer support.probe_disarm(&probe)

	// HALF 1 — the premise: the snapshot has HERDR_* keys in it, and we know
	// exactly which because we put them there.
	env, err := app.env_snapshot()
	if err != nil {
		au_check(c, "env_snapshot", false, fmt.tprintf("{}", err))
		return
	}

	leaked: [dynamic]string = {}
	for k, _ in env {
		if app.env_is_herdr_namespace(k) { append(&leaked, k) }
	}
	au_say(c, fmt.tprintf("  live env carries {} HERDR_* key(s): {}",
		len(leaked[:]), leaked[:]))
	au_check(c, "the live snapshot carries the armed HERDR_* sentinels (there is something to remove)",
		probe.armed && au_has_key(leaked[:], support.SCRATCH_PROBE_ENV) &&
			au_has_key(leaked[:], support.SCRATCH_PROBE_SESSION),
		fmt.tprintf("armed={} keys={}", probe.armed, leaked[:]))

	clean := app.scrub_env(env)
	still: [dynamic]string = {}
	for k, _ in clean {
		if app.env_is_herdr_namespace(k) { append(&still, k) }
	}
	au_check(c, "scrub_env removes every HERDR_* key", len(still) == 0,
		fmt.tprintf("{} leaked: {}", len(still[:]), still[:]))
	au_check(c, "scrub_env keeps TERM", "TERM" in clean,
		fmt.tprintf("TERM={}", clean["TERM"]))
}

au_has_key :: proc(keys: []string, want: string) -> bool {
	for k in keys { if k == want { return true } }
	return false
}
@(test)
app_scrub_live_env_has_no_herdr_keys :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_env_battery_app_scrub_live_env_has_no_herdr_keys(&__c)
}

app_env_battery_app_scrub_synthetic_namespace_boundary :: proc(c: ^AU_Ctx) {

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

	cc := app.scrub_env(synthetic)
	kept := 0
	for k, _ in cc {
		kept += 1
		if app.env_is_herdr_namespace(k) {
			au_check(c, fmt.tprintf("synthetic scrub drops {}", k), false, "still present")
		}
	}
	au_check(c, "synthetic scrub keeps exactly TERM + COLORTERM", kept == 2,
		fmt.tprintf("kept {} keys", kept))
	au_eq(c, "TERM survives verbatim", cc["TERM"], "xterm-256color")
	au_eq(c, "COLORTERM survives verbatim", cc["COLORTERM"], "truecolor")
}
@(test)
app_scrub_synthetic_namespace_boundary :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_env_battery_app_scrub_synthetic_namespace_boundary(&__c)
}

