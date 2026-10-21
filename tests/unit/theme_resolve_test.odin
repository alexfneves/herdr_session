package unit

// ─────────────────────────────────────────────────────────────────────────────
// theme_resolve_test.odin — exact, alias, and the unknown-name path (ISC-19).
//
// Ported 1:1 from the `theme-resolve` case: 23 counted assertions.
// The property worth defending here is not "does nord resolve" — it is that
// a WRONG name is loud. A silent fallback would render a theme the user never
// asked for and never learn about.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

count_matching :: proc(filter: string) -> int {
	names, _ := app.theme_names(context.allocator)
	n := 0
	for nm in names {
		if app.theme_matches(nm, filter) { n += 1 }
	}
	return n
}

@(test)
theme_resolve_exact_canonical :: proc(t: ^testing.T) {
	d, k := app.theme_resolve("gruvbox-dark")
	support.check(t, "exact canonical name resolves as explicit",
		k == .explicit && d.name == "gruvbox-dark",
		fmt.tprintf("'gruvbox-dark' -> {} {}", d.name, app.resolve_kind_label(k)))
}

@(test)
theme_resolve_case_and_space_forgiven :: proc(t: ^testing.T) {
	d2, k2 := app.theme_resolve("  GruvBox-Dark  ")
	support.check(t, "case and surrounding space are forgiven",
		k2 == .explicit && d2.name == "gruvbox-dark",
		fmt.tprintf("'  GruvBox-Dark  ' -> {}", d2.name))
}

@(test)
theme_resolve_every_alias_resolves :: proc(t: ^testing.T) {
	// Each alias is a spelling a human actually types. A miss here is a user
	// silently landing on the default instead of the theme they named.
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
		support.check(t, fmt.tprintf("alias '{}' resolves", e[0]),
			gk == .explicit && g.name == e[1],
			fmt.tprintf("'{}' -> {} ({})", e[0], g.name, app.resolve_kind_label(gk)))
	}
}

@(test)
theme_resolve_empty_defaults_silently :: proc(t: ^testing.T) {
	db, kb := app.theme_resolve("")
	support.check(t, "empty name DEFAULTS (silent: no warning owed)",
		kb == .defaulted && db.name == "gruvbox-dark",
		fmt.tprintf("'' -> {} {}", db.name, app.resolve_kind_label(kb)))
	_, kbw := app.theme_resolve("   ")
	support.check(t, "whitespace-only name DEFAULTS", kbw == .defaulted,
		app.resolve_kind_label(kbw))
}

@(test)
theme_resolve_unknown_falls_back_loudly :: proc(t: ^testing.T) {
	// Unknown == FELL_BACK, which is the LOUD path (ISC-19).
	bogus := [4]string{"bogger", "nordic", "gruvbox-bright", "catppucin-lata"}
	for b in bogus {
		g, gk := app.theme_resolve(b)
		support.check(t, fmt.tprintf("unknown '{}' FELL BACK to the default", b),
			gk == .fell_back && g.name == "gruvbox-dark",
			fmt.tprintf("'{}' -> {} ({})", b, g.name, app.resolve_kind_label(gk)))
	}
}

@(test)
theme_resolve_warning_is_actionable :: proc(t: ^testing.T) {
	// The warning must be actionable: name the bad value, name the replacement,
	// and point at what does exist.
	msg := app.Unknown_Theme_Message("bogger")
	support.check(t, "the warning names the bad value", strings.contains(msg, "bogger"), msg)
	support.check(t, "…names the fallback", strings.contains(msg, "gruvbox-dark"), msg)
	support.check(t, "…lists what IS available", strings.contains(msg, "catppuccin-latte"), msg)
}

@(test)
theme_resolve_picker_filter :: proc(t: ^testing.T) {
	// The picker's filter is a substring test over the CANONICAL name. Typing
	// the flavour word narrows the list; it does not add a row.
	support.check(t, "filter: substring of a canonical name matches",
		app.theme_matches("catppuccin-latte", "latte"), "latte in catppuccin-latte")
	support.check(t, "filter: case-insensitive",
		app.theme_matches("Gruvbox-Dark", "GRUVBOX"), "GRUVBOX")
	support.check(t, "filter: 'latte' narrows to exactly ONE row (aliases are not rows)",
		count_matching("latte") == 1, fmt.tprintf("{} rows match 'latte'", count_matching("latte")))
	support.check(t, "filter: an empty filter passes everything",
		count_matching("") == app.theme_count(),
		fmt.tprintf("{} rows match ''", count_matching("")))
}
