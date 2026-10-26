package app

// ============================================================================
// app.theme — the compiled-in palette set, mirrored from the alacritty colourschema  (T6.2; schema rework)
//
// # WHAT CHANGED, AND WHAT IS NOW FIXED
//
// This module used to hold a hand-authored set of 19 semantic slots whose values
// were picked by us from five upstream palette files, plus a joint blend search
// (`theme_hl_pair_kept`) that MANUFACTURED two of those slots at palette
// resolution time. All of that is gone.
//
// The colour set is now a verbatim mirror of one externally-defined schema: the
// `colors.*` table of an alacritty colour file. The ten shipped palettes are
// the ten files vendored under `.pi/plans/theme-sources/`, key for key, byte
// for byte. We do not author colours any more, we do not adjust them for
// contrast, and we do not derive anything. A theme is 22 named values from a
// source we do not control, and every pixel of the UI picks one of those 22 by
// ROLE.
//
// # THE SCHEMA (22 keys, 5 tables — this is the whole thing)
//
//   colors.primary.foreground   colors.primary.background
//   colors.cursor.cursor        colors.cursor.text
//   colors.selection.text       colors.selection.background
//   colors.normal.{black,red,green,yellow,blue,magenta,cyan,white}
//   colors.bright.{black,red,green,yellow,blue,magenta,cyan,white}
//
// There is no "accent", no "highlight", no "float surface", no "secondary
// text" and no "state colour" in the schema. Those are ROLES, and a role is a
// lookup into the 22 values, not a value of its own. That is the distinction
// this module is built on: the schema is data from upstream, the role table is
// the contract with the view layer, and the two are not the same list.
//
// # THE ROLE TABLE (the contract — verbatim)
//
//   | role                          | resolves from           |
//   |-------------------------------|-----------------------|
//   | background                    | `primary.background`  |
//   | primary text                  | `primary.foreground`  |
//   | secondary text                | `bright.black`        |
//   | highlighted row background    | `selection.background`|
//   | highlighted row text          | `selection.text`      |
//   | border / between-children rules | `bright.white`      |
//   | footer KEY token              | `primary.foreground`  |
//   | footer DESCRIPTION token      | `bright.black`        |
//   | running                       | `normal.green`        |
//   | stopped                       | `normal.red`          |
//   | error                         | `bright.red`          |
//   | caret background              | `cursor.cursor`       |
//   | caret glyph                   | `cursor.text`         |
//
// `theme_role_source` is this table as code and nothing else. Every row is
// asserted, for every theme, by `tests/unit/theme_roles_test.odin`, so the
// comment and the code cannot drift apart unnoticed.
//
// Note that the table is not one-to-one and is not meant to be:
// `primary.foreground` answers BOTH "primary text" and "footer KEY", and
// `bright.black` answers BOTH "secondary text" and "footer DESCRIPTION". A role
// is a question about the screen; a schema key is a value. Two questions may
// have the same answer, and that is upstream's choice, not a bug to iron out.
//
// Eleven of the 22 values are addressed by a role. The other eleven
// (`normal.black`, `normal.yellow`, `normal.blue`, `normal.magenta`,
// `normal.cyan`, `normal.white`, `bright.green`, `bright.yellow`,
// `bright.blue`, `bright.magenta`, `bright.cyan`) are carried in full and
// addressed by nothing: this repo paints twelve kinds of thing and a terminal
// colour file has sixteen ANSI slots, so most of the file is present for
// fidelity rather than for use. `theme_carries_every_schema_key` proves the
// whole 22 is loaded regardless.
//
// # WHAT WAS DELETED, AND WHY
//
//   * `accent`             — a hand-picked "selection bar" colour. The schema
//                            has no accent; the highlight bar is
//                            `selection.background` because that is literally
//                            what that key means.
//   * `run_hl` / `stop_hl` — the two DERIVED highlight roles. See the
//                            RCH-12 section below for what replaced them.
//   * `theme_hl_pair_kept` and its whole apparatus (blend grid, candidate
//                            ladders, joint feasibility search, hue-preservation
//                            test, infeasibility fallback) — the derivation was
//                            the mechanism that made the colour set a thing we
//                            compute rather than a thing we reference, and it is
//                            what the schema rework exists to remove.
//   * `theme_slot_or`      — the unset-slot fallback. It existed because roles
//                            could be missing. With a schema mirror, a role is
//                            resolved by name from a key that is always present,
//                            so there is nothing to fall back from.
//   * `header_fg`, `float_bg`, `float_fg`, `caret` — four slots for surfaces
//                            the schema does not distinguish. The header title
//                            is primary text; the floating pane is drawn on the
//                            page background with primary text and an
//                            error-coloured frame; the caret is the
//                            `cursor.cursor` / `cursor.text` PAIR, which is the
//                            only caret colour the schema defines.
//
// # RCH-12 SURVIVES WITHOUT DERIVATION
//
// The requirement was: a selected RUNNING row must not look like a selected
// STOPPED row. It used to be satisfied by blending the state colour so it
// stayed legible over the highlight bar. It is now satisfied more simply and
// more honestly: `running` and `stopped` keep `normal.green` and `normal.red`
// painted ON TOP OF `selection.background`. The state word does not change
// colour when its row is selected — the theme supplies the distinctness of the
// two state colours, and we do not manufacture it.
//
// `tests/unit/theme_roles_test.odin` verifies that this combination clears the
// legibility floor for all ten themes, and that verification is a floor test on
// real numbers, not a restatement of the design. The verification is required;
// adjusting a hex value so the verification passes is forbidden, and
// `theme_values_match_the_vendored_schema` makes the fudge impossible to hide —
// it re-reads the vendored files and compares.
//
// # LEGIBILITY FINDINGS UNDER THE STRICT MAPPING (REPORTED, NOT FIXED)
//
// Measured at floor 2.0:1 over the strict role table, the vendored values do
// not clear it everywhere. Full matrix in `tests/unit/theme_roles_test.odin`
// (`role_contrast_matrix_is_recorded`), which fails if the set of
// sub-floor pairs changes in EITHER direction — a real regression shows up,
// and so does a silent "fix" that would desync the ledger from the shipped
// values.
//
//   * solarized-dark  secondary text (bright.black #002b36) is the same colour
//                     as the page (primary.background #002b36): contrast
//                     1.000. Column headers, placeholders and footer
//                     descriptions are invisible on this theme.
//   * solarized-light border (bright.white #fdf6e3) is the same colour as the
//                     page (#fdf6e3): 1.000. The between-children rules are
//                     invisible.
//   * catppuccin-latte border 1.608; the rule is present but very faint.
//   * tokyonight-night secondary text 1.914 and nord secondary text 1.693 are
//                     below the floor.
//   * the selection bar itself is close to the page on eight themes
//                     (1.136–1.400) — subtle by upstream design, since these
//                     are the colours a terminal's own selection uses.
//
// None of these were fudged. They are the consequence of the strict mapping
// and are reported as-is.
//
// # THE OPTIONAL OVERRIDE LAYER (DESIGN OPTION (B))
//
// The user chose to fix colliding roles in user-editable data rather than in
// code: a theme may carry an optional per-role override, applied on top of the
// verbatim base through `theme_role_with_override` and out through
// `ui.palette_of`. The compiled-in values above are never edited; the override
// is data (`theme_overrides` in the JSON config), and an absent override leaves
// every role on the verbatim base. The vendored-mirror and role-table tests are
// unchanged by the layer, because the base they pin never moved.
//
// # THE ONE SEAM: A FUTURE SCHEMA LOADER IS AN ISOLATED ADDITION
//
// The product's config format stays JSON (`theme`, `remotes`,
// `cleanup_policy`, unknown keys preserved) and there is NO parser for the
// upstream file format anywhere in this module — see
// `theme_hygiene_test.odin`, which fails the build on the token in
// non-comment src lines.
//
// `theme_from_alacritty_schema` below is the single named drop-in point for a
// future loader that would take a vendored colour file's text and produce a
// `Palette`. It is deliberately UNIMPLEMENTED and returns an error. When it
// is implemented it must be implemented ONCE, in that proc, and
// `THEMES`/`theme_at` must be the only thing it feeds — no call site changes,
// no second format creeping into the view layer, no role-table change. The
// token for the upstream extension itself is spelled only in comments so the
// hygiene guard keeps its teeth.
//
// # WHY A U32 HEX AND NOT A clay.Color
//
//   * the values are transcribed from the sources as hex, so
//     `background = 0x282828` is diffable against the upstream table without a
//     float-in-a-literal detour;
//   * `app` stays free of the renderer's dependencies and testable without a
//     terminal or a Clay archive in the picture;
//   * the conversion point is then impossible to miss, which matters because of
//     the trap below.
//
// # TRAP: Clay channels are 0..255, NOT 0.0..1.0
//
// `Clay_Color` is `[4]c.float` carrying 0..255 (clay-odin/clay.odin:51).
// Feeding 0.16 instead of 40 paints the whole UI black and every check goes
// red at once. The one conversion lives in `ui.palette_of`.
//
// # TRAP: termbox2 reads a zero attr as "terminal default"
//
// In truecolour the attr's low 24 bits are the RGB, and an attr of 0 with no
// TB_HI_BLACK means "use whatever the terminal has", not "black"
// (termbox2.h:3830, 3883). Handled inside `render.attr_of`; `theme_rgb` never
// rounds a requested colour toward zero.
//
// # PROVENANCE
//
// Ten files, vendored under `.pi/plans/theme-sources/`, each 496 bytes, each
// sha256-recorded in that directory's README and re-verified by the unit suite
// against the compiled values. Names in this table are the repo's canonical
// theme names; the file a value came from is named on each entry.
//
//   gruvbox-dark       gruvbox-dark.toml        321c9813…
//   gruvbox-light      gruvbox-light.toml       4b3f4dcc…
//   catppuccin-latte   catppuccin-latte.toml   3e23ff7d…
//   catppuccin-frappe  catppuccin-frappe.toml  6a2bd3bb…
//   catppuccin-macchiato catppuccin-macchiato.toml 4340bb9b…
//   catppuccin-mocha   catppuccin-mocha.toml   76829d7b…
//   tokyonight-night   tokyo-night-default.toml 4618d0ef…
//   nord               nord-default.toml        f1aeb815…
//   solarized-dark     solarized-dark.toml      c892854c…
//   solarized-light    solarized-light.toml     1230f8ec…
//
// `theme_values_match_the_vendored_schema` re-reads these files and compares
// every one of the 22 values, so a transcription error in this table is a red
// test naming the key, not a subtly-wrong screen.
//
// # DEFAULT IS gruvbox-dark (D4)
//
// `catppuccin-latte` ships and is selectable — the user asked for it by name —
// but it is explicitly NOT the default. `THEME_DEFAULT_NAME` is the fallback
// for "no config", "unreadable config" and "config names a theme we do not
// have", which is why it lives here rather than in the config module.
// ============================================================================

import json "core:encoding/json"
import "core:fmt"
import "core:math"
import "base:runtime"
import "core:strings"

//-----------------------------------------------------------------------------
// THE SCHEMA
//-----------------------------------------------------------------------------

// Alacritty_Primary is `colors.primary`.
Alacritty_Primary :: struct {
	foreground : u32,
	background : u32,
}

// Alacritty_Cursor is `colors.cursor`. Both members are kept: `cursor` is the
// block and `text` is what is knocked out of it, and the UI needs the pair.
Alacritty_Cursor :: struct {
	text   : u32,
	cursor : u32,
}

// Alacritty_Selection is `colors.selection`.
Alacritty_Selection :: struct {
	text       : u32,
	background : u32,
}

// Alacritty_Ansi is one of `colors.normal` / `colors.bright`: the eight ANSI
// slots in their canonical order.
Alacritty_Ansi :: struct {
	black   : u32,
	red     : u32,
	green   : u32,
	yellow  : u32,
	blue    : u32,
	magenta : u32,
	cyan    : u32,
	white   : u32,
}

// Palette is one theme's colour set: the upstream schema, in full, unchanged.
//
// There are no fields here that the schema does not have and no field of the
// schema that is not here. If a value is needed on screen that is not in this
// struct, the fix is a ROLE pointing at one of these keys — never a new field
// invented for one widget.
Palette :: struct {
	primary   : Alacritty_Primary,
	cursor    : Alacritty_Cursor,
	selection : Alacritty_Selection,
	normal    : Alacritty_Ansi,
	bright    : Alacritty_Ansi,
}

// Palette_Key enumerates the schema's 22 values in the order the source files
// list them. It exists so the count, the names and the values can be checked
// against the vendored files without a hand-written loop per field.
Palette_Key :: enum {
	primary_foreground,
	primary_background,
	cursor_cursor,
	cursor_text,
	selection_text,
	selection_background,
	normal_black,
	normal_red,
	normal_green,
	normal_yellow,
	normal_blue,
	normal_magenta,
	normal_cyan,
	normal_white,
	bright_black,
	bright_red,
	bright_green,
	bright_yellow,
	bright_blue,
	bright_magenta,
	bright_cyan,
	bright_white,
}

// PALETTE_SLOTS is derived from the schema's own enumeration: primary(2) +
// cursor(2) + selection(2) + normal(8) + bright(8) = 22. It is not a number
// anyone chose; it is the number of colour values the mirrored schema has, and
// `len(Palette_Key)` is the derivation. `theme_slots` returns exactly this
// many values and the tests assert the array length, the key names and the
// per-theme values against the vendored files.
//
// The previous value was 19. It is not 19 any more because the thing being
// counted changed: 19 counted hand-authored semantic slots (two of which were
// not even authored but computed), and 22 counts the schema's colour values.
// The view layer's count of *roles* is a different number again —
// `PALETTE_ROLES`, 13 — and the two are deliberately not equal, because the
// schema and the role table are different lists.
PALETTE_SLOTS :: len(Palette_Key)

// PALETTE_ROLES is the size of the role table: 13 questions the screen can ask
// the palette. It is asserted against the `Role` enum, and the view layer's
// `ui.Palette` is asserted to have exactly one field per role.
PALETTE_ROLES :: len(Role)

// palette_key_name renders a schema key the way the source spells it, so a
// failure message names `selection.background` and not an array index.
palette_key_name :: proc(k: Palette_Key) -> string {
	switch k {
	case .primary_foreground:   return "primary.foreground"
	case .primary_background:   return "primary.background"
	case .cursor_cursor:        return "cursor.cursor"
	case .cursor_text:          return "cursor.text"
	case .selection_text:       return "selection.text"
	case .selection_background: return "selection.background"
	case .normal_black:         return "normal.black"
	case .normal_red:           return "normal.red"
	case .normal_green:         return "normal.green"
	case .normal_yellow:        return "normal.yellow"
	case .normal_blue:          return "normal.blue"
	case .normal_magenta:       return "normal.magenta"
	case .normal_cyan:          return "normal.cyan"
	case .normal_white:         return "normal.white"
	case .bright_black:         return "bright.black"
	case .bright_red:           return "bright.red"
	case .bright_green:         return "bright.green"
	case .bright_yellow:        return "bright.yellow"
	case .bright_blue:          return "bright.blue"
	case .bright_magenta:       return "bright.magenta"
	case .bright_cyan:          return "bright.cyan"
	case .bright_white:         return "bright.white"
	}
	return "?"
}

// palette_keys lists the schema keys in source order.
palette_keys :: proc() -> [PALETTE_SLOTS]Palette_Key {
	return [PALETTE_SLOTS]Palette_Key{
		.primary_foreground, .primary_background,
		.cursor_cursor, .cursor_text,
		.selection_text, .selection_background,
		.normal_black, .normal_red, .normal_green, .normal_yellow,
		.normal_blue, .normal_magenta, .normal_cyan, .normal_white,
		.bright_black, .bright_red, .bright_green, .bright_yellow,
		.bright_blue, .bright_magenta, .bright_cyan, .bright_white,
	}
}

// theme_slot reads one schema value by key. Explicit switch rather than a
// transmute onto a flat array: the mapping from key to field must be visible at
// the point of use, and a field renamed without updating this is a compile error
// rather than a silently-shifted array.
theme_slot :: proc(p: Palette, k: Palette_Key) -> u32 {
	switch k {
	case .primary_foreground:   return p.primary.foreground
	case .primary_background:   return p.primary.background
	case .cursor_cursor:        return p.cursor.cursor
	case .cursor_text:          return p.cursor.text
	case .selection_text:       return p.selection.text
	case .selection_background: return p.selection.background
	case .normal_black:         return p.normal.black
	case .normal_red:           return p.normal.red
	case .normal_green:         return p.normal.green
	case .normal_yellow:        return p.normal.yellow
	case .normal_blue:          return p.normal.blue
	case .normal_magenta:       return p.normal.magenta
	case .normal_cyan:          return p.normal.cyan
	case .normal_white:         return p.normal.white
	case .bright_black:         return p.bright.black
	case .bright_red:           return p.bright.red
	case .bright_green:         return p.bright.green
	case .bright_yellow:        return p.bright.yellow
	case .bright_blue:          return p.bright.blue
	case .bright_magenta:       return p.bright.magenta
	case .bright_cyan:          return p.bright.cyan
	case .bright_white:         return p.bright.white
	}
	return 0
}

//-----------------------------------------------------------------------------
// THE ROLE TABLE
//-----------------------------------------------------------------------------

// Role is one question the view layer asks the palette. The names are the
// roles; `theme_role_source` is the table that ties each to a schema key.
Role :: enum {
	background,        // the page
	text,              // primary text
	secondary,        // secondary text: column headers, placeholders, muted
	hl_bg,            // highlighted row background
	hl_text,          // highlighted row text
	border,           // border / between-children rules
	footer_key,       // the KEY token in a footer hint
	footer_desc,      // the DESCRIPTION token
	running,          // a session that is up
	stopped,          // a session that is not
	error,            // error text and the error pane's frame
	caret_bg,         // the cell the caret sits on
	caret_glyph,      // the glyph knocked out of that cell
}

// theme_role_source is THE ROLE TABLE and nothing else. Keep it in the order of
// the table in this file's header; `role_table_matches_the_documented_mapping`
// asserts each row's source key by name, so a row edited here without editing
// the header (or the reverse) fails with the row named.
theme_role_source :: proc(r: Role) -> Palette_Key {
	switch r {
	case .background:   return .primary_background
	case .text:         return .primary_foreground
	case .secondary:    return .bright_black
	case .hl_bg:        return .selection_background
	case .hl_text:      return .selection_text
	case .border:       return .bright_white
	case .footer_key:   return .primary_foreground
	case .footer_desc:  return .bright_black
	case .running:      return .normal_green
	case .stopped:      return .normal_red
	case .error:        return .bright_red
	case .caret_bg:     return .cursor_cursor
	case .caret_glyph:  return .cursor_text
	}
	return .primary_background // unreachable; `Role` is exhaustive above
}

// theme_role resolves a role to its 0xRRGGBB. This is the ONLY way the rest of
// the program turns a role into a colour, and the only way it turns a palette
// into a colour for drawing purposes: `ui.palette_of` calls it, and no view
// file touches a `Palette` field directly.
theme_role :: proc(p: Palette, r: Role) -> u32 {
	return theme_slot(p, theme_role_source(r))
}

// theme_role_key_name names the schema key a role resolves from — for failure
// messages and for the self-documenting dump in `theme_cases`.
theme_role_key_name :: proc(r: Role) -> string {
	return palette_key_name(theme_role_source(r))
}

//-----------------------------------------------------------------------------
// THE OPTIONAL OVERRIDE LAYER
//-----------------------------------------------------------------------------

// Theme_Override_Spec is the optional per-role override layer for ONE theme.
//
// It is the answer to the legibility findings the strict schema mirror surfaced
// and the user chose NOT to fix in code: solarized-dark's `bright.black` IS its
// own page background (secondary text / footer descriptions at contrast 1.000),
// and solarized-light's `bright.white` IS its own page background (the
// between-children rules at contrast 1.000). Rather than editing the vendored
// values — which the verbatim-mirror tests forbid — the theme may carry an
// optional override per ROLE, and the override is user-editable data
// (`theme_overrides` in the JSON config), not a code-side colour.
//
// Presence is tracked by `overridden[]` per role, NOT by the hex being zero:
// an override of #000000 is a real override and must not read as absent. The
// zero value of this struct therefore means "no overrides", which is what every
// compiled-in theme and every unconfigured theme resolves through `theme_role`.
Theme_Override_Spec :: struct {
	overridden : [PALETTE_ROLES]bool, // presence per role, in theme_role order
	hexes       : [PALETTE_ROLES]u32, // the override hex per overridden role
}

// theme_role_with_override resolves one role to its colour, applying an
// optional override when the theme carries one for that role.
//
// This is the override-aware half of the single contract: `theme_role` stays
// the pure, verbatim-base resolver (and is what the compiled-in table and the
// role-table tests exercise), while a theme that carries an override set routes
// through here instead. The override REPLACES the resolved colour; it never
// blends, never derives, never adjusts — it is data applied on top of the base.
//
// The index is the role's ordinal in the same order `theme_role_names` lists
// them, which is also the order the view layer's `ui.Palette` fields use; the
// codebase already leans on that correspondence (`int(Palette_Key)` array
// indexing in `theme_slots`).
theme_role_with_override :: proc(p: Palette, r: Role, ov: Theme_Override_Spec) -> u32 {
	i := int(r)
	if i >= 0 && i < PALETTE_ROLES && ov.overridden[i] {
		return ov.hexes[i]
	}
	return theme_role(p, r)
}

// theme_hex_value parses a "#rrggbb" string into the 0xRRGGBB the rest of the
// module works in. The leading `#` and the six digits are required; anything
// else is not an override this layer will apply (and the caller reports it).
//
// Explicit shifts rather than a transmute: the caller must be able to see that
// a "#rrggbb" becomes 0xRRGGBB with no normalisation anywhere near it.
theme_hex_value :: proc(s: string) -> (u32, bool) {
	if len(s) != 7 || s[0] != '#' { return 0, false }
	v : u32 = 0
	for i in 1..<7 {
		c := s[i]
		d : u8
		if c >= '0' && c <= '9' {
			d = u8(c - '0')
		} else if c >= 'a' && c <= 'f' {
			d = u8(c - 'a') + 10
		} else if c >= 'A' && c <= 'F' {
			d = u8(c - 'A') + 10
		} else {
			return 0, false
		}
		v = (v << 4) | u32(d)
	}
	return v, true
}

// theme_role_index_by_name finds the ordinal of a role by its documented name
// ("secondary", "hl_bg", …) — the lookup the override layer's data is written
// in. Names are compared case-insensitively, like theme resolution itself.
theme_role_index_by_name :: proc(name: string) -> (int, bool) {
	names := theme_role_names()
	wanted := strings.to_lower(name, context.temp_allocator)
	for i in 0..<len(names) {
		if strings.to_lower(names[i], context.temp_allocator) == wanted {
			return i, true
		}
	}
	return -1, false
}

// theme_overrides_for builds the optional override set that applies to one
// theme out of the config's `theme_overrides` object — the shape
// `{ "<theme>": { "<role>": "#rrggbb", … } }` — overlaid on the THEME'S OWN
// compiled-in overrides (the base).
//
// The lookup is by the theme's CANONICAL name (what the resolution landed on),
// because an override is a claim about one entry of the table; aliases are doors
// into it, not separate entries, so an override written under an alias name
// simply does not apply.
//
// Merge order: the theme's own compiled-in overrides (the base — today the two
// colliding themes carry theirs) are applied first, then the config's entries for
// that theme on top, so a hand-edited `theme_overrides` layer can still fix a
// colliding role the shipped default did not cover. The user layer wins; the
// base is data, the user is data, and the resolution is one override-aware hop.
//
// Bad entries (an unknown role, a value that is not a "#rrggbb" string) are
// skipped and named in the returned notes, so a hand-edited config surfaces a
// warning line rather than silently painting a wrong colour.
theme_overrides_for :: proc(base: Theme_Override_Spec, overrides_json: json.Object, theme_name: string) -> (Theme_Override_Spec, []string) {
	spec := base
	notes := make([dynamic]string, 0, 2)
	wanted := strings.to_lower(theme_name, context.temp_allocator)
	for name, val in overrides_json {
		if strings.to_lower(name, context.temp_allocator) != wanted { continue }
		ov, is_obj := val.(json.Object)
		if !is_obj {
			append(&notes, fmt.tprintf(
				"config: theme '%s' has a malformed override entry - not applied", name))
			continue
		}
		for role_name, hex_val in ov {
			hex_str, is_str := hex_val.(json.String)
			idx, is_role := theme_role_index_by_name(role_name)
			hex, hex_ok := u32(0), false
			if is_str { hex, hex_ok = theme_hex_value(string(hex_str)) }
			if !is_role || !hex_ok {
				append(&notes, fmt.tprintf(
					"config: theme '%s' override for unknown role '%s' is not applied",
					theme_name, role_name))
				continue
			}
			spec.overridden[idx] = true
			spec.hexes[idx] = hex
		}
	}
	return spec, notes[:]
}

theme_role_names :: proc() -> [PALETTE_ROLES]string {
	return [PALETTE_ROLES]string{
		"background", "text", "secondary", "hl_bg", "hl_text", "border",
		"footer_key", "footer_desc", "running", "stopped", "error",
		"caret_bg", "caret_glyph",
	}
}

theme_roles :: proc() -> [PALETTE_ROLES]Role {
	return [PALETTE_ROLES]Role{
		.background, .text, .secondary, .hl_bg, .hl_text, .border,
		.footer_key, .footer_desc, .running, .stopped, .error,
		.caret_bg, .caret_glyph,
	}
}

theme_slots :: proc(p: Palette) -> [PALETTE_SLOTS]u32 {
	out : [PALETTE_SLOTS]u32
	for k in palette_keys() {
		out[int(k)] = theme_slot(p, k)
	}
	return out
}

// theme_rgb splits a palette entry into 0..255 channels.
//
// Explicit shifts rather than a transmute: the caller must be able to see that
// a 0xRRGGBB becomes (R,G,B) with no normalisation anywhere near it.
theme_rgb :: proc(hex: u32) -> (r, g, b: u8) {
	r = u8((hex >> 16) & 0xff)
	g = u8((hex >> 8) & 0xff)
	b = u8(hex & 0xff)
	return
}

// theme_hex renders a palette entry back as the six-digit form the sources use.
theme_hex :: proc(hex: u32) -> string {
	return fmt.tprintf("#%06x", hex & 0xffffff)
}

//-----------------------------------------------------------------------------
// WCAG 2.1 LUMINANCE AND CONTRAST
//-----------------------------------------------------------------------------
//
// Kept in the product module rather than duplicated in the test file because
// the legibility verification is a claim about the shipped values, and a claim
// measured with a second copy of the formula is a claim about the copy.

// theme_srgb_to_linear inverts the sRGB transfer function. The linear segment
// near black is part of the standard, not a shortcut: skipping it mis-ranks
// dark colours, which is the region these themes work in.
theme_srgb_to_linear :: proc(c: u8) -> f64 {
	s := f64(c) / 255.0
	if s <= 0.03928 { return s / 12.92 }
	return math.pow((s + 0.055) / 1.055, 2.4)
}

// theme_luma is WCAG relative luminance — NOT perceived brightness by
// averaging channels. The weights are the Rec. 709 ones the standard names.
theme_luma :: proc(hex: u32) -> f64 {
	r, g, b := theme_rgb(hex)
	return 0.2126 * theme_srgb_to_linear(r) +
	       0.7152 * theme_srgb_to_linear(g) +
	       0.0722 * theme_srgb_to_linear(b)
}

// theme_contrast_lumina is the ratio from two already-computed luminances.
theme_contrast_lumina :: proc(a, b: f64) -> f64 {
	la := a + 0.05
	lb := b + 0.05
	if la > lb { return la / lb }
	return lb / la
}

// theme_contrast is the WCAG 2.1 ratio between two palette entries, always
// >= 1 and symmetric by construction.
theme_contrast :: proc(a, b: u32) -> f64 {
	return theme_contrast_lumina(theme_luma(a), theme_luma(b))
}

// THEME_LEGIBILITY_FLOOR is the floor the state-word-on-the-bar verification is
// run against, and the floor the full role matrix is recorded against.
//
// It is 2.0 and not 4.5 deliberately: 4.5 is WCAG AA for body text, and no
// terminal theme of ten is designed against it for a role like "muted footer
// description". 2.0 is the level at which a coloured word is distinguishable
// from the bar it sits on, which is what RCH-12 asks to preserve. It is the
// SAME number the previous derived-pair machinery carried, so adopting it here
// is not a softening to make a test pass: the ten vendored themes clear it for
// the two pairs the requirement names (minimum 2.119, gruvbox-light's
// `stopped` over `selection.background`), and where they fail elsewhere that
// failure is recorded rather than patched.
THEME_LEGIBILITY_FLOOR :: f64(2.0)

//-----------------------------------------------------------------------------
// THE SEAM: A FUTURE SCHEMA-FILE LOADER
//-----------------------------------------------------------------------------

// Theme_Schema_Loader_Stub is what the seam returns. A dedicated message so a
// caller that forgot to implement the loader cannot mistake the result for a
// parsed-but-empty palette.
Theme_Schema_Loader_Stub :: "not implemented: the colour-schema file loader is a deliberate seam and has no parser here"

// theme_from_alacritty_schema is the SINGLE drop-in point for reading an
// upstream colour file's text into a `Palette`.
//
// IT IS UNIMPLEMENTED ON PURPOSE. The product reads JSON configuration only
// (see config.odin and `theme_hygiene_test.odin`), and this repo's rule is
// that the upstream schema is compiled in, not parsed at run time. The proc
// exists so that the day a user-supplied file becomes a requirement, there is
// exactly one place it lands:
//
//   * it takes the file's text and returns (Palette, error_message);
//   * it must produce the SAME 22-key struct, so no caller changes;
//   * `THEMES` becomes a runtime list built by calling it, and `theme_at` /
//     `theme_index_of` / the role table stay untouched — a role resolves from a
//     schema key, and the schema is the same whether it was compiled or read;
//   * it must NOT gain contrast adjustment, blending or slot synthesis. A file
//     that is missing a key is a parse error naming the key, not an invitation
//     to fall back to a neighbour (that fallback existed here as `theme_slot_or`
//     and was deleted with the rest of the manufactured-colour machinery).
//
// `Theme_Schema_Loader_Stub` is returned for every input, including empty and
// including syntactically perfect input, so the seam can never be mistaken for
// a working loader that "just needs a nudge".
theme_from_alacritty_schema :: proc(text: string) -> (Palette, string) {
	_ = text
	return Palette{}, Theme_Schema_Loader_Stub
}

//-----------------------------------------------------------------------------
// Theme identity
//-----------------------------------------------------------------------------

// Theme is one selectable entry: its canonical name, the names that also
// resolve to it, and its colour set.
//
// `overrides` is the OPTIONAL per-role override layer (design option (b) from
// the override-seam decision): when a theme carries overrides, they replace the
// resolved colour of the named ROLES on top of the verbatim base — the compiled
// values are never edited, an override is user-editable data applied at
// resolution time. A theme with no overrides carries the zero spec, which means
// "no overrides": every role resolves through `theme_role` to the verbatim base.
// A theme that ships colliding overrides (today: solarized-dark — secondary /
// footer_desc; solarized-light — border) carries them HERE, on the entry, as
// data; the user layer below overlays the config's `theme_overrides` on top of
// that compiled-in base.
Theme :: struct {
	name    : string,   // canonical, kebab-case — what the config stores
	aliases : []string, // tolerant spellings for CONFIG resolution only
	pal     : Palette, // the verbatim alacritty schema values for this theme
	overrides : Theme_Override_Spec, // optional per-role overrides; zero = none
}

// THEME_DEFAULT_NAME is the answer to "we could not work out a theme". D4.
THEME_DEFAULT_NAME :: "gruvbox-dark"

// Resolve_Kind says how a requested name landed, so the caller can put the
// honest word in front of it.
Resolve_Kind :: enum {
	explicit,  // the name was known and used as given
	defaulted, // nothing was requested: the D4 default, no warning owed
	fell_back, // a name WAS given but we do not ship it: warn, use the default
}

resolve_kind_label :: proc(k: Resolve_Kind) -> string {
	switch k {
	case .explicit:  return "explicit"
	case .defaulted: return "defaulted"
	case .fell_back: return "fell_back"
	}
	return "?"
}

//-----------------------------------------------------------------------------
// THE SET — ten themes, each one its vendored file's 22 values
//
// Transcribed from `.pi/plans/theme-sources/<file>` with no adjustment of any
// kind. `theme_values_match_the_vendored_schema` re-reads those files and
// compares all 220 values; `theme_sources_are_byte_pinned` hashes them. A
// transcription error here is a red test naming the key and the file, not a
// subtly-wrong screen.
//
// Aliases are deliberately NARROW: they exist so a hand-edited config written
// with the flavour word ("latte") rather than the canonical id still resolves.
//-----------------------------------------------------------------------------

THEMES : [10]Theme = {
	// ── gruvbox-dark: the default (D4) ─────────────────────────────────
	// vendored: gruvbox-dark.toml  sha256 321c9813559a9a6eb99a6ee19829f19a9b9b874ac3cb849d5ddf9826ff7aeb0f
	{
		name    = "gruvbox-dark",
		aliases = []string{"gruvbox", "gruvbox_dark"},
		pal = Palette{
			primary   = Alacritty_Primary{foreground = 0xebdbb2, background = 0x282828},
			cursor    = Alacritty_Cursor{cursor = 0xebdbb2, text = 0x282828},
			selection = Alacritty_Selection{text = 0x282828, background = 0xebdbb2},
			normal    = Alacritty_Ansi{black = 0x282828, red = 0xcc241d, green = 0x98971a,
			                           yellow = 0xd79921, blue = 0x458588, magenta = 0xb16286,
			                           cyan = 0x689d6a, white = 0xa89984},
			bright    = Alacritty_Ansi{black = 0x928374, red = 0xfb4934, green = 0xb8bb26,
			                           yellow = 0xfabd2f, blue = 0x83a598, magenta = 0xd3869b,
			                           cyan = 0x8ec07c, white = 0xebdbb2},
		},
	},

	// ── gruvbox-light ──────────────────────────────────────────────────
	// vendored: gruvbox-light.toml  sha256 4b3f4dccaf5496bbdff7908d928dc11232df4e4e9b288e42d571f3d1b586c828
	{
		name    = "gruvbox-light",
		aliases = []string{"gruvbox_light"},
		pal = Palette{
			primary   = Alacritty_Primary{foreground = 0x3c3836, background = 0xfbf1c7},
			cursor    = Alacritty_Cursor{cursor = 0x3c3836, text = 0xfbf1c7},
			selection = Alacritty_Selection{text = 0xfbf1c7, background = 0x3c3836},
			normal    = Alacritty_Ansi{black = 0xfbf1c7, red = 0xcc241d, green = 0x98971a,
			                           yellow = 0xd79921, blue = 0x458588, magenta = 0xb16286,
			                           cyan = 0x689d6a, white = 0x7c6f64},
			bright    = Alacritty_Ansi{black = 0x928374, red = 0x9d0006, green = 0x79740e,
			                           yellow = 0xb57614, blue = 0x076678, magenta = 0x8f3f71,
			                           cyan = 0x427b58, white = 0x3c3836},
		},
	},

	// ── catppuccin-latte: REQUIRED, and explicitly NOT the default ─────
	// vendored: catppuccin-latte.toml  sha256 3e23ff7d55a606811dcea37fd87991c7f6c28ba7e53cd8be4107f09e99babded
	// The canonical spelling is `catppuccin-latte` (the user wrote "catputin");
	// the misspelling is an alias so the config forgives but the product name
	// stays correct.
	{
		name    = "catppuccin-latte",
		aliases = []string{"latte", "catppuccin", "catpuccin-latte", "catppuccin_latte"},
		pal = Palette{
			primary   = Alacritty_Primary{foreground = 0x4c4f69, background = 0xeff1f5},
			cursor    = Alacritty_Cursor{cursor = 0xdc8a78, text = 0xeff1f5},
			selection = Alacritty_Selection{text = 0x4c4f69, background = 0xd8dae1},
			normal    = Alacritty_Ansi{black = 0x5c5f77, red = 0xd20f39, green = 0x40a02b,
			                           yellow = 0xdf8e1d, blue = 0x1e66f5, magenta = 0xea76cb,
			                           cyan = 0x179299, white = 0xacb0be},
			bright    = Alacritty_Ansi{black = 0x6c6f85, red = 0xde293e, green = 0x49af3d,
			                           yellow = 0xeea02d, blue = 0x456eff, magenta = 0xfe85d8,
			                           cyan = 0x2d9fa8, white = 0xbcc0cc},
		},
	},

	// vendored: catppuccin-frappe.toml  sha256 6a2bd3bb2aedb7764ee302716e9ecde375a1a7efcd8578cd5061fe398011df2a
	{
		name    = "catppuccin-frappe",
		aliases = []string{"frappe"},
		pal = Palette{
			primary   = Alacritty_Primary{foreground = 0xc6d0f5, background = 0x303446},
			cursor    = Alacritty_Cursor{cursor = 0xf2d5cf, text = 0x232634},
			selection = Alacritty_Selection{text = 0xc6d0f5, background = 0x44495d},
			normal    = Alacritty_Ansi{black = 0x51576d, red = 0xe78284, green = 0xa6d189,
			                           yellow = 0xe5c890, blue = 0x8caaee, magenta = 0xf4b8e4,
			                           cyan = 0x81c8be, white = 0xa5adce},
			bright    = Alacritty_Ansi{black = 0x626880, red = 0xe67172, green = 0x8ec772,
			                           yellow = 0xd9ba73, blue = 0x7b9ef0, magenta = 0xf2a4db,
			                           cyan = 0x5abfb5, white = 0xb5bfe2},
		},
	},

	// vendored: catppuccin-macchiato.toml  sha256 4340bb9b6b3ad823d27d4e66052b00a06e51876f12bcdd8e668a569bd7c2055f
	{
		name    = "catppuccin-macchiato",
		aliases = []string{"macchiato"},
		pal = Palette{
			primary   = Alacritty_Primary{foreground = 0xcad3f5, background = 0x24273a},
			cursor    = Alacritty_Cursor{cursor = 0xf4dbd6, text = 0x181926},
			selection = Alacritty_Selection{text = 0xcad3f5, background = 0x3a3e53},
			normal    = Alacritty_Ansi{black = 0x494d64, red = 0xed8796, green = 0xa6da95,
			                           yellow = 0xeed49f, blue = 0x8aadf4, magenta = 0xf5bde6,
			                           cyan = 0x8bd5ca, white = 0xa5adcb},
			bright    = Alacritty_Ansi{black = 0x5b6078, red = 0xec7486, green = 0x8ccf7f,
			                           yellow = 0xe1c682, blue = 0x78a1f6, magenta = 0xf2a9dd,
			                           cyan = 0x63cbc0, white = 0xb8c0e0},
		},
	},

	// vendored: catppuccin-mocha.toml  sha256 76829d7b773dfa66f282c2963d297089db89e45c442dd71b33f6d45cf4e8a43b
	{
		name    = "catppuccin-mocha",
		aliases = []string{"mocha"},
		pal = Palette{
			primary   = Alacritty_Primary{foreground = 0xcdd6f4, background = 0x1e1e2e},
			cursor    = Alacritty_Cursor{cursor = 0xf5e0dc, text = 0x11111b},
			selection = Alacritty_Selection{text = 0xcdd6f4, background = 0x353748},
			normal    = Alacritty_Ansi{black = 0x45475a, red = 0xf38ba8, green = 0xa6e3a1,
			                           yellow = 0xf9e2af, blue = 0x89b4fa, magenta = 0xf5c2e7,
			                           cyan = 0x94e2d5, white = 0xa6adc8},
			bright    = Alacritty_Ansi{black = 0x585b70, red = 0xf37799, green = 0x89d88b,
			                           yellow = 0xebd391, blue = 0x74a8fc, magenta = 0xf2aede,
			                           cyan = 0x6bd7ca, white = 0xbac2de},
		},
	},

	// ── tokyonight-night ───────────────────────────────────────────────
	// vendored: tokyo-night-default.toml  sha256 4618d0efa28c768b86973fcf6f0a94e92f2bb14fae46cac3992b0cfe54821092
	// The repo's canonical name is `tokyonight-night`; the file is the
	// "default" flavour of the upstream tokyo-night slug.
	{
		name    = "tokyonight-night",
		aliases = []string{"tokyonight", "tokyo-night", "tokyo_night"},
		pal = Palette{
			primary   = Alacritty_Primary{foreground = 0xc0caf5, background = 0x1a1b26},
			cursor    = Alacritty_Cursor{cursor = 0xc0caf5, text = 0x1a1b26},
			selection = Alacritty_Selection{text = 0xc0caf5, background = 0x283457},
			normal    = Alacritty_Ansi{black = 0x15161e, red = 0xf7768e, green = 0x9ece6a,
			                           yellow = 0xe0af68, blue = 0x7aa2f7, magenta = 0xbb9af7,
			                           cyan = 0x7dcfff, white = 0xa9b1d6},
			bright    = Alacritty_Ansi{black = 0x414868, red = 0xf7768e, green = 0x9ece6a,
			                           yellow = 0xe0af68, blue = 0x7aa2f7, magenta = 0xbb9af7,
			                           cyan = 0x7dcfff, white = 0xc0caf5},
		},
	},

	// ── nord ───────────────────────────────────────────────────────────
	// vendored: nord-default.toml  sha256 f1aeb81518df1413f1e265c8e207cad214bf09a3a4b379b73d4dbd91b7329431
	// NOTE vs the old hand-authored palette: this file's `primary.foreground`
	// is #d8dee9 (nord4). The palette this repo shipped before used
	// #e5e9f0 (nord5) for `fg`. The mirror uses the file. `normal.white` is
	// #e5e9f0 in the file, which is where the old value now lives.
	{
		name    = "nord",
		aliases = []string{"nord-theme", "nordtheme"},
		pal = Palette{
			primary   = Alacritty_Primary{foreground = 0xd8dee9, background = 0x2e3440},
			cursor    = Alacritty_Cursor{cursor = 0xd8dee9, text = 0x2e3440},
			selection = Alacritty_Selection{text = 0xd8dee9, background = 0x3f4758},
			normal    = Alacritty_Ansi{black = 0x3b4252, red = 0xbf616a, green = 0xa3be8c,
			                           yellow = 0xebcb8b, blue = 0x81a1c1, magenta = 0xb48ead,
			                           cyan = 0x88c0d0, white = 0xe5e9f0},
			bright    = Alacritty_Ansi{black = 0x4c566a, red = 0xbf616a, green = 0xa3be8c,
			                           yellow = 0xebcb8b, blue = 0x81a1c1, magenta = 0xb48ead,
			                           cyan = 0x8fbcbb, white = 0xeceff4},
		},
	},

	// ── solarized ──────────────────────────────────────────────────────
	// vendored: solarized-dark.toml  sha256 c892854c5437e8b39161092f452fb06d6b86064fff2c2b9ed147ac5f725cd346
	// NOTE: this file's `bright.black` is #002b36, which is ALSO
	// `primary.background`. Under the role table that makes secondary text the
	// page colour on this theme (contrast 1.000 — invisible). Reported as a
	// finding; the value is NOT changed.
	//
	// The colliding roles are remediated through the OPTIONAL OVERRIDE LAYER
	// (design option (b)), NOT through an edit of the verbatim base: this entry
	// carries the override that replaces the resolved colour of the colliding
	// roles. `bright.black` answers BOTH the `secondary` role (column headers,
	// placeholders, muted text) and the `footer_desc` role (footer descriptions),
	// so both roles whose resolved colour collides are overridden here. The base
	// `pal` above stays byte-for-byte the vendored file's values; the override is
	// what clears the 1.000 collision, and it is data, not a base edit.
	{
		name    = "solarized-dark",
		aliases = []string{"solarized", "solarized_dark"},
		pal = Palette{
			primary   = Alacritty_Primary{foreground = 0x839496, background = 0x002b36},
			cursor    = Alacritty_Cursor{cursor = 0x839496, text = 0x002b36},
			selection = Alacritty_Selection{text = 0x93a1a1, background = 0x073642},
			normal    = Alacritty_Ansi{black = 0x073642, red = 0xdc322f, green = 0x859900,
			                           yellow = 0xb58900, blue = 0x268bd2, magenta = 0xd33682,
			                           cyan = 0x2aa198, white = 0xeee8d5},
			bright    = Alacritty_Ansi{black = 0x002b36, red = 0xcb4b16, green = 0x586e75,
			                           yellow = 0x657b83, blue = 0x839496, magenta = 0x6c71c4,
			                           cyan = 0x93a1a1, white = 0xfdf6e3},
		},
		overrides = Theme_Override_Spec{
			overridden = [PALETTE_ROLES]bool{false, false, true, false, false, false, false, true, false, false, false, false, false},
			hexes       = [PALETTE_ROLES]u32{0, 0, 0x586e75, 0, 0, 0, 0, 0x586e75, 0, 0, 0, 0, 0},
		},
	},

	// vendored: solarized-light.toml  sha256 1230f8ec75ddb464d9edd026c08e5f9876cf1df5bf1266fb5065cec2869a2cf4
	// NOTE: this file's `bright.white` is #fdf6e3, which is ALSO
	// `primary.background`. Under the role table that makes the
	// between-children rules invisible on this theme (1.000). Reported as a
	// finding; the value is NOT changed.
	{
		name    = "solarized-light",
		aliases = []string{"solarized_light"},
		pal = Palette{
			primary   = Alacritty_Primary{foreground = 0x657b83, background = 0xfdf6e3},
			cursor    = Alacritty_Cursor{cursor = 0x657b83, text = 0xfdf6e3},
			selection = Alacritty_Selection{text = 0x586e75, background = 0xeee8d5},
			normal    = Alacritty_Ansi{black = 0x073642, red = 0xdc322f, green = 0x859900,
			                           yellow = 0xb58900, blue = 0x268bd2, magenta = 0xd33682,
			                           cyan = 0x2aa198, white = 0xeee8d5},
			bright    = Alacritty_Ansi{black = 0x002b36, red = 0xcb4b16, green = 0x586e75,
			                           yellow = 0x657b83, blue = 0x839496, magenta = 0x6c71c4,
			                           cyan = 0x93a1a1, white = 0xfdf6e3},
		},
		overrides = Theme_Override_Spec{
			overridden = [PALETTE_ROLES]bool{false, false, false, false, false, true, false, false, false, false, false, false, false},
			hexes       = [PALETTE_ROLES]u32{0, 0, 0, 0, 0, 0x586e75, 0, 0, 0, 0, 0, 0, 0},
		},
	},
}

//-----------------------------------------------------------------------------
// Enumeration
//-----------------------------------------------------------------------------

theme_count :: proc() -> int { return len(THEMES) }

theme_at :: proc(i: int) -> Theme { return THEMES[i] }

// theme_names lists the CANONICAL names in picker order, allocated from `alloc`.
//
// Only canonical names reach the picker: an alias is a door into the table, not
// a second entry in it. Listing both would let the user "pick" two names for
// one palette and then the config would disagree with the screen.
theme_names :: proc(alloc: runtime.Allocator) -> ([]string, runtime.Allocator_Error) {
	out := make([dynamic]string, 0, len(THEMES))
	for t in THEMES do append(&out, strings.clone(t.name, alloc))
	return out[:], nil
}

//-----------------------------------------------------------------------------
// Resolution
//-----------------------------------------------------------------------------

// theme_index_of finds a theme by canonical name, then by alias.
// Comparison ignores case and surrounding whitespace, because a hand-written
// config is edited by a person and `"Gruvbox-Dark "` must not be a fatal typo.
theme_index_of :: proc(requested: string) -> (int, bool) {
	needle := strings.trim_space(requested)
	if len(needle) == 0 { return -1, false }
	lowered := strings.to_lower(needle, context.temp_allocator)

	for t, i in THEMES {
		if strings.to_lower(t.name, context.temp_allocator) == lowered {
			return i, true
		}
	}
	for t, i in THEMES {
		for a in t.aliases {
			if strings.to_lower(a, context.temp_allocator) == lowered {
				return i, true
			}
		}
	}
	return -1, false
}

theme_is_known :: proc(requested: string) -> bool {
	_, ok := theme_index_of(requested)
	return ok
}

theme_named :: proc(requested: string) -> (Theme, bool) {
	i, ok := theme_index_of(requested)
	if !ok { return Theme{}, false }
	return THEMES[i], true
}

// theme_named_or_default is the "just give me something to paint with"
// lookup: exact name, then alias, then the D4 default. It is `theme_resolve`
// with the kind dropped, for callers that cannot act on the difference.
theme_named_or_default :: proc(requested: string) -> Theme {
	t, _ := theme_resolve(requested)
	return t
}

// theme_default is THE fallback theme: no config, unreadable config, or a config
// naming something we do not ship. It is a lookup, so the default can never be
// a palette that drifted away from the table.
theme_default :: proc() -> Theme {
	t, ok := theme_named(THEME_DEFAULT_NAME)
	// gruvbox-dark is in the table by construction (the smoke suite asserts
	// it). If that ever stops being true, the FIRST theme is the next-best
	// answer: a usable, fully-populated palette, which is all this path needs.
	if !ok && len(THEMES) > 0 { return THEMES[0] }
	return t
}

// theme_resolve answers "the config said X — what do we paint, and what must we
// tell the user about it?"
//
// The three answers are why this returns a kind rather than a bool: ISC-19
// needs an unknown name to be LOUD (a warning) and an absent name to be SILENT
// (a default). A bool would collapse the two and the footer would either spam
// on a fresh install or stay quiet over a typo.
theme_resolve :: proc(requested: string) -> (Theme, Resolve_Kind) {
	trimmed := strings.trim_space(requested)
	if len(trimmed) == 0 {
		return theme_default(), .defaulted
	}
	t, ok := theme_named(trimmed)
	if !ok {
		return theme_default(), .fell_back
	}
	return t, .explicit
}

// Unknown_Theme_Message is the one line ISC-19 asks for: it names the value
// that was wrong, what is being used instead, and where the list lives.
Unknown_Theme_Message :: proc(requested: string) -> string {
	return fmt.tprintf(
		"unknown theme '%s' - using %s (available: %s)",
		requested, THEME_DEFAULT_NAME, theme_list_string(context.allocator))
}

// theme_list_string is the shipped set, canonical spelling, in picker order.
theme_list_string :: proc(alloc: runtime.Allocator) -> string {
	names, _ := theme_names(alloc)
	joined, _ := strings.join(names, ", ", alloc)
	return joined
}
