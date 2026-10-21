package unit

// ─────────────────────────────────────────────────────────────────────────────
// theme_config_parse_test.odin — every way a config file can be wrong, and what
// it costs the user.
//
// Ported 1:1 from the `config-parse` case: 34 counted assertions.
//
// The invariant these 34 protect is NOT "parsing works". It is the SHAPE of
// the failure: a bad config must cost the user exactly one readable line and
// nothing else. A stack trace, a crash, a silently-different theme, or three
// warnings where one belongs are each a different broken promise, and each has
// its own assertion here for that reason.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

warn_join :: proc(m: app.Config) -> string {
	out := ""
	for w in m.warnings {
		out = fmt.tprintf("{} | {}", out, w)
	}
	return out
}

remote_join :: proc(rs: []app.Remote) -> string {
	out := ""
	for r in rs {
		out = fmt.tprintf("{} {}(label='{}')", out, r.device, r.label)
	}
	return out
}

has_remote_named :: proc(rs: []app.Remote, dev: string) -> bool {
	for r in rs {
		if r.device == dev { return true }
	}
	return false
}

// ── MISSING / BLANK: silent defaults ────────────────────────────────────────

@(test)
config_parse_missing_file_is_silent :: proc(t: ^testing.T) {
	m := app.config_parse_json("", "/tmp/nope/herdr_session.json")
	support.check(t, "missing file: SILENT (no warnings)", len(m.warnings) == 0,
		fmt.tprintf("{} warning(s)", len(m.warnings)))
	support.eq(t, "…defaults to gruvbox-dark", m.theme, "gruvbox-dark")
	support.eq(t, "…cleanup only_created (R1 resolves the parked D2)",
		m.cleanup_policy, "only_created")
	support.check(t, "…no remote hosts", len(m.remotes) == 0,
		fmt.tprintf("{} remote(s)", len(m.remotes)))
	support.check(t, "…reads as absent, not corrupt", !m.present && !m.corrupt,
		fmt.tprintf("present={} corrupt={}", m.present, m.corrupt))
}

@(test)
config_parse_whitespace_only_is_missing :: proc(t: ^testing.T) {
	blank := app.config_parse_json("   \n\t ", "/tmp/nope")
	support.check(t, "whitespace-only file behaves as missing",
		len(blank.warnings) == 0 && !blank.present && blank.theme == "gruvbox-dark",
		fmt.tprintf("present={} theme='{}' warnings={}",
			blank.present, blank.theme, len(blank.warnings)))
}

// ── CORRUPT: defaults + exactly ONE visible warning ─────────────────────────

@(test)
config_parse_corrupt_json_is_loud_once :: proc(t: ^testing.T) {
	bad := app.config_parse_json("{ this is not json at all", "/tmp/bad")
	support.check(t, "corrupt JSON: flagged corrupt", bad.corrupt,
		fmt.tprintf("corrupt={}", bad.corrupt))
	support.check(t, "…still fully usable defaults",
		bad.theme == "gruvbox-dark" && bad.cleanup_policy == "only_created",
		fmt.tprintf("theme='{}' cleanup='{}'", bad.theme, bad.cleanup_policy))
	support.check(t, "…exactly ONE warning line (visible, not a stack trace)",
		len(bad.warnings) == 1, fmt.tprintf("{} warnings: {}", len(bad.warnings), warn_join(bad)))
	support.check(t, "…the warning names the file so the user can fix THAT one",
		strings.contains(bad.warnings[0], "/tmp/bad"), bad.warnings[0])
	support.check(t, "…config_warning_text surfaces it", app.config_warning_text(bad) != "",
		app.config_warning_text(bad))
}

@(test)
config_parse_wrong_root_type_is_corrupt :: proc(t: ^testing.T) {
	arr := app.config_parse_json(`[1,2,3]`, "/tmp/arr")
	support.check(t, "root array is corrupt (must be an object)",
		arr.corrupt && len(arr.warnings) == 1,
		fmt.tprintf("corrupt={} warnings='{}'", arr.corrupt, warn_join(arr)))
	scalar := app.config_parse_json(`42`, "/tmp/scalar")
	support.check(t, "root scalar is corrupt", scalar.corrupt && scalar.theme == "gruvbox-dark",
		warn_join(scalar))
}

// ── THEME VALUE: unknown is loud, alias and cleared are silent ────────────────

@(test)
config_parse_unknown_theme_falls_back_and_warns :: proc(t: ^testing.T) {
	ut := app.config_parse_json(`{"theme":"bogger"}`, "/tmp/ut")
	support.eq(t, "unknown theme falls back to gruvbox-dark", ut.theme, "gruvbox-dark")
	support.check(t, "…flagged fell_back", ut.theme_fell_back,
		fmt.tprintf("fell_back={}", ut.theme_fell_back))
	support.check(t, "…exactly one warning", len(ut.warnings) == 1, warn_join(ut))
	support.check(t, "…warning quotes the bad name AND the replacement",
		strings.contains(ut.warnings[0], "bogger") &&
		strings.contains(ut.warnings[0], "gruvbox-dark"), ut.warnings[0])
}

@(test)
config_parse_alias_in_file_is_honoured_silently :: proc(t: ^testing.T) {
	al := app.config_parse_json(`{"theme":"latte"}`, "/tmp/al")
	support.check(t, "alias 'latte' in the file resolves to catppuccin-latte, silently",
		al.theme == "catppuccin-latte" && len(al.warnings) == 0,
		fmt.tprintf("theme='{}' warnings={}", al.theme, len(al.warnings)))
}

@(test)
config_parse_explicit_empty_theme_is_cleared :: proc(t: ^testing.T) {
	cl := app.config_parse_json(`{"theme":""}`, "/tmp/cl")
	support.check(t, "theme:'' reads as cleared, silent",
		cl.theme == "gruvbox-dark" && !cl.theme_fell_back && len(cl.warnings) == 0,
		fmt.tprintf("theme='{}' fell_back={} warnings={}",
			cl.theme, cl.theme_fell_back, len(cl.warnings)))
}

// ── WRONG-TYPED KEYS: ignore THAT key, keep the file ────────────────────────

@(test)
config_parse_wrong_typed_keys_do_not_lose_the_file :: proc(t: ^testing.T) {
	wt := app.config_parse_json(
		`{"theme":42,"cleanup_policy":["never"],"remotes":"build-box"}`, "/tmp/wt")
	support.check(t, "wrong-typed keys each get a warning", len(wt.warnings) == 3,
		fmt.tprintf("{} warnings: {}", len(wt.warnings), warn_join(wt)))
	support.check(t, "…defaults still hold for every owned key",
		wt.theme == "gruvbox-dark" && wt.cleanup_policy == "only_created" && len(wt.remotes) == 0,
		fmt.tprintf("theme='{}' cleanup='{}' remotes={}",
			wt.theme, wt.cleanup_policy, len(wt.remotes)))
	support.check(t, "…and the file is NOT called corrupt (it parsed fine)",
		!wt.corrupt && wt.present, fmt.tprintf("corrupt={} present={}", wt.corrupt, wt.present))
}

// ── REMOTES: both shapes, VERBATIM, de-duplicated, local dropped ────────────

@(test)
config_parse_remotes_both_shapes_verbatim :: proc(t: ^testing.T) {
	rs := app.config_parse_json(
		`{"remotes":["build-box","deploy@10.0.0.7",{"target":"gpu-node","label":"GPU node"},"local","build-box","","  ",{"label":"no target"}]}`,
		"/tmp/rs")
	support.check(t, "remotes parsed from both string and object forms", len(rs.remotes) == 3,
		fmt.tprintf("{} host(s): {}", len(rs.remotes), remote_join(rs.remotes)))
	support.check(t, "…an ssh target is stored VERBATIM",
		rs.remotes[1].device == "deploy@10.0.0.7", rs.remotes[1].device)
	support.check(t, "…an object entry carries its label",
		rs.remotes[2].device == "gpu-node" && rs.remotes[2].label == "GPU node",
		fmt.tprintf("{} / {}", rs.remotes[2].device, rs.remotes[2].label))
	support.check(t, "…'local' is NOT configurable (discovery owns the local device)",
		!has_remote_named(rs.remotes, "local"), remote_join(rs.remotes))
	support.check(t, "…duplicates and blanks are dropped silently", len(rs.warnings) == 0,
		warn_join(rs))
}

// ── cleanup_policy: three accepted labels, anything else warns ──────────────

@(test)
config_parse_cleanup_policy_accepted_labels :: proc(t: ^testing.T) {
	pols := [3]string{"never", "only_created", "always"}
	for pol in pols {
		c := app.config_parse_json(fmt.tprintf(`{{"cleanup_policy":"{}"}}`, pol), "/tmp/pol")
		support.check(t, fmt.tprintf("cleanup_policy '{}' accepted", pol),
			c.cleanup_policy == pol && len(c.warnings) == 0,
			fmt.tprintf("'{}' warnings={}", c.cleanup_policy, len(c.warnings)))
	}
}

@(test)
config_parse_unknown_cleanup_policy_falls_back_to_never :: proc(t: ^testing.T) {
	// .never is the SAFE direction: an unrecognised policy must never end up
	// meaning "delete things".
	bad_pol := app.config_parse_json(`{"cleanup_policy":"on"}`, "/tmp/badpol")
	support.check(t, "unknown cleanup_policy warns and keeps 'never'",
		bad_pol.cleanup_policy == "never" && len(bad_pol.warnings) == 1, warn_join(bad_pol))
}

// ── UNKNOWN KEYS: not our business, and they must survive a save ────────────

@(test)
config_parse_unknown_keys_load_silently :: proc(t: ^testing.T) {
	uk := app.config_parse_json(`{"theme":"nord","whatever":true,"extra":{"a":[1,2]}}`, "/tmp/uk")
	support.check(t, "unknown extra keys load SILENTLY", len(uk.warnings) == 0,
		fmt.tprintf("{} warning(s): {}", len(uk.warnings), warn_join(uk)))
	support.eq(t, "…and the known key still applied", uk.theme, "nord")
}

// ── JSON5 leniency: a human WILL edit this file ────────────────────────────

@(test)
config_parse_json5_comments_and_trailing_comma :: proc(t: ^testing.T) {
	// The parser's DEFAULT_SPECIFICATION allows // and /* comments and a
	// trailing comma. Asserted because whoever edits this file by hand will
	// write them, and rejecting them would be a trap.
	j5 := app.config_parse_json(
		"{ /* theme for the app */\n \"theme\": \"nord\", // trailing comma on purpose\n}",
		"/tmp/j5")
	support.check(t, "JSON5 comments + trailing comma load (hand-edit friendly)",
		j5.theme == "nord" && !j5.corrupt && len(j5.warnings) == 0,
		fmt.tprintf("theme='{}' corrupt={} warnings={}", j5.theme, j5.corrupt, len(j5.warnings)))
}
