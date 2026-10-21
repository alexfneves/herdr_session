package unit

// theme_config_live_test.odin — T9 port of the `config-live` case.
//
// Source: src/theme_cases.odin `case_config_live` (21 counted assertions).
// This is the ONLY theme case that exercises `config_load()`, the real loader,
// as opposed to `config_parse_json`, the total function. It is still in-process
// — no terminal, no fixture, no herdr invocation — so it stays in the hermetic
// tier. It does mutate the PROCESS environment (XDG_CONFIG_HOME), which is why
// every test here is wrapped in redirect/restore.
//
// WHY REDIRECTING XDG_CONFIG_HOME IS ENOUGH HERE, AND WHY THAT DOES NOT
// GENERALISE. `config_load` resolves only its own file, and `os.user_config_dir`
// honours XDG_CONFIG_HOME. The bash version of this case redirected HOME as
// well, because the same sandbox also had to hide the developer's real session
// list from a live `herdr session list`. THERE IS NO SUCH CALL IN THIS FILE.
// Redirecting XDG for a herdr invocation is the known trap: herdr keys its
// state dir off the same XDG conventions, the sandbox has no sessions in it,
// and the test fails with an empty list that reads like an app bug. See
// theme_harness.odin. Nothing deferred here can reintroduce it by accident
// because the deferred work is a PTY test, not an env change.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

@(test)
config_live_missing_file_is_silent_and_creates_nothing :: proc(t: ^testing.T) {
	dir := swap_theme_cfg(t, "live-missing")

	c := app.config_load()
	// It resolved into the temp dir — NOT the developer's real ~/.config, and
	// not the literal "$XDG_CONFIG_HOME" string.
	support.check(t, "no file: resolves into the temp XDG dir",
		c.path != "" && strings.index(c.path, dir) == 0 &&
		!strings.contains(c.path, "$XDG"),
		fmt.tprintf("resolved path = {}", c.path))
	support.check(t, "…SILENT defaults (absent config is not a problem)",
		len(c.warnings) == 0 && c.theme == "gruvbox-dark" && !c.corrupt,
		fmt.tprintf("warnings={} theme='{}' corrupt={}", len(c.warnings), c.theme, c.corrupt))
	support.check(t, "…and it did NOT create a file on the way", !file_exists(c.path),
		"a read path that writes is a surprise in the user's dotfiles")
	support.check(t, "…cleanup default resolved to only_created",
		c.cleanup_policy == "only_created", c.cleanup_policy)
}

@(test)
config_live_reads_a_real_file :: proc(t: ^testing.T) {
	dir := swap_theme_cfg(t, "live-read")

	hand := `{"theme":"nord","cleanup_policy":"always","remotes":["conf-host.example"]}`
	if err := os.write_entire_file_from_string(cfg_file(dir), hand); err != nil {
		support.check(t, "fixture: config written", false, fmt.tprintf("{}", err))
		return
	}
	c := app.config_load()
	support.check(t, "a real config file loads",
		c.present && !c.corrupt && c.theme == "nord" && c.cleanup_policy == "always",
		fmt.tprintf("present={} corrupt={} theme='{}' cleanup='{}'",
			c.present, c.corrupt, c.theme, c.cleanup_policy))
	support.check(t, "…and the remote from the file is there",
		len(c.remotes) == 1 && c.remotes[0].device == "conf-host.example", remote_join(c.remotes))
	// The remote from the config is a user-owned thing. It has to reach the
	// remote picker with its label and target intact or the config is write-only.
	support.check(t, "…remote_is_valid accepts a config-declared host",
		len(c.remotes) == 1 && app.remote_is_valid(c.remotes[0]), remote_join(c.remotes))
	support.check(t, "…no warnings for a well-formed file", len(c.warnings) == 0, warn_join(c))
	support.check(t, "…path points at the temp XDG file (not real HOME)",
		strings.index(c.path, dir) == 0 && !strings.contains(c.path, "$XDG"), c.path)
	support.check(t, "…and that path is the file we actually wrote",
		c.path == cfg_file(dir), fmt.tprintf("got {} want {}", c.path, cfg_file(dir)))
}

@(test)
config_live_corrupt_file_warns_once :: proc(t: ^testing.T) {
	dir := swap_theme_cfg(t, "live-corrupt")

	if err := os.write_entire_file_from_string(cfg_file(dir), "{ nope {{{"); err != nil {
		support.check(t, "fixture: corrupt config written", false, fmt.tprintf("{}", err))
		return
	}
	c := app.config_load()
	// Stay usable: the app must come up on defaults and say so, once.
	support.check(t, "corrupt config loads as corrupt with defaults intact",
		c.corrupt && c.theme == "gruvbox-dark" && c.cleanup_policy == "only_created",
		fmt.tprintf("corrupt={} theme='{}' cleanup='{}'", c.corrupt, c.theme, c.cleanup_policy))
	support.check(t, "…exactly ONE footer warning", len(c.warnings) == 1,
		fmt.tprintf("{} warning(s): {}", len(c.warnings), warn_join(c)))
	support.check(t, "…the warning names the file so the user can fix THAT one",
		strings.contains(c.warnings[0], "herdr_session.json"), c.warnings[0])
}

@(test)
config_live_unknown_theme_surfaces_in_the_footer :: proc(t: ^testing.T) {
	dir := swap_theme_cfg(t, "live-unknown")

	if err := os.write_entire_file_from_string(cfg_file(dir), `{"theme":"bogger"}`); err != nil {
		support.check(t, "fixture: bad-theme config written", false, fmt.tprintf("{}", err))
		return
	}
	c := app.config_load()
	support.check(t, "unknown theme falls back AND is visible",
		c.theme == "gruvbox-dark" && c.theme_fell_back && len(c.warnings) == 1,
		fmt.tprintf("theme='{}' fell_back={} warnings={}",
			c.theme, c.theme_fell_back, len(c.warnings)))
	support.check(t, "…config_warning_text is non-empty (this is what the footer shows)",
		app.config_warning_text(c) != "", app.config_warning_text(c))
}

@(test)
config_live_unreadable_file_warns :: proc(t: ^testing.T) {
	dir := swap_theme_cfg(t, "live-unreadable")

	if err := os.write_entire_file_from_string(cfg_file(dir), "{}"); err != nil {
		support.check(t, "fixture: unreadable config written", false, fmt.tprintf("{}", err))
		return
	}
	// Mode 000: EACCES, not ENOENT. "Cannot read my config" and "I have no
	// config" are different situations to the user and must not collapse into
	// the same silent default.
	if serr := os.chmod(cfg_file(dir), os.Permissions{}); serr != nil {
		support.note(t, fmt.tprintf("chmod skipped (running as root?): {}", serr))
	}
	c := app.config_load()
	support.check(t, "unreadable config: warned (NOT silently defaulting)",
		len(c.warnings) >= 1 && (c.corrupt || !c.present),
		fmt.tprintf("present={} corrupt={} warnings={}", c.present, c.corrupt, warn_join(c)))
	// Restore the mode before the deferred delete_dir, or removal is refused.
	os.chmod(cfg_file(dir), os.Permissions_Read_All + os.Permissions_Write_All)
}

@(test)
config_live_save_round_trips_through_the_real_loader :: proc(t: ^testing.T) {
	// Closes the loop with the REAL loader: a theme picked in the UI, written by
	// the real save path, read back by the real read path, at a real path under
	// the redirect. This is as close to the end of the T9 loop as a hermetic
	// test can get; the last hop (a terminal showing it) is the deferred pty
	// tier and is NOT claimed here.
	dir := swap_theme_cfg(t, "live-save")

	s1, e1 := app.config_save_theme(cfg_file(dir), "nord")
	c1 := app.config_load()
	support.check(t, "live-save then load returns the theme",
		s1 && c1.present && c1.theme == "nord",
		fmt.tprintf("save_ok={} present={} theme='{}' err='{}'", s1, c1.present, c1.theme, e1))
	support.check(t, "…with no warnings on the round trip", len(c1.warnings) == 0, warn_join(c1))
	support.check(t, "…twice (a second save re-reads the first one's output)",
		app.config_load().theme == "nord", fmt.tprintf("theme='{}'", app.config_load().theme))

	s2, e2 := app.config_save_theme(cfg_file(dir), "catppuccin-mocha")
	c2 := app.config_load()
	support.check(t, "a second save replaces it",
		s2 && c2.theme == "catppuccin-mocha", fmt.tprintf("save_ok={} theme='{}' err='{}'",
			s2, c2.theme, e2))
	support.check(t, "…and the file is still valid afterwards",
		!c2.corrupt && len(c2.warnings) == 0, warn_join(c2))
}
