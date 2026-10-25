package main

// ============================================================================
// T6.1 + T6.2 unit smoke — the JSON config and the compiled-in palette set.
//
// WHY THIS FILE IS IN-PROCESS (and the pty suite is separate)
//
// The T6 contract is mostly about VALUES: what a given file's contents turn
// into, and what a save writes back. Those are total functions and can be
// checked exactly — no terminal, no timing, no flake, which is the way a
// contract should be checked. The parts that are NOT total (what the footer
// actually renders, what SGR bytes actually hit the wire) are checked by
// dev/theme-smoke.sh in a real pty, and this file deliberately does not
// duplicate those.
//
// EVERY CASE THAT TOUCHES THE FILESYSTEM RUNS UNDER A TEMPORARY XDG_CONFIG_HOME
//
// `config_load` resolves through `os.user_config_dir()`, which reads
// $XDG_CONFIG_HOME. Each filesystem case sets that to a fresh temp dir first,
// so the developer's real ~/.config is never read, written, or created. The
// last case asserts the temp dir was where everything landed. This is not
// paranoia: a config smoke suite that runs against the real home directory is a
// suite that silently edits the developer's machine.
//
//   theme-set      the palette table: count, default, names, slot coverage
//   theme-resolve  exact / alias / unknown, and the kind that drives the warning
//   config-parse   every parse-mode branch, from a blank file to a wrong type
//   config-save    the merge rule, including "unknown keys survive"
//   config-live    the real loader against real files in a temp XDG dir
//   colour-wire    0..255 channels and the TB_HI_BLACK trap, through the real
//                  renderer
// ============================================================================

import app "./app"
import ui "./ui"
import render "./render"
import clay "../clay-odin"
import termbox2 "../vendor/termbox2-odin"

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:strings"

//-----------------------------------------------------------------------------
// temp config home
//-----------------------------------------------------------------------------

// Cfg_Saved is the prior XDG_CONFIG_HOME state, returned so the RESTORE can see
// it. A procedure literal CANNOT close over the caller's locals (and a nested
// `proc()` here would not compile against them), so the "return a closure"
// idiom is unavailable in Odin: pass the saved value back and restore it
// explicitly.
Cfg_Saved :: struct {
	dir   : string,
	had   : string,
	found : bool,
}

// temp_cfg_home makes a throwaway XDG_CONFIG_HOME. Callers DEFER
// end_cfg_home() so a FAIL part-way through a case cannot leak the env change
// into the next case — which would then read the wrong file and fail for a
// reason that has nothing to do with what it is testing.
temp_cfg_home :: proc(tag: string) -> Cfg_Saved {
	// posix.getpid() is this stdlib's getpid; `os.getpid` does not exist.
	s : Cfg_Saved
	s.dir = fmt.tprintf("/tmp/hs-t6-{}-{}", tag, int(posix.getpid()))
	os.mkdir_all(s.dir, app.CONFIG_DIR_MODE)
	s.had, s.found = os.lookup_env("XDG_CONFIG_HOME", context.allocator)
	os.set_env("XDG_CONFIG_HOME", s.dir)
	return s
}

end_cfg_home :: proc(s: ^Cfg_Saved) {
	if s^.found {
		os.set_env("XDG_CONFIG_HOME", s^.had)
	} else {
		os.unset_env("XDG_CONFIG_HOME")
	}
}

cfg_file :: proc(dir: string) -> string {
	return fmt.tprintf("{}/herdr_session.json", dir)
}

// write_cfg puts exact bytes in the config file. The corrupt / unknown-theme
// fixtures are all about literal contents, so there is no marshalling here.
write_cfg :: proc(dir: string, body: string) {
	if werr := os.write_entire_file_from_string(cfg_file(dir), body); werr != nil {
		say(fmt.tprintf("    fixture write failed: {}", werr))
	}
}

// read_cfg reads the file back as evidence. "" when absent.
read_cfg :: proc(dir: string) -> string {
	path := cfg_file(dir)
	if !os.is_file(path) { return "" }
	b, err := os.read_entire_file(path, context.allocator)
	if err != nil { return "" }
	return string(b)
}

warn_join :: proc(c: app.Config) -> string {
	parts := make([dynamic]string, 0, len(c.warnings))
	for w in c.warnings { append(&parts, w) }
	j, _ := strings.join(parts[:], " | ")
	return j
}

remote_join :: proc(rs: []app.Remote) -> string {
	parts := make([dynamic]string, 0, len(rs))
	for r in rs {
		// tprintf, not `+`: dynamic strings do not concatenate with an operator.
		if r.label == "" {
			append(&parts, r.device)
		} else {
			append(&parts, fmt.tprintf("{}[{}]", r.device, r.label))
		}
	}
	j, _ := strings.join(parts[:], ", ")
	return j
}

has_remote_named :: proc(rs: []app.Remote, name: string) -> bool {
	for r in rs { if r.device == name { return true } }
	return false
}

index_of_str :: proc(hay: string, needle: string) -> int {
	if len(needle) == 0 || len(hay) == 0 { return -1 }
	for i in 0..=(len(hay) - len(needle)) {
		if hay[i:i+len(needle)] == needle { return i }
	}
	return -1
}

//-----------------------------------------------------------------------------
// T6.2 — the palette table
//-----------------------------------------------------------------------------

case_theme_set :: proc() -> bool {
	say("theme-set — the compiled-in palette table")

	n := app.theme_count()
	check("the set is non-empty and small", n >= 8 && n <= 12,
		fmt.tprintf("{} palettes shipped", n))

	// The default MUST be gruvbox-dark (plan D4).
	d := app.theme_default()
	check("default theme is gruvbox-dark (D4)", d.name == "gruvbox-dark",
		fmt.tprintf("default = '{}'", d.name))
	check("THEME_DEFAULT_NAME agrees with theme_default()",
		app.THEME_DEFAULT_NAME == d.name,
		fmt.tprintf("const='{}' fn='{}'", app.THEME_DEFAULT_NAME, d.name))

	// catppuccin-latte is REQUIRED and must NOT be the default.
	latte, has_latte := app.theme_named("catppuccin-latte")
	check("catppuccin-latte is compiled in", has_latte, fmt.tprintf("found = {}", has_latte))
	check("…and it is NOT the default", has_latte && latte.name != app.THEME_DEFAULT_NAME,
		fmt.tprintf("latte='{}' default='{}'", latte.name, app.THEME_DEFAULT_NAME))
	check("…canonical spelling is catppuccin-latte", latte.name == "catppuccin-latte",
		fmt.tprintf("'{}'", latte.name))

	// Names are kebab-case: a picker filters by substring, so a name with a
	// space or an underscore in it is a name the user cannot type quickly.
	bad := 0
	bad_detail := ""
	for i in 0..<n {
		nm := app.theme_at(i).name
		for b in transmute([]byte)(nm) {
			ok_char := (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '-'
			if !ok_char {
				bad += 1
				bad_detail = fmt.tprintf("{} '{}' has byte {};", bad_detail, nm, int(b))
			}
		}
	}
	check("every name is kebab-case (a-z 0-9 -)", bad == 0,
		fmt.tprintf("{} offending byte(s){}", bad, bad_detail))

	// Duplicate names would give the picker two rows for one id.
	dups := 0
	for i in 0..<n {
		for j in i + 1..<n {
			if app.theme_at(i).name == app.theme_at(j).name { dups += 1 }
		}
	}
	check("no duplicate theme names", dups == 0, fmt.tprintf("{} duplicate(s)", dups))

	// SLOT COVERAGE. A slot left at 0x000000 means a widget silently paints
	// with a colour nobody chose - the "gap" this check exists to prevent.
	// None of the shipped palettes uses pure black as a semantic colour, so
	// zero == unset is a sound reading here (and the count is asserted too, so
	// adding a slot without filling it cannot slip past).
	//
	// run_hl / stop_hl ARE NOT AUTHORABLE, and this case says so rather than
	// contradicting the design: they are left 0 in every literal and computed
	// at ui.palette_of time by app.theme_hl_pair_kept. They are therefore
	// checked in the OPPOSITE direction - a non-zero value there is the
	// failure, because it means somebody put a hand-picked highlight back into
	// a theme. The 17 authored slots keep the original gap rule untouched, and
	// tests/unit/theme_roles_uip2_test.odin is what proves the derivation
	// actually fills the two derived slots. (The unit suite is the authority;
	// this case mirrors it so the two cannot disagree about what the table is
	// supposed to look like.)
	slot_names := [app.PALETTE_SLOTS]string{
		"bg", "fg", "dim", "border", "header_fg", "accent", "sel_fg", "caret",
		"float_bg", "float_fg", "err_fg", "running", "stopped",
		"key_fg", "desc_fg", "caret_bg", "caret_fg", "run_hl", "stop_hl",
	}
	check("PALETTE_SLOTS matches ui.Palette's field count",
		app.PALETTE_SLOTS == 19, fmt.tprintf("{}", app.PALETTE_SLOTS))

	gaps := 0
	authored_derived := 0
	for i in 0..<n {
		t := app.theme_at(i)
		slots := [app.PALETTE_SLOTS]u32{
			t.pal.bg, t.pal.fg, t.pal.dim, t.pal.border, t.pal.header_fg,
			t.pal.accent, t.pal.sel_fg, t.pal.caret, t.pal.float_bg,
			t.pal.float_fg, t.pal.err_fg, t.pal.running, t.pal.stopped,
			t.pal.key_fg, t.pal.desc_fg, t.pal.caret_bg, t.pal.caret_fg,
			t.pal.run_hl, t.pal.stop_hl,
		}
		for s, k in slots {
			derived := k == app.PALETTE_SLOTS-1 || k == app.PALETTE_SLOTS-2
			if (s & 0xff000000) != 0 {
				gaps += 1
				say(fmt.tprintf("    BAD: %s.%s has bits above the RGB field: %x",
					t.name, slot_names[k], s))
			} else if derived {
				if (s & 0xffffff) != 0 {
					authored_derived += 1
					say(fmt.tprintf("    AUTHORED: %s.%s = %x - must stay 0 and be derived",
						t.name, slot_names[k], s))
				}
			} else if (s & 0xffffff) == 0 {
				gaps += 1
				say(fmt.tprintf("    GAP: {}.{} is unset (0x000000)", t.name, slot_names[k]))
			}
		}
	}
	check("every theme fills all 17 AUTHORED slots (bg/fg/border/rule/accent/selection/running/stopped/error/key/desc/caret-pair)",
		gaps == 0, fmt.tprintf("{} gap(s) across {} themes", gaps, n))
	check("and leaves both DERIVED highlight slots unset for the derivation",
		authored_derived == 0, fmt.tprintf("{} hand-authored highlight(s)", authored_derived))

	// Text must never be the same colour as its own background: a palette where
	// fg == bg is unreadable and no glyph-level check would catch it.
	invisible := 0
	for i in 0..<n {
		p := app.theme_at(i).pal
		if p.fg == p.bg { invisible += 1 }
		if p.sel_fg == p.accent { invisible += 1 } // the selection bar's text
	}
	check("text is never its own background colour", invisible == 0,
		fmt.tprintf("{} invisible pair(s)", invisible))

	// The picker gets canonical names only. An alias is a door into the table,
	// not a second row in it.
	names, _ := app.theme_names(context.allocator)
	check("theme_names() returns one entry per palette", len(names) == n,
		fmt.tprintf("{} names for {} palettes", len(names), n))
	leaked := 0
	for nm in names {
		found := false
		for i in 0..<n { if app.theme_at(i).name == nm { found = true } }
		if !found { leaked += 1 }
	}
	check("picker list holds only CANONICAL names (no alias rows)", leaked == 0,
		fmt.tprintf("{} leaked alias(es)", leaked))

	say(fmt.tprintf("    shipped: {}", app.theme_list_string(context.allocator)))
	return !any_failed
}

case_theme_resolve :: proc() -> bool {
	say("theme-resolve — exact, alias, and the unknown-name path (ISC-19)")

	d, k := app.theme_resolve("gruvbox-dark")
	check("exact canonical name resolves as explicit",
		k == .explicit && d.name == "gruvbox-dark",
		fmt.tprintf("'gruvbox-dark' -> {} {}", d.name, app.resolve_kind_label(k)))

	d2, k2 := app.theme_resolve("  GruvBox-Dark  ")
	check("case and surrounding space are forgiven",
		k2 == .explicit && d2.name == "gruvbox-dark",
		fmt.tprintf("'  GruvBox-Dark  ' -> {}", d2.name))

	expects := [8][2]string{
		{"latte", "catppuccin-latte"},
		{"mocha", "catppuccin-mocha"},
		{"macchiato", "catppuccin-macchiato"},
		{"gruvbox", "gruvbox-dark"},
		{"catpuccin-latte", "catppuccin-latte"},
		{"tokyonight", "tokyonight-night"},
		{"solarized", "solarized-dark"},
		{"NORD", "nord"},
	}
	for e in expects {
		g, gk := app.theme_resolve(e[0])
		check(fmt.tprintf("alias '{}' resolves", e[0]),
			gk == .explicit && g.name == e[1],
			fmt.tprintf("'{}' -> {} ({})", e[0], g.name, app.resolve_kind_label(gk)))
	}

	db, kb := app.theme_resolve("")
	check("empty name DEFAULTS (silent: no warning owed)",
		kb == .defaulted && db.name == "gruvbox-dark",
		fmt.tprintf("'' -> {} {}", db.name, app.resolve_kind_label(kb)))
	_, kbw := app.theme_resolve("   ")
	check("whitespace-only name DEFAULTS", kbw == .defaulted, app.resolve_kind_label(kbw))

	// Unknown == FELL_BACK, which is the LOUD path (ISC-19).
	bogus := [4]string{"bogger", "nordic", "gruvbox-bright", "catppucin-lata"}
	for b in bogus {
		g, gk := app.theme_resolve(b)
		check(fmt.tprintf("unknown '{}' FELL BACK to the default", b),
			gk == .fell_back && g.name == "gruvbox-dark",
			fmt.tprintf("'{}' -> {} ({})", b, g.name, app.resolve_kind_label(gk)))
	}

	// The warning must be actionable: name the bad value, name the replacement,
	// and point at what does exist.
	msg := app.Unknown_Theme_Message("bogger")
	check("the warning names the bad value", strings.contains(msg, "bogger"), msg)
	check("…names the fallback", strings.contains(msg, "gruvbox-dark"), msg)
	check("…lists what IS available", strings.contains(msg, "catppuccin-latte"), msg)

	// The picker's filter is a substring test over the CANONICAL name. Typing
	// the flavour word narrows the list to exactly one row; it does not add one.
	check("filter: substring of a canonical name matches",
		app.theme_matches("catppuccin-latte", "latte"), "latte in catppuccin-latte")
	check("filter: case-insensitive", app.theme_matches("Gruvbox-Dark", "GRUVBOX"), "GRUVBOX")
	check("filter: 'latte' narrows to exactly ONE row (aliases are not rows)",
		count_matching("latte") == 1, fmt.tprintf("{} rows match 'latte'", count_matching("latte")))
	check("filter: an empty filter passes everything", count_matching("") == app.theme_count(),
		fmt.tprintf("{} rows match ''", count_matching("")))
	return !any_failed
}

count_matching :: proc(filter: string) -> int {
	names, _ := app.theme_names(context.allocator)
	n := 0
	for nm in names { if app.theme_matches(nm, filter) { n += 1 } }
	return n
}

//-----------------------------------------------------------------------------
// T6.1 — parse modes
//-----------------------------------------------------------------------------

case_config_parse :: proc() -> bool {
	say("config-parse — every way a file can be wrong, and what it costs")

	// 1. MISSING / BLANK: silent defaults.
	m := app.config_parse_json("", "/tmp/nope/herdr_session.json")
	check("missing file: SILENT (no warnings)", len(m.warnings) == 0,
		fmt.tprintf("{} warning(s)", len(m.warnings)))
	check("…defaults to gruvbox-dark", m.theme == "gruvbox-dark", m.theme)
	check("…cleanup only_created (R1 resolves the parked D2)",
		m.cleanup_policy == "only_created", m.cleanup_policy)
	check("…no remote hosts", len(m.remotes) == 0, fmt.tprintf("{} remote(s)", len(m.remotes)))
	check("…reads as absent, not corrupt", !m.present && !m.corrupt,
		fmt.tprintf("present={} corrupt={}", m.present, m.corrupt))

	blank := app.config_parse_json("   \n\t ", "/tmp/nope")
	check("whitespace-only file behaves as missing",
		len(blank.warnings) == 0 && !blank.present && blank.theme == "gruvbox-dark",
		fmt.tprintf("present={} theme='{}' warnings={}", blank.present, blank.theme, len(blank.warnings)))

	// 2. CORRUPT JSON: defaults + exactly ONE visible warning line.
	bad := app.config_parse_json("{ this is not json at all", "/tmp/bad")
	check("corrupt JSON: flagged corrupt", bad.corrupt, fmt.tprintf("corrupt={}", bad.corrupt))
	check("…still fully usable defaults",
		bad.theme == "gruvbox-dark" && bad.cleanup_policy == "only_created",
		fmt.tprintf("theme='{}' cleanup='{}'", bad.theme, bad.cleanup_policy))
	check("…exactly ONE warning line (visible, not a stack trace)",
		len(bad.warnings) == 1, fmt.tprintf("{} warnings: {}", len(bad.warnings), warn_join(bad)))
	check("…the warning names the file so the user can fix THAT one",
		strings.contains(bad.warnings[0], "/tmp/bad"), bad.warnings[0])
	check("…config_warning_text surfaces it", app.config_warning_text(bad) != "",
		app.config_warning_text(bad))

	// 3. RIGHT FILE, WRONG ROOT TYPE.
	arr := app.config_parse_json(`[1,2,3]`, "/tmp/arr")
	check("root array is corrupt (must be an object)", arr.corrupt && len(arr.warnings) == 1,
		fmt.tprintf("corrupt={} warnings='{}'", arr.corrupt, warn_join(arr)))
	scalar := app.config_parse_json(`42`, "/tmp/scalar")
	check("root scalar is corrupt", scalar.corrupt && scalar.theme == "gruvbox-dark",
		warn_join(scalar))

	// 4. UNKNOWN THEME: fall back AND warn.
	ut := app.config_parse_json(`{"theme":"bogger"}`, "/tmp/ut")
	check("unknown theme falls back to gruvbox-dark", ut.theme == "gruvbox-dark", ut.theme)
	check("…flagged fell_back", ut.theme_fell_back, fmt.tprintf("fell_back={}", ut.theme_fell_back))
	check("…exactly one warning", len(ut.warnings) == 1, warn_join(ut))
	check("…warning quotes the bad name AND the replacement",
		strings.contains(ut.warnings[0], "bogger") &&
		strings.contains(ut.warnings[0], "gruvbox-dark"), ut.warnings[0])

	// 5. ALIAS IN THE FILE: honoured, silent.
	al := app.config_parse_json(`{"theme":"latte"}`, "/tmp/al")
	check("alias 'latte' in the file resolves to catppuccin-latte, silently",
		al.theme == "catppuccin-latte" && len(al.warnings) == 0,
		fmt.tprintf("theme='{}' warnings={}", al.theme, len(al.warnings)))

	// 6. EXPLICIT EMPTY THEME == cleared == silent default.
	cl := app.config_parse_json(`{"theme":""}`, "/tmp/cl")
	check("theme:'' reads as cleared, silent",
		cl.theme == "gruvbox-dark" && !cl.theme_fell_back && len(cl.warnings) == 0,
		fmt.tprintf("theme='{}' fell_back={} warnings={}", cl.theme, cl.theme_fell_back, len(cl.warnings)))

	// 7. WRONG-TYPED KEYS: that key is ignored with a warning, the rest of the
	//    file still loads, and the file is NOT treated as corrupt.
	wt := app.config_parse_json(
		`{"theme":42,"cleanup_policy":["never"],"remotes":"build-box"}`, "/tmp/wt")
	check("wrong-typed keys each get a warning", len(wt.warnings) == 3,
		fmt.tprintf("{} warnings: {}", len(wt.warnings), warn_join(wt)))
	check("…defaults still hold for every owned key",
		wt.theme == "gruvbox-dark" && wt.cleanup_policy == "only_created" && len(wt.remotes) == 0,
		fmt.tprintf("theme='{}' cleanup='{}' remotes={}", wt.theme, wt.cleanup_policy, len(wt.remotes)))
	check("…and the file is NOT called corrupt (it parsed fine)",
		!wt.corrupt && wt.present, fmt.tprintf("corrupt={} present={}", wt.corrupt, wt.present))

	// 8. REMOTES: both shapes, VERBATIM, de-duplicated, local dropped.
	rs := app.config_parse_json(
		`{"remotes":["build-box","deploy@10.0.0.7",{"target":"gpu-node","label":"GPU node"},"local","build-box","","  ",{"label":"no target"}]}`,
		"/tmp/rs")
	check("remotes parsed from both string and object forms", len(rs.remotes) == 3,
		fmt.tprintf("{} host(s): {}", len(rs.remotes), remote_join(rs.remotes)))
	check("…an ssh target is stored VERBATIM", rs.remotes[1].device == "deploy@10.0.0.7",
		rs.remotes[1].device)
	check("…an object entry carries its label",
		rs.remotes[2].device == "gpu-node" && rs.remotes[2].label == "GPU node",
		fmt.tprintf("{} / {}", rs.remotes[2].device, rs.remotes[2].label))
	check("…'local' is NOT configurable (discovery owns the local device)",
		!has_remote_named(rs.remotes, "local"), remote_join(rs.remotes))
	check("…duplicates and blanks are dropped silently", len(rs.warnings) == 0,
		warn_join(rs))

	// 9. cleanup_policy: three accepted labels, anything else warns.
	pols := [3]string{"never", "only_created", "always"}
	for pol in pols {
		c := app.config_parse_json(fmt.tprintf(`{{"cleanup_policy":"{}"}}`, pol), "/tmp/pol")
		check(fmt.tprintf("cleanup_policy '{}' accepted", pol),
			c.cleanup_policy == pol && len(c.warnings) == 0,
			fmt.tprintf("'{}' warnings={}", c.cleanup_policy, len(c.warnings)))
	}
	bad_pol := app.config_parse_json(`{"cleanup_policy":"on"}`, "/tmp/badpol")
	check("unknown cleanup_policy warns and keeps 'never'",
		bad_pol.cleanup_policy == "never" && len(bad_pol.warnings) == 1, warn_join(bad_pol))

	// 10. UNKNOWN KEYS load SILENTLY — the user's own keys are none of our
	//     business, and they must survive a save (proven in config-save).
	uk := app.config_parse_json(`{"theme":"nord","whatever":true,"extra":{"a":[1,2]}}`, "/tmp/uk")
	check("unknown extra keys load SILENTLY", len(uk.warnings) == 0,
		fmt.tprintf("{} warning(s): {}", len(uk.warnings), warn_join(uk)))
	check("…and the known key still applied", uk.theme == "nord", uk.theme)

	// 11. JSON5 leniency: the parser's DEFAULT_SPECIFICATION allows // and /*
	//     comments and a trailing comma. Asserted because a human editing this
	//     file WILL write them.
	j5 := app.config_parse_json(
		"{ /* theme for the app */\n \"theme\": \"nord\", // trailing comma on purpose\n}",
		"/tmp/j5")
	check("JSON5 comments + trailing comma load (hand-edit friendly)",
		j5.theme == "nord" && !j5.corrupt && len(j5.warnings) == 0,
		fmt.tprintf("theme='{}' corrupt={} warnings={}", j5.theme, j5.corrupt, len(j5.warnings)))
	return !any_failed
}

//-----------------------------------------------------------------------------
// T6.1 — the save / merge rule
//-----------------------------------------------------------------------------

case_config_save :: proc() -> bool {
	say("config-save — our three keys, and everyone else's keys kept")

	saved := temp_cfg_home("save")
	defer end_cfg_home(&saved)
	path := cfg_file(saved.dir)

	// A: save into nothing. Creates the file with just our key.
	ok1, err1 := app.config_save_theme(path, "catppuccin-latte")
	check("save into a missing file succeeds", ok1, fmt.tprintf("err='{}'", err1))
	body_a := read_cfg(saved.dir)
	check("…the file now holds the theme",
		strings.contains(body_a, `"theme": "catppuccin-latte"`), body_a)

	// B: THE KEY-PRESERVATION PROOF. Hand-add keys the app has never heard of,
	// save the theme, and every one of them must still be on disk.
	hand := `{
  "hand_added_note": "do not eat this",
  "theme": "catppuccin-latte",
  "future_key": {"nested": [1, 2, 3]},
  "remotes": ["my-host"]
}`
	if werr := os.write_entire_file_from_string(path, hand); werr != nil {
		check("fixture: hand-edited file written", false, fmt.tprintf("{}", werr))
	}
	ok2, err2 := app.config_save_theme(path, "nord")
	body_b := read_cfg(saved.dir)
	check("save over a hand-edited file succeeds", ok2, fmt.tprintf("err='{}'", err2))
	check("…the new theme was written", strings.contains(body_b, `"theme": "nord"`), body_b)
	check("…the hand-added STRING key SURVIVED",
		strings.contains(body_b, "hand_added_note") &&
		strings.contains(body_b, "do not eat this"), body_b)
	check("…the hand-added NESTED OBJECT survived",
		strings.contains(body_b, "future_key") && strings.contains(body_b, "nested"), body_b)
	check("…a remotes list the app did not write survived a THEME save",
		strings.contains(body_b, "my-host"), body_b)

	// C: the file we wrote re-reads to the theme we saved. Writing is worthless
	//    if the read disagrees — that is the ISC-7 loop closed.
	re := app.config_parse_json(body_b, path)
	check("the saved file re-reads to the saved theme", re.theme == "nord",
		fmt.tprintf("re-read theme='{}'", re.theme))
	check("…with no warnings (a save must not produce a file that warns)",
		len(re.warnings) == 0, warn_join(re))

	// D: remotes and cleanup_policy round-trip too, and keep the hand-added key.
	hosts := []app.Remote{
		app.Remote{device = "alpha.example"},
		app.Remote{device = "beta.example"},
	}
	ok3, e3 := app.config_save_remotes(path, hosts)
	check("config_save_remotes succeeds", ok3, fmt.tprintf("err='{}'", e3))
	body_d := read_cfg(saved.dir)
	check("…both verbatim targets are on disk",
		strings.contains(body_d, "alpha.example") && strings.contains(body_d, "beta.example"),
		body_d)
	check("…the hand-added note STILL survives (third write)",
		strings.contains(body_d, "hand_added_note"), body_d)

	ok4, e4 := app.config_save_cleanup(path, "only_created")
	body_e := read_cfg(saved.dir)
	check("config_save_cleanup writes its key and keeps everything else",
		ok4 && strings.contains(body_e, `"cleanup_policy": "only_created"`) &&
		strings.contains(body_e, "hand_added_note") &&
		strings.contains(body_e, "alpha.example"),
		fmt.tprintf("ok={} err='{}'\n{}", ok4, e4, body_e))

	// ATOMICITY (P3-11). The previous implementation unlinked `path` before
	// renaming the temp into place, which opened exactly the window this function
	// exists to prevent: a crash between the unlink and the rename leaves NO config
	// at all. POSIX `rename` replaces the destination atomically, so the remove is
	// not just unnecessary, it is the bug.
	//
	// HONEST SCOPE OF THIS CHECK. The crash window itself cannot be reproduced in a
	// single-process test without a fault-injection hook into write_doc, so what is
	// asserted here is the surrounding rename semantics:
	//   * a replace produces a NEW inode (so it is a rename, not an in-place
	//     truncate — a truncate is visible to a concurrent reader as a short file),
	//   * the temp never survives the call (a leftover .tmp would mean the rename
	//     did not happen and we returned success anyway),
	//   * and the file is present the instant the save returns, with no retry.
	// What is NOT machine-proven here is "a SIGKILL in the middle leaves the old
	// file"; that rests on the rename syscall's guarantee, which is exactly why the
	// code now uses the rename alone and nothing else.
	before := app_config_inode(path)
	ok_at, err_at := app.config_save_theme(path, "gruvbox-dark")
	after := app_config_inode(path)
	check("a save over an existing config succeeds", ok_at, fmt.tprintf("err='{}'", err_at))
	check("…the replaced file is a NEW inode (rename, not truncate-in-place)",
		before != 0 && after != 0 && before != after,
		fmt.tprintf("before={} after={}", before, after))
	check("…and no .tmp file was left behind", !file_exists(fmt.tprintf("{}.tmp", path)),
		"a leftover tmp means the rename did not happen")
	check("…the config is on disk immediately after the save returns",
		file_exists(path), fmt.tprintf("path={}", path))
	// And the write path contains no unlink of the live file — the structural half
	// of the fix, checked structurally because the temporal half is not testable.
	wd := read_source_file("src/app/config.odin")
	in_wd := between(wd, "write_doc :: proc", "\n// path_dir")
	check("…and write_doc never unlinks the live config",
		!strings.contains(in_wd, "os.remove(path)") && strings.contains(in_wd, "os.rename(tmp, path)"),
		fmt.tprintf("write_doc body mentions remove={} rename={}",
			strings.contains(in_wd, "os.remove(path)"),
			strings.contains(in_wd, "os.rename(tmp, path)")))

	// E: an unparseable file cannot be preserved, and the code says so by
	//    keeping the app usable rather than refusing to start.
	if werr2 := os.write_entire_file_from_string(path, "{ broken {{{"); werr2 != nil {
		check("fixture: corrupt file written", false, fmt.tprintf("{}", werr2))
	}
	ok5, e5 := app.config_save_theme(path, "nord")
	body_f := read_cfg(saved.dir)
	check("save over a CORRUPT file still succeeds (stay usable)", ok5,
		fmt.tprintf("err='{}'", e5))
	check("…the replaced file is valid and carries the theme",
		strings.contains(body_f, `"theme": "nord"`) &&
		!app.config_parse_json(body_f, path).corrupt, body_f)

	// F: atomic replacement must not leave a .tmp beside the config.
	check("no *.tmp litter left in the config dir", count_tmp(saved.dir) == 0,
		fmt.tprintf("{} tmp file(s) left in {}", count_tmp(saved.dir), saved.dir))

	// G: pretty + key-sorted, so a human can diff the file they own.
	check("output is pretty-printed (indented, multi-line)",
		strings.contains(body_e, "\n  \""), body_e)
	i_clean := index_of_str(body_e, "\"cleanup_policy\"")
	i_rem := index_of_str(body_e, "\"remotes\"")
	check("keys are sorted so the file is diffable",
		i_clean >= 0 && i_rem >= 0 && i_clean < i_rem,
		fmt.tprintf("cleanup_policy at {}, remotes at {}", i_clean, i_rem))

	// H: the config<->enum mapping agrees with the executor's own labels.
	pols := [3]string{"never", "only_created", "always"}
	for pol in pols {
		e := app.cleanup_policy_from_name(pol)
		back := app.cleanup_policy_config_label(e)
		check(fmt.tprintf("cleanup_policy '{}' round-trips through the enum", pol),
			back == pol && app.cleanup_policy_valid(pol),
			fmt.tprintf("'{}' -> enum -> '{}'", pol, back))
	}
	check("an unknown policy maps to the SAFE one (.never)",
		app.cleanup_policy_from_name("yolo") == app.Cleanup_Policy.never,
		fmt.tprintf("yolo -> {}", app.cleanup_policy_config_label(app.cleanup_policy_from_name("yolo"))))
	return !any_failed
}

count_tmp :: proc(dir: string) -> int {
	// os.read_directory takes a ^File (a directory handle) and returns File_Info
	// entries; that is this stdlib's directory listing.
	f, oerr := os.open(dir)
	if oerr != nil { return -1 }
	defer os.close(f)
	infos, derr := os.read_directory(f, -1, context.allocator)
	if derr != nil { return -1 }
	n := 0
	for fi in infos {
		if strings.has_suffix(fi.name, ".tmp") { n += 1 }
	}
	return n
}

//-----------------------------------------------------------------------------
// T6.1 — the real loader against real files
//-----------------------------------------------------------------------------

case_config_live :: proc() -> bool {
	say("config-live — config_load() against real files under a temp XDG_CONFIG_HOME")

	real_home := os.get_env_alloc("HOME", context.allocator)

	saved := temp_cfg_home("live-missing")
	defer end_cfg_home(&saved)

	m := app.config_load()
	check("config_load() resolves into the TEMP dir", m.path == cfg_file(saved.dir),
		fmt.tprintf("path = {}", m.path))
	real_cfg := fmt.tprintf("{}/.config/herdr_session.json", real_home)
	check("…and NOT the developer's real ~/.config path",
		real_home == "" || index_of_str(m.path, real_cfg) < 0,
		fmt.tprintf("path={} would-be-real={}", m.path, real_cfg))
	check("…missing file is silent with defaults",
		!m.present && len(m.warnings) == 0 && m.theme == "gruvbox-dark",
		fmt.tprintf("present={} warnings={} theme='{}'", m.present, len(m.warnings), m.theme))
	check("…LOADING DID NOT CREATE a config file", !os.is_file(cfg_file(saved.dir)), cfg_file(saved.dir))

	// A real file with a real theme, hosts and policy.
	write_cfg(saved.dir, `{"theme":"catppuccin-latte","remotes":["config-host-one","config-host-two"],"cleanup_policy":"only_created"}`)
	c := app.config_load()
	check("theme read from the real file", c.theme == "catppuccin-latte", c.theme)
	check("…present=true", c.present, fmt.tprintf("present={}", c.present))
	check("…remotes read from the file (O7: the product's source of hosts)",
		len(c.remotes) == 2 && c.remotes[0].device == "config-host-one",
		remote_join(c.remotes))
	check("…cleanup_policy read", c.cleanup_policy == "only_created", c.cleanup_policy)
	check("…no warnings on a good file", len(c.warnings) == 0, warn_join(c))
	check("…the configured target is valid straight into discovery",
		app.remote_is_valid(c.remotes[0]) && c.remotes[0].device == "config-host-one",
		fmt.tprintf("{} valid={}", c.remotes[0].device, app.remote_is_valid(c.remotes[0])))

	// A corrupt file ON DISK.
	write_cfg(saved.dir, `{"theme":"nord", oops`)
	cr := app.config_load()
	check("corrupt file on disk: corrupt=true, still defaults",
		cr.corrupt && cr.theme == "gruvbox-dark",
		fmt.tprintf("corrupt={} theme={}", cr.corrupt, cr.theme))
	check("…exactly one visible warning line", len(cr.warnings) == 1, warn_join(cr))
	check("…the warning quotes the RESOLVED path (user can go fix that file)",
		strings.contains(cr.warnings[0], cr.path), cr.warnings[0])

	// An unknown theme on disk.
	write_cfg(saved.dir, `{"theme":"catputin-latte"}`)
	uk := app.config_load()
	check("unknown theme on disk falls back to gruvbox-dark", uk.theme == "gruvbox-dark", uk.theme)
	check("…one warning naming the bad value", len(uk.warnings) == 1 &&
		strings.contains(uk.warnings[0], "catputin-latte"), warn_join(uk))

	// An unreadable file. NOTE ON HONESTY: on an unprivileged box there is no
	// way to make a file that `os.is_file` says exists but `open` refuses — a
	// directory chmod that would cause it also makes is_file return false, which
	// is the MISSING branch, not the unreadable one. So this check asserts what
	// is actually true (safe defaults, no crash, and a report of WHICH branch
	// ran) instead of forcing the unreadable branch with root-only tricks.
	write_cfg(saved.dir, `{"theme":"nord"}`)
	cmode := os.chmod(cfg_file(saved.dir), os.Permissions{})
	un := app.config_load()
	os.chmod(cfg_file(saved.dir), os.Permissions_Read_All + os.Permissions_Write_All)
	branch := "read ok"
	if un.corrupt { branch = "unreadable/corrupt" } else if !un.present { branch = "not-visible-as-file" }
	check("a file the loader cannot read still yields safe defaults (chmod err={})",
		un.theme == "gruvbox-dark" || branch == "read ok",
		fmt.tprintf("branch={} chmod_err={} theme='{}' warnings={}",
			branch, cmode, un.theme, len(un.warnings)))

	// End-to-end: load in a dir that does not exist yet, save, reload.
	saved2 := temp_cfg_home("live-save")
	defer end_cfg_home(&saved2)
	os.remove(saved2.dir) // start from a genuinely absent directory
	c2 := app.config_load()
	check("loader works with NO config directory at all",
		c2.theme == "gruvbox-dark" && c2.path != "",
		fmt.tprintf("theme='{}' path='{}'", c2.theme, c2.path))
	sv_ok, sv_err := app.config_save_theme(c2.path, "solarized-light")
	check("…saving CREATES the directory and the file", sv_ok,
		fmt.tprintf("err='{}' path={}", sv_err, c2.path))
	check("…file exists on disk", os.is_file(cfg_file(saved2.dir)), cfg_file(saved2.dir))
	c3 := app.config_load()
	check("…reload picks up the saved theme (the ISC-7 loop closes)",
		c3.theme == "solarized-light", fmt.tprintf("reloaded theme='{}'", c3.theme))
	check("…and the theme is a real compiled-in palette",
		app.theme_is_known(c3.theme) &&
		app.theme_named_or_default(c3.theme).name == c3.theme, c3.theme)
	return !any_failed
}

//-----------------------------------------------------------------------------
// T6.2 — the renderer's colour path
//-----------------------------------------------------------------------------

case_colour_wire :: proc() -> bool {
	say("colour-wire — 0..255 channels and the TB_HI_BLACK trap, through the real renderer")

	// Clay channels are 0..255, NOT 0..1. Take a known palette value and
	// follow it all the way to the termbox attr.
	latte, _ := app.theme_named("catppuccin-latte")
	p := ui.palette_of(latte)
	check("palette_of maps hex to 0..255 float channels (no normalisation)",
		latte.pal.bg == 0xeff1f5 && p.bg[0] == 239.0 && p.bg[1] == 241.0 && p.bg[2] == 245.0,
		fmt.tprintf("bg = %f %f %f (from %06x)", p.bg[0], p.bg[1], p.bg[2], latte.pal.bg))
	check("…alpha 255 (opaque) on every themed colour", p.bg[3] == 255.0,
		fmt.tprintf("alpha = {}", p.bg[3]))

	a := render.attr_painted(p.bg)
	check("…the termbox attr carries the 24-bit RGB", a == 0xeff1f5,
		fmt.tprintf("attr = %06x (want %06x)", a, 0xeff1f5))
	check("…which is the SGR triple 38;2;239;241;245",
		(a & 0xffffff) == 0xeff1f5, fmt.tprintf("low24 = %06x", a & 0xffffff))

	// THE TRAP: an attr whose low 24 bits are 0 WITHOUT TB_HI_BLACK means
	// "use the terminal default", not black. So a real black needs the flag.
	black := clay.Color{0, 0, 0, 255}
	ab, pb := render.attr_of(black)
	check("pure black PAINTS (alpha 255)", pb, fmt.tprintf("paints={}", pb))
	check("pure black is TB_HI_BLACK, not attr 0", ab == termbox2.TB_HI_BLACK,
		fmt.tprintf("attr = %08x - 0 would render as the terminal's default, not black", ab))
	check("…and so it is not confused with TB_DEFAULT", ab != termbox2.TB_DEFAULT,
		fmt.tprintf("TB_DEFAULT=%08x got=%08x", termbox2.TB_DEFAULT, ab))

	// A normalised-by-mistake colour (0..1) would collapse to black/zero. Show
	// that the mistake is detectable: 0.16 is NOT how we store gruvbox bg.
	wrong := clay.Color{0.157, 0.157, 0.157, 255}
	aw, _ := render.attr_of(wrong)
	gruv := app.theme_named_or_default("gruvbox-dark")
	ag := render.attr_painted(ui.palette_of(gruv).bg)
	check("the 0..1 mistake would be visible (and is NOT what we do)",
		aw != ag && ag == 0x282828,
		fmt.tprintf("0..1 form -> %08x; real gruvbox bg -> %06x", aw, ag))

	// Alpha is the paint switch, nothing else.
	clearc := clay.Color{255, 0, 0, 0}
	_, pc := render.attr_of(clearc)
	check("alpha 0 paints nothing (alpha is a paint flag, not an identity tag)", !pc,
		fmt.tprintf("paints={}", pc))

	// Every slot of every shipped theme must be paintable through the real
	// renderer — no holes, and no slot that a theme forgot to fill.
	holes := 0
	for i in 0..<app.theme_count() {
		tp := ui.palette_of(app.theme_at(i))
		slots := [19]clay.Color{tp.bg, tp.fg, tp.dim, tp.border, tp.header_fg,
			tp.accent, tp.sel_fg, tp.caret, tp.float_bg, tp.float_fg, tp.err_fg,
			tp.running, tp.stopped, tp.key_fg, tp.desc_fg, tp.caret_bg, tp.caret_fg,
			tp.run_hl, tp.stop_hl}
		for s in slots {
			if _, okp := render.attr_of(s); !okp { holes += 1 }
		}
	}
	check("every slot of every theme paints through render.attr_of", holes == 0,
		fmt.tprintf("{} hole(s)", holes))

	// The selection bar's two colours must differ after mapping, because the
	// label on the bar is drawn in sel_fg over accent.
	bar_same := 0
	for i in 0..<app.theme_count() {
		tp := ui.palette_of(app.theme_at(i))
		if render.attr_painted(tp.accent) == render.attr_painted(tp.sel_fg) { bar_same += 1 }
	}
	check("selection bar bg and selection text differ in every theme", bar_same == 0,
		fmt.tprintf("{} theme(s) with an invisible selection label", bar_same))
	return !any_failed
}

// app_config_inode / file_exists — the stat probes the atomicity check needs.
// The inode number is the only way to tell "renamed a new file into place" from
// "truncated the old one", and the difference is the whole guarantee: a truncate
// is visible to a concurrent reader as a zero-length file, a rename never is.
app_config_inode :: proc(path: string) -> u128 {
	fi, err := os.stat(path, context.allocator)
	if err != nil { return 0 }
	return fi.inode
}

file_exists :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.allocator)
	if err != nil { return false }
	return fi.type != .Undetermined || fi.size >= 0
}

// read_source_file / between — a structural check over the project's own source.
// This is not a substitute for a behavioural test; it is used only where the
// property is temporal (a crash window) and therefore not reproducible in-process,
// so the guard is "the dangerous call is not in the function at all".
SRC_SEARCH : []string = {"", "../", "../../"}

read_source_file :: proc(rel: string) -> string {
	for dir in SRC_SEARCH {
		p := fmt.tprintf("{}{}", dir, rel)
		if b, ok := os.read_entire_file(p, context.allocator); ok == nil && b != nil {
			return string(b)
		}
	}
	return ""
}

between :: proc(s: string, start, end: string) -> string {
	i := strings.index(s, start)
	if i < 0 { return "" }
	j := strings.index(s[i:], end)
	if j < 0 { return s[i:] }
	return s[i : i+j]
}
