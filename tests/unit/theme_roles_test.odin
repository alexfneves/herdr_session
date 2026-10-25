package unit

// ============================================================================
// theme_roles_test.odin — the ROLE TABLE is the contract, and it is checked.
//
// WHAT REPLACED WHAT
//
// This file replaces `theme_roles_uip2_test.odin`, which existed to prove that
// two palette slots (`run_hl`, `stop_hl`) were DERIVED by a joint blend search
// rather than hand-authored. There is nothing to derive any more: the palette is
// a mirror of the alacritty `colors.*` schema and every colour on screen is one
// of its 22 values selected by ROLE. What has to be proven now is different,
// and harder in a useful way:
//
//   1. the role table says what it says (and the code agrees with the header in
//      `src/app/theme.odin`),
//   2. the view layer's palette is a pure function of that table, so no widget
//      can reach a colour that the table did not choose,
//   3. the strict mapping is MEASURED rather than trusted, and every place it
//      fails is recorded as a finding instead of being painted over.
//
// WHY THE ROLE TABLE IS ASSERTED BY NAME AND NOT BY BEHAVIOUR ALONE
//
// `theme_role(pal, .secondary)` returns *a* colour for every palette no matter
// what the mapping is, so behaviour-only tests cannot tell "secondary resolves
// from bright.black" from "secondary resolves from normal.black". The test
// carries the documented KEY NAME for each row; the product carries the mapping;
// they are compared per row. A one-line edit to `theme_role_source` that swaps
// two rows goes red here naming the row, which is the only way a table this
// shape can be guarded.
//
// WHY A FINDINGS LEDGER INSTEAD OF A PASS/FAIL FLOOR OVER EVERYTHING
//
// The brief is explicit: if a theme fails a legibility floor under the strict
// mapping, that is a FINDING TO REPORT, not a licence to fudge a hex value.
// A blanket "all roles >= 2.0" assertion would be red out of the box, and red
// with 21 known-accepted entries is indistinguishable from red because someone
// broke something. So the ledger asserts the FAILING SET EXACTLY:
//
//   * a NEW sub-floor pair appears -> red (a real regression),
//   * a recorded pair stops failing -> red (someone "fixed" it by editing a
//     hex, which the schema mirror forbids — and if they fixed it the honest
//     way, by re-vendoring, the ledger must be updated deliberately),
//   * the measured value of every pair is printed on every run, so the numbers
//     are in front of a reader without a rebuild-and-grep.
//
// That is a stronger assertion than "everything clears the floor" because it is
// falsifiable in both directions, and it is the only honest shape when the
// shipped values are somebody else's design.
//
// WHY CONTRAST IS COMPUTED, NOT LOOKED AT
//
// Every number is WCAG 2.1 relative-luminance contrast computed from the
// shipped hex through `app.theme_contrast` — the same function the module
// documents, not a second copy of the formula. A number derived from the table
// cannot go stale when the table changes, and it fails with the measured value
// in the message. "Looks fine on my terminal" is not re-checkable.
// ============================================================================

import "core:fmt"
import "core:strings"
import "core:testing"

import clay "../../clay-odin"
import ui "../../src/ui"
import app "../../src/app"
import support "../support"

// ── the documented role table, as DATA in the test ─────────────────────────
//
// Row-for-row what the header of `src/app/theme.odin` claims. `role` is the
// `app.Role` member by name; `key` is the schema key it must resolve from.
Role_Row :: struct {
	role : app.Role,
	role_name : string,
	key  : string,
	what : string,
}

ROLE_TABLE : [13]Role_Row = {
	{.background,   "background",   "primary.background",   "the page"},
	{.text,         "text",         "primary.foreground",   "primary text"},
	{.secondary,   "secondary",    "bright.black",         "secondary text: headers, placeholders, muted"},
	{.hl_bg,       "hl_bg",        "selection.background", "highlighted row background"},
	{.hl_text,     "hl_text",      "selection.text",       "highlighted row text"},
	{.border,      "border",       "bright.white",         "border / between-children rules"},
	{.footer_key,  "footer_key",   "primary.foreground",   "footer KEY token"},
	{.footer_desc, "footer_desc",  "bright.black",         "footer DESCRIPTION token"},
	{.running,     "running",      "normal.green",         "a session that is up"},
	{.stopped,     "stopped",      "normal.red",           "a session that is not"},
	{.error,       "error",        "bright.red",           "error text / error pane frame"},
	{.caret_bg,    "caret_bg",     "cursor.cursor",        "caret background"},
	{.caret_glyph, "caret_glyph",  "cursor.text",          "caret glyph"},
}

// ui_field_of is the view layer's field name for each role, in the SAME ORDER
// as ROLE_TABLE. `palette_of` builds the fields in this order and
// `ui_palette_is_a_pure_function_of_the_role_table` reads the fields back in
// the same order to prove it.
UI_FIELDS : [13]string = {
	"bg", "fg", "dim", "sel_bg", "sel_fg", "border",
	"key_fg", "desc_fg", "running", "stopped", "err_fg", "caret_bg", "caret_fg",
}

// the resolved clay colour of one ui.Palette field, by index. Explicit field
// list rather than a transmute: the order is the assertion, and a transmute
// would happily pass with a reordered struct.
ui_fields :: proc(p: ui.Palette) -> [13]clay.Color {
	return [13]clay.Color{p.bg, p.fg, p.dim, p.sel_bg, p.sel_fg, p.border,
		p.key_fg, p.desc_fg, p.running, p.stopped, p.err_fg, p.caret_bg, p.caret_fg}
}

ui_field :: proc(p: ui.Palette, i: int) -> clay.Color {
	return ui_fields(p)[i]
}

// pad_right pads a label so the printed matrices line up. Hand-rolled because
// Odin's `{}` does not take a width verb, and a matrix that does not line up is
// a matrix nobody reads.
pad_right :: proc(s: string, n: int) -> string {
	if len(s) >= n { return s }
	out : [dynamic]u8 = {}
	defer delete(out)
	for i := 0; i < n; i += 1 {
		if i < len(s) { append(&out, s[i]) } else { append(&out, ' ') }
	}
	return string(out[:])
}

clay_hex :: proc(c: clay.Color) -> u32 {
	r := u32(c[0]) & 0xff
	g := u32(c[1]) & 0xff
	b := u32(c[2]) & 0xff
	return (r << 16) | (g << 8) | b
}

// ── 1. the table says what it says ─────────────────────────────────────────

@(test)
role_table_matches_the_documented_mapping :: proc(t: ^testing.T) {
	// One assertion per ROW. A row that changed in `theme_role_source` without
	// changing here (or the reverse) fails with the row's own name and both
	// names involved.
	for row in ROLE_TABLE {
		got := app.theme_role_source(row.role)
		support.eq(t, fmt.tprintf("role '{}' resolves from '{}'", row.role_name, row.key),
			app.palette_key_name(got), row.key)
	}
}

@(test)
role_table_is_the_complete_set_of_roles :: proc(t: ^testing.T) {
	// The test's table must cover every role there is. If `Role` grows a member
	// and this file did not notice, the count differs and the new role would
	// otherwise be unverified.
	support.eq_i(t, "the test's role table covers every app.Role",
		len(ROLE_TABLE), app.PALETTE_ROLES)
	names := app.theme_role_names()
	support.eq_i(t, "…and app.theme_role_names() agrees on the count",
		len(names), app.PALETTE_ROLES)
	// each declared role name appears exactly once in the product's list
	missing := 0
	dup := 0
	detail := ""
	for row in ROLE_TABLE {
		hits := 0
		for n in names {
			if n == row.role_name { hits += 1 }
		}
		if hits == 0 {
			missing += 1
			detail = fmt.tprintf("{} '{}' is not in app.theme_role_names();", detail, row.role_name)
		} else if hits > 1 {
			dup += 1
			detail = fmt.tprintf("{} '{}' appears {} times;", detail, row.role_name, hits)
		}
	}
	support.check(t, "every role named here exists in the product's role list, exactly once",
		missing == 0 && dup == 0,
		fmt.tprintf("{} missing, {} duplicated{}", missing, dup, detail))
}

@(test)
role_resolution_is_total_and_never_an_unchosen_colour :: proc(t: ^testing.T) {
	// Replaces `roles_slot_or_falls_back_only_on_an_unset_slot` and
	// `roles_incomplete_theme_degrades_to_chosen_colours` from the old file.
	//
	// Those two existed because a role COULD be unset and the product had a
	// fallback proc (`theme_slot_or`) that substituted a neighbour. Under a
	// schema mirror there is nothing to fall back from: a role names a key that
	// is present by construction, so the honest version of "an incomplete theme
	// cannot paint an unchosen colour" is "no role ever resolves to 0", which
	// is what this asserts, for every theme, for every role.
	bad := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		for row in ROLE_TABLE {
			v := app.theme_role(th.pal, row.role)
			if v == 0 || (v & 0xff000000) != 0 {
				bad += 1
				detail = fmt.tprintf("{} {}.{} resolved to {:08x}", detail, th.name, row.role_name, v)
			}
		}
	}
	support.check(t, "every role resolves to a real colour in every theme (never the 0 sentinel)",
		bad == 0, fmt.tprintf("{} bad resolution(s) across {} themes × {} roles{}",
			bad, app.theme_count(), app.PALETTE_ROLES, detail))
}

@(test)
role_resolution_hits_the_documented_schema_value :: proc(t: ^testing.T) {
	// The behavioural half of the table check: for every theme, the value the
	// role resolves to must equal the value the DOCUMENTED key holds in that
	// same theme. Combined with `role_table_matches_the_documented_mapping`
	// (which checks the mapping by name) this closes the loop: right key, and
	// the right value out of that key.
	bad := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		for row in ROLE_TABLE {
			// the value under the documented key name, looked up by name
			want : u32 = 0
			found := false
			for k in app.palette_keys() {
				if app.palette_key_name(k) == row.key {
					want = app.theme_slot(th.pal, k)
					found = true
				}
			}
			if !found {
				bad += 1
				detail = fmt.tprintf("{} documented key '{}' is not in the schema enum", detail, row.key)
				continue
			}
			got := app.theme_role(th.pal, row.role)
			if got != want {
				bad += 1
				detail = fmt.tprintf("{} role '{}' resolved to {:06x}, '{}' holds {:06x}",
					detail, row.role_name, got, row.key, want)
			}
		}
	}
	support.check(t, "every role resolves to the value of its documented key, in every theme",
		bad == 0, fmt.tprintf("{} mismatch(es){}", bad, detail))
}

// ── 2. the view palette is a pure function of the table ─────────────────────

@(test)
ui_palette_is_a_pure_function_of_the_role_table :: proc(t: ^testing.T) {
	// `ui.Palette` must be exactly the role table with clay colours in it:
	// field i is `clay_colour(theme_role(pal, role_i))`, for every theme. If a
	// field were mapped from anything else — a raw key, a computed blend, a
	// constant — this fails for that field.
	support.eq_i(t, "ui.Palette has one field per role", len(UI_FIELDS), app.PALETTE_ROLES)
	support.eq_i(t, "…and the role table has one row per field", len(ROLE_TABLE), len(UI_FIELDS))

	bad := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		p := ui.palette_of(th)
		for row, j in ROLE_TABLE {
			got := clay_hex(ui_field(p, int(j)))
			want := app.theme_role(th.pal, row.role) & 0xffffff
			if got != want {
				bad += 1
				detail = fmt.tprintf("{} {}.{} = {:06x} but role '{}' ({}) resolves to {:06x}",
					detail, th.name, UI_FIELDS[j], got, row.role_name, row.key, want)
			}
		}
	}
	support.check(t, "every ui.Palette field is exactly its role's resolved colour (no side doors)",
		bad == 0, fmt.tprintf("{} mismatch(es) across {} themes × {} fields{}",
			bad, app.theme_count(), app.PALETTE_ROLES, detail))
}

@(test)
every_colour_a_view_reaches_is_a_role :: proc(t: ^testing.T) {
	// "No UI element can reach a colour without going through a role" is only
	// worth reading if it is checked at the source. Scans src/ui/*.odin CODE
	// lines for `pal.<field>` references and requires every <field> to be one
	// of the 13 role fields. A widget that invented its own colour, or reached
	// past the palette into the schema, shows up here by file and line.
	root := seam_src_root()
	if len(root) == 0 {
		support.check(t, "every `pal.<field>` in src/ui/* is a role field", false,
			"src/ not found from this working directory — the scan did not run")
		return
	}
	hits := seam_walk_src(root)
	if seam_files_scanned == 0 {
		support.check(t, "every `pal.<field>` in src/ui/* is a role field", false,
			"0 files scanned — a scan over nothing is not a clean result")
		return
	}
	is_role :: proc(name: string) -> bool {
		for f in UI_FIELDS {
			if f == name { return true }
		}
		return false
	}
	scanned := 0
	violations : [dynamic]string = {}
	for h in hits {
		if !strings.has_prefix(h.file, "src/ui/") { continue }
		i := 0
		code := h.code
		for i + 4 < len(code) {
			if code[i] != 'p' || code[i+1] != 'a' || code[i+2] != 'l' || code[i+3] != '.' {
				i += 1
				continue
			}
			j := i + 4
			for j < len(code) && (is_alpha_byte(code[j]) || code[j] == '_') { j += 1 }
			name := code[i+4 : j]
			scanned += 1
			if !is_role(name) {
				append(&violations, fmt.tprintf("{}:{}: `pal.{}` is not a role field", h.file, h.line, name))
			}
			i = j
		}
	}
	support.check(t, "every `pal.<field>` in src/ui/* is one of the 13 role fields",
		scanned > 0 && len(violations) == 0,
		fmt.tprintf("{} references scanned, {} violation(s); first: {}",
			scanned, len(violations), first_or_none(violations[:])))
}

is_alpha_byte :: proc(b: u8) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

@(test)
the_deleted_roles_are_actually_gone :: proc(t: ^testing.T) {
	// The brief names what must be deleted. A comment saying they are gone is
	// not evidence; a code line containing one of those names is proof they
	// are not. Comments are stripped before matching (same discipline as
	// `hygiene_no_toml_anywhere_in_src`), so this file and the module headers
	// may discuss the removal freely.
	NEEDLES : []string = {"run_hl", "stop_hl", "theme_hl_", "theme_slot_or",
	                      "DEFAULT_PALETTE", ".accent", "header_fg", "float_bg", "float_fg"}
	root := seam_src_root()
	if len(root) == 0 {
		support.check(t, "the deleted palette members are absent from src/ code", false,
			"src/ not found — the scan did not run")
		return
	}
	hits := seam_walk_src(root)
	if seam_files_scanned == 0 {
		support.check(t, "the deleted palette members are absent from src/ code", false,
			"0 files scanned — a scan over nothing is not a clean result")
		return
	}
	bad := 0
	detail := ""
	for h in hits {
		for n in NEEDLES {
			if strings.contains(h.code, n) {
				bad += 1
				detail = fmt.tprintf("{} {}:{} contains '{}';", detail, h.file, h.line, n)
			}
		}
	}
	support.check(t, "no run_hl / stop_hl / theme_hl_* / theme_slot_or / DEFAULT_PALETTE / .accent / header_fg / float_* survives in src/ code",
		bad == 0, fmt.tprintf("{} hit(s){}", bad, detail))
}

// ── 3. the mandated verification: the state word over the highlight ────────

@(test)
state_word_over_the_highlight_clears_the_legibility_floor :: proc(t: ^testing.T) {
	// THE REQUIREMENT (RCH-12, restated without derivation).
	//
	// `running` / `stopped` keep `normal.green` / `normal.red` painted ON TOP
	// OF `selection.background`. The theme supplies the distinctness; nothing
	// here manufactures it. This test verifies the combination clears
	// THEME_LEGIBILITY_FLOOR for all ten themes, measured on the resolved
	// roles — the colours that actually hit the screen.
	//
	// There is deliberately NO fudge path: the values are the vendored ones
	// (see `theme_values_match_the_vendored_schema`), so a pass here is a
	// statement about the upstream palette, and a fail here can only be fixed
	// by changing the theme set, not by nudging a hex.
	FLOOR := app.THEME_LEGIBILITY_FLOOR
	min_run := f64(1.0e18)
	min_stop := f64(1.0e18)
	min_run_at := ""
	min_stop_at := ""
	bad := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		p := ui.palette_of(th)
		bar := clay_hex(p.sel_bg)
		run := clay_hex(p.running)
		stop := clay_hex(p.stopped)
		cr := app.theme_contrast(run, bar)
		cs := app.theme_contrast(stop, bar)
		if cr < min_run { min_run, min_run_at = cr, th.name }
		if cs < min_stop { min_stop, min_stop_at = cs, th.name }
		if cr < FLOOR || cs < FLOOR {
			bad += 1
			detail = fmt.tprintf("{} {}: running-on-bar {:.3f}, stopped-on-bar {:.3f} (floor {:.2f})",
				detail, th.name, cr, cs, FLOOR)
		}
		support.note(t, fmt.tprintf("    {} running/bar {}  stopped/bar {}",
			pad_right(th.name, 21), fmt.tprintf("{:.3f}", cr), fmt.tprintf("{:.3f}", cs)))
	}
	support.check(t, "running and stopped clear the legibility floor over selection.background — ALL themes",
		bad == 0, fmt.tprintf("{} violation(s){}", bad, detail))
	support.check(t, "…and the tightest margins are themselves above the floor",
		min_run >= FLOOR && min_stop >= FLOOR,
		fmt.tprintf("tightest running {:.3f} ({}), tightest stopped {:.3f} ({}), floor {:.2f}",
			min_run, min_run_at, min_stop, min_stop_at, FLOOR))
	support.note(t, fmt.tprintf("    tightest: running {:.3f} on {}, stopped {:.3f} on {} (floor {:.2f})",
		min_run, min_run_at, min_stop, min_stop_at, FLOOR))
}

@(test)
running_and_stopped_are_never_the_same_colour :: proc(t: ^testing.T) {
	// Identity distinctness. If a theme ever ships normal.green == normal.red,
	// no amount of role naming can keep a selected RUNNING row from looking
	// like a selected STOPPED row, and the fact has to be caught here rather
	// than inferred from a screenshot.
	same := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		p := ui.palette_of(th)
		if clay_hex(p.running) == clay_hex(p.stopped) {
			same += 1
			detail = fmt.tprintf("{} {}: running == stopped ({:06x})", detail, th.name, clay_hex(p.running))
		}
	}
	support.check(t, "running != stopped in every theme (the distinction exists to be preserved)",
		same == 0, fmt.tprintf("{} collapse(s){}", same, detail))
}

// ── 4. the findings ledger: the whole matrix, measured and pinned ──────────

Pair_Row :: struct {
	label : string,
	fg    : app.Role,
	bg    : app.Role,
}

// The pairs that matter, each measured where it is PAINTED. `text/bg` also
// covers footer_key/bg and `secondary/bg` also covers footer_desc/bg because
// the role table makes those aliases (primary.foreground and bright.black
// respectively) — which is exactly why they are measured once and the alias
// relationship is asserted by the table test above instead.
MEASURED : [15]Pair_Row = {
	{"text/bg",            .text,        .background},
	{"secondary/bg",       .secondary,   .background},
	{"hl_text/hl_bg",      .hl_text,     .hl_bg},
	{"hl_bg/bg",           .hl_bg,       .background},
	{"border/bg",          .border,      .background},
	{"running/bg",         .running,     .background},
	{"stopped/bg",         .stopped,     .background},
	{"error/bg",           .error,       .background},
	{"caret_glyph/caret_bg", .caret_glyph, .caret_bg},
	{"caret_bg/bg",        .caret_bg,    .background},
	{"running/hl_bg",      .running,     .hl_bg},
	{"stopped/hl_bg",      .stopped,     .hl_bg},
	{"running/hl_text",    .running,     .hl_text},
	{"stopped/hl_text",    .stopped,     .hl_text},
	{"running/stopped",    .running,     .stopped},
}

// FINDINGS: every (theme, pair) that measures below THEME_LEGIBILITY_FLOOR
// under the strict mapping, with the measured ratio recorded alongside. These
// are NOT accepted because they pass — they are REPORTED because the values
// are upstream's and adjusting them is forbidden.
//
// The two worst entries are the pair of 1.000s: in solarized-dark
// `bright.black` IS `primary.background` (#002b36), so every piece of
// secondary text — column headers, placeholders, footer descriptions — is
// the page colour; and in solarized-light `bright.white` IS
// `primary.background` (#fdf6e3), so the between-children rules are
// invisible. Those are not exaggerations, they are the arithmetic.
Finding :: struct {
	theme : string,
	pair  : string,
	measured : f64,
	note  : string,
}

LEDGER : [36]Finding = {
	{"gruvbox-dark", "running/stopped", 1.766, "normal.green vs normal.red is carried by HUE; WCAG luminance ratio is the wrong instrument and the strict mapping does not fix that"},
	{"gruvbox-light", "running/stopped", 1.766, "normal.green vs normal.red is carried by HUE; WCAG luminance ratio is the wrong instrument and the strict mapping does not fix that"},
	{"catppuccin-latte", "hl_bg/bg", 1.235, "selection.background is a near-tone tint of the page on this theme"},
	{"catppuccin-latte", "border/bg", 1.608, "bright.white is at/near the page colour: the between-children rule is faint or invisible"},
	{"catppuccin-latte", "running/stopped", 1.624, "normal.green vs normal.red is carried by HUE; WCAG luminance ratio is the wrong instrument and the strict mapping does not fix that"},
	{"catppuccin-latte", "stopped/hl_text", 1.471, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"catppuccin-frappe", "hl_bg/bg", 1.382, "selection.background is a near-tone tint of the page on this theme"},
	{"catppuccin-frappe", "running/stopped", 1.527, "normal.green vs normal.red is carried by HUE; WCAG luminance ratio is the wrong instrument and the strict mapping does not fix that"},
	{"catppuccin-frappe", "running/hl_text", 1.135, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"catppuccin-frappe", "stopped/hl_text", 1.734, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"catppuccin-macchiato", "hl_bg/bg", 1.398, "selection.background is a near-tone tint of the page on this theme"},
	{"catppuccin-macchiato", "running/stopped", 1.538, "normal.green vs normal.red is carried by HUE; WCAG luminance ratio is the wrong instrument and the strict mapping does not fix that"},
	{"catppuccin-macchiato", "running/hl_text", 1.081, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"catppuccin-macchiato", "stopped/hl_text", 1.663, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"catppuccin-mocha", "hl_bg/bg", 1.399, "selection.background is a near-tone tint of the page on this theme"},
	{"catppuccin-mocha", "running/stopped", 1.557, "normal.green vs normal.red is carried by HUE; WCAG luminance ratio is the wrong instrument and the strict mapping does not fix that"},
	{"catppuccin-mocha", "running/hl_text", 1.028, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"catppuccin-mocha", "stopped/hl_text", 1.601, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"tokyonight-night", "secondary/bg", 1.914, "bright.black is at or near the page colour: headers, placeholders and footer descriptions suffer"},
	{"tokyonight-night", "hl_bg/bg", 1.399, "selection.background is a near-tone tint of the page on this theme"},
	{"tokyonight-night", "running/stopped", 1.448, "normal.green vs normal.red is carried by HUE; WCAG luminance ratio is the wrong instrument and the strict mapping does not fix that"},
	{"tokyonight-night", "running/hl_text", 1.132, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"tokyonight-night", "stopped/hl_text", 1.639, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"nord", "secondary/bg", 1.693, "bright.black is at or near the page colour: headers, placeholders and footer descriptions suffer"},
	{"nord", "hl_bg/bg", 1.340, "selection.background is a near-tone tint of the page on this theme"},
	{"nord", "running/hl_text", 1.509, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"solarized-dark", "secondary/bg", 1.000, "bright.black is at or near the page colour: headers, placeholders and footer descriptions suffer"},
	{"solarized-dark", "hl_bg/bg", 1.155, "selection.background is a near-tone tint of the page on this theme"},
	{"solarized-dark", "running/stopped", 1.443, "normal.green vs normal.red is carried by HUE; WCAG luminance ratio is the wrong instrument and the strict mapping does not fix that"},
	{"solarized-dark", "running/hl_text", 1.198, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"solarized-dark", "stopped/hl_text", 1.730, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"solarized-light", "hl_bg/bg", 1.136, "selection.background is a near-tone tint of the page on this theme"},
	{"solarized-light", "border/bg", 1.000, "bright.white is at/near the page colour: the between-children rule is faint or invisible"},
	{"solarized-light", "running/stopped", 1.443, "normal.green vs normal.red is carried by HUE; WCAG luminance ratio is the wrong instrument and the strict mapping does not fix that"},
	{"solarized-light", "running/hl_text", 1.680, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
	{"solarized-light", "stopped/hl_text", 1.164, "the state word is close to the bar TEXT colour in luminance (hue still separates them)"},
}

@(test)
role_contrast_matrix_is_recorded :: proc(t: ^testing.T) {
	// Measures every pair in MEASURED for every theme, prints the whole
	// matrix, and asserts the set of sub-floor results is EXACTLY LEDGER.
	//
	// Both directions are enforced. A new violation fails with its numbers. A
	// violation that stopped being true also fails, because it means the
	// shipped hex changed — and under a schema mirror the hex only changes when
	// somebody re-vendored it, which is a deliberate act that must land with
	// an updated ledger, not a quiet edit to make a green screen.
	FLOOR := app.THEME_LEGIBILITY_FLOOR

	got : [dynamic]string = {}
	defer delete(got)
	missing : [dynamic]string = {}
	defer delete(missing)
	stale : [dynamic]string = {}
	defer delete(stale)

	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		p := ui.palette_of(th)
		line := fmt.tprintf("    {}", pad_right(th.name, 21))
		for pr in MEASURED {
			a := clay_hex(ui_field(p, role_index_in_palette(pr.fg)))
			b := clay_hex(ui_field(p, role_index_in_palette(pr.bg)))
			r := app.theme_contrast(a, b)
			line = fmt.tprintf("{} {}: {}", line, pad_right(pr.label, 21), fmt.tprintf("{:.3f}", r))
			if r < FLOOR {
				append(&got, fmt.tprintf("{}|{}", th.name, pr.label))
			}
		}
		support.note(t, line)
	}

	// Build the recorded set.
	want_count := len(LEDGER)
	extra := 0
	for g in got {
		found := false
		for L in LEDGER {
			if L.theme == theme_part(g) && L.pair == pair_part(g) { found = true }
		}
		if !found {
			extra += 1
			append(&missing, fmt.tprintf("NOT RECORDED: {}", g))
		}
	}
	// and the reverse: every ledger entry must still be failing
	for L in LEDGER {
		still := false
		for g in got {
			if g == fmt.tprintf("{}|{}", L.theme, L.pair) { still = true }
		}
		if !still {
			append(&stale, fmt.tprintf("NO LONGER FAILING (was {:.3f}): {}/{}", L.measured, L.theme, L.pair))
		}
	}

	support.check(t, "the set of below-floor role pairs is EXACTLY the recorded findings ledger",
		extra == 0 && len(stale) == 0,
		fmt.tprintf("{} measured below floor, {} recorded; unrecorded={}, stale={}",
			len(got), want_count, extra, len(stale)))
	for m in missing { support.note(t, fmt.tprintf("      {}", m)) }
	for s in stale { support.note(t, fmt.tprintf("      {}", s)) }
}

theme_part :: proc(s: string) -> string {
	i := strings.index(s, "|")
	if i < 0 { return s }
	return s[:i]
}

pair_part :: proc(s: string) -> string {
	i := strings.index(s, "|")
	if i < 0 { return "" }
	return s[i+1:]
}

// role_index_in_palette maps a Role to its index in UI_FIELDS, which is the
// same order as ROLE_TABLE. Keeping it a lookup over the two tables rather than
// a hardcoded map means there is still one source of ordering.
role_index_in_palette :: proc(r: app.Role) -> int {
	for row, i in ROLE_TABLE {
		if row.role == r { return int(i) }
	}
	return 0
}

@(test)
ledger_measured_values_match_the_recorded_ratios :: proc(t: ^testing.T) {
	// The ledger records a number per finding, not just a name. Recompute
	// each one and require it to still round to the recorded value. This is
	// the check that catches "the set is the same but someone nudged a hex by
	// one and nobody looked".
	FLOOR := app.THEME_LEGIBILITY_FLOOR
	bad := 0
	detail := ""
	for L in LEDGER {
		th, ok := app.theme_named(L.theme)
		if !ok {
			bad += 1
			detail = fmt.tprintf("{} ledger names an unshipped theme '{}';", detail, L.theme)
			continue
		}
		p := ui.palette_of(th)
		row := pair_row_for(L.pair)
		if row == nil {
			bad += 1
			detail = fmt.tprintf("{} ledger pair '{}' is not in MEASURED;", detail, L.pair)
			continue
		}
		a := clay_hex(ui_field(p, role_index_in_palette(row^.fg)))
		b := clay_hex(ui_field(p, role_index_in_palette(row^.bg)))
		got := app.theme_contrast(a, b)
		// two-decimal agreement: 0.005 tolerance
		diff := got - L.measured
		if diff < 0 { diff = -diff }
		if diff > 0.005 {
			bad += 1
			detail = fmt.tprintf("{} {} / {}: recorded {:.3f}, measured {:.3f}",
				detail, L.theme, L.pair, L.measured, got)
		}
		if got >= FLOOR {
			bad += 1
			detail = fmt.tprintf("{} {} / {}: measured {:.3f} but the ledger lists it as BELOW floor {:.2f}",
				detail, L.theme, L.pair, got, FLOOR)
		}
	}
	support.check(t, "every ledger entry's recorded ratio still measures as recorded",
		bad == 0, fmt.tprintf("{} mismatch(es){}", bad, detail))
}

pair_row_for :: proc(label: string) -> ^Pair_Row {
	for i in 0..<len(MEASURED) {
		if MEASURED[i].label == label { return &MEASURED[i] }
	}
	return nil
}
