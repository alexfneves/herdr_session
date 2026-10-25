package unit

// ─────────────────────────────────────────────────────────────────────────────
// theme_set_test.odin — the compiled-in palette table.
//
// Ported 1:1 from the `theme-set` case of dev/theme-smoke.sh (via
// src/theme_cases.odin), 13 counted assertions. The measurement that sets the
// floor is the RUNTIME count, not a grep of `check(` call sites.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

@(test)
theme_set_ships_a_small_closed_set :: proc(t: ^testing.T) {
	n := app.theme_count()
	support.check(t, "the set is non-empty and small", n >= 8 && n <= 12,
		fmt.tprintf("{} palettes shipped", n))
}

@(test)
theme_set_default_is_gruvbox_dark :: proc(t: ^testing.T) {
	// The default MUST be gruvbox-dark (plan D4).
	d := app.theme_default()
	support.eq(t, "default theme is gruvbox-dark (D4)", d.name, "gruvbox-dark")
	support.check(t, "THEME_DEFAULT_NAME agrees with theme_default()",
		app.THEME_DEFAULT_NAME == d.name,
		fmt.tprintf("const='{}' fn='{}'", app.THEME_DEFAULT_NAME, d.name))
}

@(test)
theme_set_latte_is_required_and_not_default :: proc(t: ^testing.T) {
	// catppuccin-latte is REQUIRED and must NOT be the default.
	latte, has_latte := app.theme_named("catppuccin-latte")
	support.check(t, "catppuccin-latte is compiled in", has_latte,
		fmt.tprintf("found = {}", has_latte))
	support.check(t, "…and it is NOT the default",
		has_latte && latte.name != app.THEME_DEFAULT_NAME,
		fmt.tprintf("latte='{}' default='{}'", latte.name, app.THEME_DEFAULT_NAME))
	support.eq(t, "…canonical spelling is catppuccin-latte", latte.name, "catppuccin-latte")
}

@(test)
theme_set_names_are_kebab_case :: proc(t: ^testing.T) {
	// Names are kebab-case: a picker filters by substring, so a name with a
	// space or an underscore in it is a name the user cannot type quickly.
	bad := 0
	bad_detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		nm := app.theme_at(i).name
		for j := 0; j < len(nm); j += 1 {
			b := nm[j]
			ok_char := (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') || b == '-'
			if !ok_char {
				bad += 1
				bad_detail = fmt.tprintf("{} '{}' has byte {};", bad_detail, nm, int(b))
			}
		}
	}
	support.check(t, "every name is kebab-case (a-z 0-9 -)", bad == 0,
		fmt.tprintf("{} offending byte(s){}", bad, bad_detail))
}

@(test)
theme_set_no_duplicate_names :: proc(t: ^testing.T) {
	// Duplicate names would give the picker two rows for one id.
	dups := 0
	n := app.theme_count()
	for i := 0; i < n; i += 1 {
		for j := i + 1; j < n; j += 1 {
			if app.theme_at(i).name == app.theme_at(j).name { dups += 1 }
		}
	}
	support.check(t, "no duplicate theme names", dups == 0, fmt.tprintf("{} duplicate(s)", dups))
}

@(test)
theme_set_palette_slot_count :: proc(t: ^testing.T) {
	// PALETTE_SLOTS is the count of COLOUR VALUES in the mirrored schema:
	// primary(2) + cursor(2) + selection(2) + normal(8) + bright(8) = 22.
	// It used to be 19, and the two numbers are not comparable — 19 counted
	// hand-authored semantic slots (two of which were not authored at all but
	// computed), 22 counts the schema's values. The derivation is asserted
	// three ways so a stale number cannot survive:
	//
	//   * against the literal 22,
	//   * against len(Palette_Key) — the enumeration the count is derived from,
	//   * against the key table `palette_keys()` actually returns.
	//
	// And the ROLE count is asserted to be a DIFFERENT number: the role table
	// and the schema are not the same list, and a change that made them equal
	// would mean someone collapsed one into the other.
	KEYS :: 2 + 2 + 2 + 8 + 8
	support.eq_i(t, "PALETTE_SLOTS is the mirrored schema's value count", app.PALETTE_SLOTS, KEYS)
	support.eq_i(t, "…which is len(Palette_Key) — the derivation, not a guess",
		app.PALETTE_SLOTS, len(app.Palette_Key))
	support.eq_i(t, "…and the key table really is that long",
		app.PALETTE_SLOTS, len(app.palette_keys()))
	support.eq_i(t, "PALETTE_ROLES is the role table's size", app.PALETTE_ROLES, 13)
	support.check(t, "…roles are NOT slots (schema keys != UI roles)",
		app.PALETTE_ROLES != app.PALETTE_SLOTS,
		fmt.tprintf("roles={} keys={}", app.PALETTE_ROLES, app.PALETTE_SLOTS))
	support.check(t, "…and the old 19-slot shape is gone, not re-labelled",
		app.PALETTE_SLOTS != 19, fmt.tprintf("{}", app.PALETTE_SLOTS))
}

@(test)
theme_set_every_theme_carries_every_schema_key :: proc(t: ^testing.T) {
	// SCHEMA COVERAGE. Every one of the 22 values must be present in every
	// theme. A value left at 0x000000 means a widget silently paints with a
	// colour nobody chose (0 is also the termbox "terminal default" sentinel,
	// so a hole here is invisible in the worst sense), and a value with bits
	// above the RGB field is not a colour at all.
	//
	// There is no exemption list in this test. The previous version exempted two
	// slots because they were DERIVED; with the schema mirror nothing is derived,
	// so nothing is exempt and the rule is simply "all 220 values, every theme".
	gaps := 0
	wide := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		for k in app.palette_keys() {
			s := app.theme_slot(th.pal, k)
			if (s & 0xff000000) != 0 {
				wide += 1
				detail = fmt.tprintf("{} BAD:{}{}.{} has bits above the RGB field {:08x}",
					detail, th.name, app.palette_key_name(k), s)
			} else if (s & 0xffffff) == 0 {
				gaps += 1
				detail = fmt.tprintf("{} GAP:{}{}.{} is unset (0x000000)",
					detail, th.name, app.palette_key_name(k))
			}
		}
	}
	support.check(t,
		"every theme carries all 22 schema values (none unset)",
		gaps == 0, fmt.tprintf("{} gap(s) across {} themes{}", gaps, app.theme_count(), detail))
	support.check(t,
		"…and none of them has bits outside the RGB field",
		wide == 0, fmt.tprintf("{} overflow(s){}", wide, detail))
}

@(test)
theme_set_text_is_never_its_own_background :: proc(t: ^testing.T) {
	// A role pair that resolves to the same colour is unreadable and no
	// glyph-level check catches it. Asserted on the RESOLVED roles, which is
	// what is painted — not on palette fields, which is what used to be authored.
	//
	// This is the narrow, always-true slice. The wider "is every role legible on
	// what it is painted over" question is answered honestly (and with
	// failures) in `role_contrast_matrix_is_recorded` in theme_roles_test.odin;
	// this pair is the one that must hold in literally every palette.
	invisible := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		p := app.theme_at(i).pal
		if app.theme_role(p, .text) == app.theme_role(p, .background) {
			invisible += 1
			detail = fmt.tprintf("{} {}: text == background", detail, app.theme_at(i).name)
		}
		if app.theme_role(p, .hl_text) == app.theme_role(p, .hl_bg) {
			invisible += 1
			detail = fmt.tprintf("{} {}: hl_text == hl_bg", detail, app.theme_at(i).name)
		}
	}
	support.check(t, "no theme makes its text its own background", invisible == 0,
		fmt.tprintf("{} invisible pair(s){}", invisible, detail))
}

@(test)
theme_set_picker_list_is_canonical_only :: proc(t: ^testing.T) {
	// The picker gets canonical names only. An alias is a door into the table,
	// not a second row in it.
	n := app.theme_count()
	names, _ := app.theme_names(context.allocator)
	support.check(t, "theme_names() returns one entry per palette", len(names) == n,
		fmt.tprintf("{} names for {} palettes", len(names), n))
	leaked := 0
	leaked_detail := ""
	for nm in names {
		found := false
		for i := 0; i < n; i += 1 {
			if app.theme_at(i).name == nm { found = true }
		}
		if !found {
			leaked += 1
			leaked_detail = fmt.tprintf("{} '{}'", leaked_detail, nm)
		}
	}
	support.check(t, "picker list holds only CANONICAL names (no alias rows)", leaked == 0,
		fmt.tprintf("{} leaked alias(es){}", leaked, leaked_detail))
	support.note(t, fmt.tprintf("    shipped: {}", app.theme_list_string(context.allocator)))
	_ = strings.trim_space
}
