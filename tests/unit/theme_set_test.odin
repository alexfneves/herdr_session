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
	support.eq_i(t, "PALETTE_SLOTS matches ui.Palette's field count", app.PALETTE_SLOTS, 13)
}

@(test)
theme_set_every_theme_fills_every_slot :: proc(t: ^testing.T) {
	// SLOT COVERAGE. A slot left at 0x000000 means a widget silently paints
	// with a colour nobody chose. None of the shipped palettes uses pure black
	// as a semantic colour, so zero == unset is a sound reading here — and the
	// slot count is asserted separately, so adding a slot without filling it
	// cannot slip past.
	slot_names := [app.PALETTE_SLOTS]string{
		"bg", "fg", "dim", "border", "header_fg", "accent", "sel_fg", "caret",
		"float_bg", "float_fg", "err_fg", "running", "stopped",
	}
	gaps := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		slots := [app.PALETTE_SLOTS]u32{
			th.pal.bg, th.pal.fg, th.pal.dim, th.pal.border, th.pal.header_fg,
			th.pal.accent, th.pal.sel_fg, th.pal.caret, th.pal.float_bg,
			th.pal.float_fg, th.pal.err_fg, th.pal.running, th.pal.stopped,
		}
		for s, k in slots {
			if (s & 0xff000000) != 0 {
				gaps += 1
				detail = fmt.tprintf("{} {};{}.{} has bits above the RGB field {:08x}",
					detail, "BAD:", th.name, slot_names[k], s)
			} else if (s & 0xffffff) == 0 {
				gaps += 1
				detail = fmt.tprintf("{} GAP:{}.{} is unset (0x000000)", detail, th.name, slot_names[k])
			}
		}
	}
	support.check(t,
		"every theme fills all 13 slots (bg/fg/border/rule/accent/selection/running/stopped/error)",
		gaps == 0, fmt.tprintf("{} gap(s) across {} themes{}", gaps, app.theme_count(), detail))
}

@(test)
theme_set_text_is_never_its_own_background :: proc(t: ^testing.T) {
	// A palette where fg == bg is unreadable and no glyph-level check catches it.
	invisible := 0
	for i := 0; i < app.theme_count(); i += 1 {
		p := app.theme_at(i).pal
		if p.fg == p.bg { invisible += 1 }
		if p.sel_fg == p.accent { invisible += 1 } // the selection bar's text
	}
	support.check(t, "text is never its own background colour", invisible == 0,
		fmt.tprintf("{} invisible pair(s)", invisible))
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
