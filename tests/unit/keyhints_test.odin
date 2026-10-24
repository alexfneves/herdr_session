package unit

// ============================================================================
// keyhints_test.odin — the footer hint tables, and the footer's UNIT FORMAT.
//
// T2 re-homed the seven KEYS_* tables and the state dispatcher out of
// `package main` into src/ui/keyhints.odin. Same reason as diag_head: while
// they lived in main they were unreachable from tests/, and the footer-width
// proofs that depend on them would otherwise have been deleted rather than
// ported.
//
// UIP-5 (RCH-10 changes 7 + 8 + 9) changed what a hint LOOKS like, and this
// file changed with it rather than being lowered to fit:
//
//   * THE UNIT INVERTED (AD-1). `r new remote` is now `New remote: r`:
//     description first, key second, units joined by ` | `. Colour and format
//     land together — the spans ARE the footer (`ui.footer_spans`) and
//     `ui.keys_line` is the plain-text projection of those same spans, so a
//     line and its colours cannot describe different text.
//   * THE DESCRIPTIONS ARE NEW (AD-2). Per-shortcut display strings, never
//     derived from RCH-9's state label. `keyhints_every_hint_is_a_display_unit`
//     asserts the shape and that every description reads as a display string,
//     which is what makes "still the old lowercase verb" red.
//   * EVERY WIDTH MOVED (AD-3). A join is 3 cells where SEP was 2, the
//     front-cut marker is 4, and the units themselves are different lengths.
//     Nothing below is inherited from the old sweep: the survival point of
//     every hint is RE-DERIVED from the product's own width helpers and
//     asserted as a biconditional — the hint is on the line IF AND ONLY IF
//     the width can hold it.
//
// THE ORDER OF A TABLE IS CONTRACT, NOT STYLE. `keys_line` keeps the exit hint
// and fills from the exit-hint side, cutting from the front when the footer
// runs out of room. So the LAST entry of every table is "how you get out", and
// these tests pin that. Reordering a table is a product change to what
// survives a narrow terminal. THE RETENTION POLICY IS NOT RE-LIT HERE — AD-1
// did not change it; it changed the size of the atoms the rule counts, which
// is exactly why the sweep was re-derived instead of reused.
// ============================================================================

import "core:fmt"
import "core:testing"

import clay "../../clay-odin"
import render "../../src/render"
import app "../../src/app"
import tb "../../vendor/termbox2-odin"
import ui "../../src/ui"
import support "../support"

// The dispatcher must cover EVERY value of app.State, named explicitly here.
//
// key_hints_for uses a #partial switch, so a NEW state is a compile error --
// good -- but a state that silently falls through to the KEYS_MODE fallback is
// not. Naming each state in the test is what makes "we added a mode and its
// footer is wrong" a red assertion rather than a footer that shows the wrong
// keys until a human notices. This is also why `app` is imported: the test
// asserts against the product's own enum, not a list the test invented.
@(test)
keyhints_covers_every_declared_app_state :: proc(t: ^testing.T) {
	states : []app.State = {
		app.State.mode_selection,
		app.State.name_local,
		app.State.remote_server,
		app.State.name_remote_named,
		app.State.attach,
		app.State.delete_session,
		app.State.theme,
		app.State.error,
	}
	missing := ""
	for st in states {
		if len(ui.key_hints_for(st)) == 0 {
			if missing == "" { missing = fmt.tprintf("{}", st) }
			else { missing = fmt.tprintf("{}, {}", missing, st) }
		}
	}
	support.check(t, "every declared app.State yields a usable hint table",
		missing == "", fmt.tprintf("states with no hints: '{}'", missing))

	// And every declared table's state is one the dispatcher knows about, so
	// the two lists cannot drift apart in either direction.
	declared := 0
	for th in ui.all_hint_tables() {
		found := false
		for st in states { if st == th.state { found = true; break } }
		support.check(t, fmt.tprintf("table '{}' declares a state the dispatcher knows", th.name),
			found, "")
		declared += 1
	}
	support.eq_i(t, "the number of declared tables equals the number of app.States",
		declared, len(states))
}

// every state dispatches to a non-empty table
@(test)
keyhints_every_state_returns_a_nonempty_table :: proc(t: ^testing.T) {
	tables := ui.all_hint_tables()
	empty := ""
	n : int = 0
	for th in tables {
		n += 1
		if len(th.hints) == 0 {
			if empty == "" { empty = th.name } else { empty = fmt.tprintf("{}, {}", empty, th.name) }
		}
	}
	support.check(t, "every state's hint table is non-empty", n > 0 && empty == "",
		fmt.tprintf("{} tables checked, empty: '{}'", n, empty))
}

// the dispatcher agrees with the declared table for every state
@(test)
keyhints_dispatcher_matches_the_declared_table :: proc(t: ^testing.T) {
	mismatch := ""
	n : int = 0
	for th in ui.all_hint_tables() {
		n += 1
		got := ui.key_hints_for(th.state)
		if len(got) != len(th.hints) {
			mismatch = fmt.tprintf("{} len {} vs {}", th.name, len(got), len(th.hints))
			break
		}
		for i := 0; i < len(got); i += 1 {
			if got[i].key != th.hints[i].key || got[i].action != th.hints[i].action {
				mismatch = fmt.tprintf("{}[{}]={}/{} declared {}/{}",
					th.name, i, got[i].key, got[i].action,
					th.hints[i].key, th.hints[i].action)
				break
			}
		}
	}
	support.check(t, "key_hints_for returns exactly the declared table, per state",
		n > 0 && mismatch == "",
		fmt.tprintf("{} states checked, first mismatch: '{}'", n, mismatch))
}

// no table lists the same key twice: two rows for one key means the footer
// advertises two different actions for a single press.
@(test)
keyhints_no_duplicate_key_label :: proc(t: ^testing.T) {
	dups := ""
	for th in ui.all_hint_tables() {
		for i := 0; i < len(th.hints); i += 1 {
			for j := i + 1; j < len(th.hints); j += 1 {
				if th.hints[i].key == th.hints[j].key {
					dup := fmt.tprintf("{}: '{}' twice", th.name, th.hints[i].key)
					if dups == "" { dups = dup } else { dups = fmt.tprintf("{}, {}", dups, dup) }
				}
			}
		}
	}
	support.check(t, "no table advertises the same key twice", dups == "",
		fmt.tprintf("duplicates: '{}'", dups))
}

// THE ORDER CONTRACT: the last hint is always the exit/quit hint.
@(test)
keyhints_exit_hint_is_last_in_every_table :: proc(t: ^testing.T) {
	bad := ""
	for th in ui.all_hint_tables() {
		if len(th.hints) == 0 { continue }
		last := th.hints[len(th.hints)-1]
		if !is_exit_action(last.action) {
			d := fmt.tprintf("{} last='{}'", th.name, kh_unit(last))
			if bad == "" { bad = d } else { bad = fmt.tprintf("; {}", bad, d) }
		}
	}
	support.check(t,
		"every table's LAST hint is an exit/back/dismiss action (keys_line fills from that side)",
		bad == "", fmt.tprintf("offenders: '{}'", bad))
}

// ── AD-1 / AD-2: what one unit IS ───────────────────────────────────────
//
// Every hint, in every table, must render as `Description: key`, built out of
// exactly three spans (desc / ": " / key) so each piece's colour is decided by
// its KIND and not by whoever assembled a string.
//
// The expectation is built HERE out of the hint's own fields with a local
// concatenation, rather than by calling the product's formatter and comparing
// it to itself. If `footer_unit_text` changes shape, this goes red.
@(test)
keyhints_every_hint_is_a_display_unit :: proc(t: ^testing.T) {
	bad_shape := ""
	bad_spans := ""
	not_display := ""
	checked := 0
	for th in ui.all_hint_tables() {
		for k in th.hints {
			checked += 1
			want := kh_cat3(k.action, ": ", k.key)
			got := ui.footer_unit_text(k)
			if got != want {
				kh_first(&bad_shape, fmt.tprintf("{} want '{}' got '{}'", th.name, want, got))
			}
			// The OLD pattern was `key action`. If the inversion ever regressed
			// back to that, the unit would start with the key.
			if kh_starts_with(got, k.key) && got != want {
				kh_first(&bad_shape, fmt.tprintf("{} back in `key action` order: '{}'", th.name, got))
			}
			// AD-2: a display string — capitalised, and the thing before the
			// colon is the description, not the key.
			if !kh_starts_upper(k.action) {
				kh_first(&not_display, fmt.tprintf("{} '{}' is not a display description",
					th.name, k.action))
			}

			// The three spans, in the three kinds, with the right text in each.
			one : [1]ui.Key_Hint = {k}
			spans := ui.footer_spans(one[:], ui.NO_LIMIT)
			bad := len(spans) != 3 ||
				spans[0].kind != ui.Footer_Span_Kind.desc || spans[0].text != k.action ||
				spans[1].kind != ui.Footer_Span_Kind.sep || spans[1].text != ": " ||
				spans[2].kind != ui.Footer_Span_Kind.key || spans[2].text != k.key
			if bad {
				kh_first(&bad_spans, fmt.tprintf("{} '{}' -> [{}]", th.name, want, kh_kind_names(spans[:])))
			}
			delete(spans)
		}
	}
	support.check(t, "every hint renders as `Description: key`", checked > 0 && bad_shape == "",
		fmt.tprintf("{} hints checked, first bad shape: '{}'", checked, bad_shape))
	support.check(t, "and every unit is desc / ': ' / key spans, in that order",
		bad_spans == "", fmt.tprintf("first offender: '{}'", bad_spans))
	support.check(t, "and every description is a display string, not the old lowercase verb",
		not_display == "", fmt.tprintf("first offender: '{}'", not_display))
}

// The colour each kind gets, from the ONE mapping the footer uses. This does
// not re-prove the palette is good — tests/unit/theme_roles_uip2_test.odin
// measures WCAG contrast per theme, including key_fg >= 4.5 on the page while
// desc_fg is held at 2.7 and at least 1.5x quieter. What this proves is that
// the footer asks for the DOMINANT role on the key and the MUTED role on the
// description, for every shipped theme, and that the two are not one colour
// wearing two names.
@(test)
keyhints_span_kinds_map_to_the_dominant_and_muted_roles :: proc(t: ^testing.T) {
	n := app.theme_count()
	support.check(t, "the sweep covers every shipped theme", n > 0,
		fmt.tprintf("app.theme_count() = {}", n))
	wrong := 0
	undominated := 0
	detail := ""
	for i := 0; i < n; i += 1 {
		th := app.theme_at(i)
		pal := ui.palette_of(th)
		key := ui.footer_span_fg(&pal, .key)
		desc := ui.footer_span_fg(&pal, .desc)
		sep := ui.footer_span_fg(&pal, .sep)
		if !kh_col_eq(key, pal.key_fg) || !kh_col_eq(desc, pal.desc_fg) || !kh_col_eq(sep, pal.dim) {
			wrong += 1
			detail = fmt.tprintf("{} {}", detail, th.name)
			continue
		}
		// AD-1.2 — if key_fg and desc_fg were the same value the footer could
		// not make the key dominant no matter how it painted.
		if kh_col_eq(key, desc) {
			undominated += 1
			detail = fmt.tprintf("{} {} (key_fg == desc_fg)", detail, th.name)
		}
	}
	support.check(t, "the footer paints keys key_fg, descriptions desc_fg, punctuation dim",
		wrong == 0, fmt.tprintf("{} wrong-role theme(s):{}{}", wrong, "", detail))
	support.check(t, "and no theme gives the key and its description one colour",
		undominated == 0, fmt.tprintf("{} undominated theme(s){}", undominated, detail))
}

// ── AD-3: the width sweep, RE-DERIVED ───────────────────────────────────
//
// The old sweep asked, against a hardcoded OLD-format width, whether `t theme`
// was still on the line. That question is stale: the units changed length, the
// join went 2 cells -> 3, the front-cut marker 3 -> 4. So the survival point of
// EVERY hint is recomputed here from the product's own width helpers and
// asserted as a biconditional — a hint appearing that should have been cut
// fails as surely as one vanishing that should have survived.
@(test)
keyhints_mode_survival_set_is_exactly_what_the_width_holds :: proc(t: ^testing.T) {
	widths : [8]int = {120, 100, 80, 60, 40, 30, 20, 10}
	ks := ui.KEYS_MODE[:]
	for w in widths {
		line := ui.keys_line(ks, i32(w))
		pieces := kh_split(line, ui.SEP)
		want := kh_expected_kept(ks, i32(w))
		got := kh_visible_units(pieces[:], ks)
		mark := kh_marker_shown(pieces[:])
		support.check(t, fmt.tprintf("KEYS_MODE at {} cols keeps exactly {} unit(s)", w, len(want)),
			kh_same_units(got[:], want[:]),
			fmt.tprintf("width={} want=[{}] got=[{}] line='{}'",
				w, kh_join_units(want[:]), kh_join_units(got[:]), line))
		// And the pieces the separator reveals are exactly those units plus,
		// when something was cut, the single `…` head — which is what makes
		// the marker's interaction with the split explicit rather than implied.
		support.check(t, fmt.tprintf("KEYS_MODE at {} cols: pieces == units + marker", w),
			len(pieces) == len(got) + (mark ? 1 : 0),
			fmt.tprintf("pieces={} units={} marker={} line='{}'", len(pieces), len(got), mark, line))
		delete(pieces)
		delete(want)
		delete(got)
	}
}

// THE WIDTH CONTRACT, re-homed from src/ui_cases.odin:505-532 and re-derived
// for the inverted unit.
//
// KEYS_MODE is 8 units / 128 cells at the new widths, so at 120 and below the
// footer MUST cut. What must survive is the exit unit and, above its own
// derived threshold, `Theme: t`.
@(test)
keyhints_mode_table_survives_the_width_sweep :: proc(t: ^testing.T) {
	widths : [8]int = {120, 100, 80, 60, 40, 30, 20, 10}
	ks := ui.KEYS_MODE[:]
	theme := ks[len(ks)-2]
	last := ks[len(ks)-1]
	// The theme hint's crossing point, derived: its unit, the join to the exit
	// unit, the exit unit, plus the front-cut marker (paid for because hints
	// still sit to its left). Nothing here is a remembered number.
	need := kh_min_width(ks, len(ks)-2)
	theme_unit := kh_unit(theme)
	exit_unit := kh_unit(last)
	for w in widths {
		line := ui.keys_line(ks, i32(w))
		n := int(ui.text_cols(line))

		// the exit hint is what you are promised last and must be kept first
		support.check(t, fmt.tprintf("KEYS_MODE at {} cols still shows the exit hint", w),
			w < int(ui.footer_unit_cols(last)) || strings_contains(line, exit_unit),
			fmt.tprintf("exit unit='{}' footer='{}'", exit_unit, line))

		// `Theme: t` is guarded by its own derived threshold, not a literal
		// carried over from the `key action` format.
		support.check(t, fmt.tprintf("KEYS_MODE at {} cols shows `Theme: t` iff max >= {}", w, need),
			(w >= int(need)) == strings_contains(line, theme_unit),
			fmt.tprintf("need={} visible={} got='{}'", need, strings_contains(line, theme_unit), line))

		support.check(t, fmt.tprintf("KEYS_MODE at {} cols never overflows", w),
			n <= w, fmt.tprintf("cols={} line='{}'", n, line))

		support.check(t, fmt.tprintf("KEYS_MODE at {} cols cuts no unit in half", w),
			kh_no_half_unit(line),
			fmt.tprintf("partial line='{}'", line))

		support.check(t, fmt.tprintf("KEYS_MODE at {} cols is not blank", w),
			line != "", fmt.tprintf("footer = '{}'", line))
	}
}

// Every table, every width: the exit unit is present whenever the width can
// physically hold it, nothing overflows, nothing is half a unit, nothing is
// blank, and the cut marker only ever heads the line. This covers ALL SEVEN
// tables rather than only the mode table, because the never-blank rule and the
// exit-hint promise are made about every state — and 40 columns (MIN_COLS,
// src/terminal/resize.odin:56) is in the sweep.
@(test)
keyhints_every_table_honours_the_width_contract :: proc(t: ^testing.T) {
	widths : [8]int = {120, 100, 80, 60, 40, 30, 20, 10}
	lost := ""
	over := ""
	half := ""
	blank := ""
	misplaced := ""
	double := ""
	tables := ui.all_hint_tables()
	n_tables := 0
	for th in tables {
		n_tables += 1
		for w in widths {
			ks := th.hints
			line := ui.keys_line(ks, i32(w))
			last := ks[len(ks)-1]
			exit_unit := kh_unit(last)
			if w >= int(ui.footer_unit_cols(last)) && !strings_contains(line, exit_unit) {
				kh_first(&lost, fmt.tprintf("{} at {} cols: exit unit '{}' missing from '{}'",
					th.name, w, exit_unit, line))
			}
			if ui.text_cols(line) > i32(w) {
				kh_first(&over, fmt.tprintf("{} at {} cols: '{}' is {} cells",
					th.name, w, line, ui.text_cols(line)))
			}
			if !kh_no_half_unit(line) {
				kh_first(&half, fmt.tprintf("{} at {} cols: half unit in '{}'", th.name, w, line))
			}
			if line == "" {
				kh_first(&blank, fmt.tprintf("{} at {} cols: blank footer", th.name, w))
			}
			// No footer line may contain a run of two spaces. This is not
			// cosmetic: the pre-migration no-half check in src/ui_cases.odin
			// splits the line on `  ` (two spaces). ` | ` is one space, pipe,
			// one space, so the projection never contains a double space and
			// that older check keeps slicing at unit boundaries instead of inside
			// a unit. A description that ever carried a double space would break
			// it, and this is where that shows up first.
			if strings_contains(line, "  ") {
				kh_first(&double, fmt.tprintf("{} at {} cols: '{}' contains a double space", th.name, w, line))
			}
			pieces := kh_split(line, ui.SEP)
			for j := 0; j < len(pieces); j += 1 {
				if pieces[j] == ui.CUT_MARKER && j != 0 {
					kh_first(&misplaced, fmt.tprintf("{} at {} cols: marker at piece {} of '{}'",
						th.name, w, j, line))
				}
			}
			delete(pieces)
		}
	}
	support.check(t, "all seven tables keep the exit unit at every width that fits it",
		n_tables > 0 && lost == "", fmt.tprintf("first loss: '{}'", lost))
	support.check(t, "and none overflows its width at any of the 8 widths", over == "",
		fmt.tprintf("first overflow: '{}'", over))
	support.check(t, "and none shows a half unit at any width", half == "",
		fmt.tprintf("first half: '{}'", half))
	support.check(t, "and none goes blank while it has hints", blank == "",
		fmt.tprintf("first blank: '{}'", blank))
	support.check(t, "and the front-cut marker only ever heads the line", misplaced == "",
		fmt.tprintf("first misplaced marker: '{}'", misplaced))
	support.check(t, "and no footer line contains a double space (the legacy split boundary)",
		double == "", fmt.tprintf("first offender: '{}'", double))
}

// THE FALSIFIABILITY OF THE PREDICATE ITSELF.
//
// A truncation check that cannot fail is worse than no check, so the predicate
// is fed, one by one, the exact halves it exists to catch. Each of these lines
// LOOKS like a plausible footer fragment — that is what makes them the bug.
@(test)
keyhints_half_unit_predicate_falsifies :: proc(t: ^testing.T) {
	// A unit cut just after the colon: description and separator, no key.
	support.check(t, "the predicate FAILS on a description whose key was cut off",
		!kh_no_half_unit("Attach: "), fmt.tprintf("kh_half_unit_count('Attach: ')={}", kh_half_unit_count("Attach: ")))
	support.check(t, "the predicate FAILS on a bare 'Attach:'",
		!kh_no_half_unit("Attach:"), fmt.tprintf("kh_half_unit_count('Attach:')={}", kh_half_unit_count("Attach:")))
	// A bare key: the description is what went missing.
	support.check(t, "the predicate FAILS on a bare key",
		!kh_no_half_unit("a"), fmt.tprintf("kh_half_unit_count('a')={}", kh_half_unit_count("a")))
	// A unit sliced mid-description, joined to a whole unit.
	support.check(t, "the predicate FAILS on a unit sliced mid-word",
		!kh_no_half_unit("New rem | Quit: esc"),
		fmt.tprintf("kh_half_unit_count('New rem | Quit: esc')={}", kh_half_unit_count("New rem | Quit: esc")))
	// An ellipsised unit: this `…` trails the text, it is not the cut marker.
	support.check(t, "the predicate FAILS on an ellipsised unit",
		!kh_no_half_unit("Quit:…"), fmt.tprintf("kh_half_unit_count('Quit:…')={}", kh_half_unit_count("Quit:…")))
	// A whole unit glued to a fragment on its right.
	support.check(t, "the predicate FAILS when the fragment is on the right",
		!kh_no_half_unit("Theme: t | At"),
		fmt.tprintf("kh_half_unit_count('Theme: t | At')={}", kh_half_unit_count("Theme: t | At")))
	// The positives, so the predicate is not simply always-false.
	support.check(t, "the predicate PASSES a whole unit",
		kh_no_half_unit("New remote: r"), "rejected a whole unit")
	support.check(t, "the predicate PASSES the marker plus whole units",
		kh_no_half_unit("… | Theme: t | Quit: esc"), "rejected a marked line")
	// The marker is legal ONLY as a piece of its own. Glued to a unit it is
	// not the marker any more — which is precisely why footer_spans emits it
	// as its own span followed by its own separator.
	support.check(t, "the marker counts only as its own piece, not glued to text",
		kh_marker_only("… | Quit: esc") && !kh_marker_only("…Quit: esc | Quit: esc"),
		fmt.tprintf("marker_only('… | Quit: esc')={} marker_only('…Quit: esc | …')={}",
			kh_marker_only("… | Quit: esc"), kh_marker_only("…Quit: esc | Quit: esc")))
}

// The footer's plain-text projection must be free of format garbage. This
// project has a live, known `%!(EXTRA …)` failure in another suite; the
// footer's answer is that it never touches a format string at all — units are
// concatenated spans. This sweeps every table at every width for the `%!`
// sequence so a regression cannot hide behind "my tprintf template is safe".
@(test)
keyhints_footer_output_has_no_format_garbage :: proc(t: ^testing.T) {
	widths : [8]int = {120, 100, 80, 60, 40, 30, 20, 10}
	dirty := ""
	n := 0
	for th in ui.all_hint_tables() {
		for w in widths {
			n += 1
			line := ui.keys_line(th.hints, i32(w))
			if strings_contains(line, "%!") || strings_contains(line, "%(") {
				kh_first(&dirty, fmt.tprintf("{} at {} cols: '{}'", th.name, w, line))
			}
		}
	}
	support.check(t, "no footer line contains %! or %( at any width of any table",
		n > 0 && dirty == "", fmt.tprintf("{} lines swept, first offender: '{}'", n, dirty))
}

// ── THE PAINTED PROOF ───────────────────────────────────────────────────
//
// Everything above proves the spans CARRY the right kinds. This proves the
// renderer PAINTED them that way, read back out of termbox's BACK buffer the
// same way the caret (UIP-4) and selection (UIP-3) tests do — what the
// renderer decided, not what was asked for. Each span occupies a known run of
// columns, so a swap of the key and description roles shows up as the wrong
// colour at a known x, in every shipped theme.
@(test)
keyhints_footer_paints_key_cells_in_key_fg :: proc(t: ^testing.T) {
	if !render_session(t, "keyhints-footer-paint") { return }
	n := app.theme_count()
	support.check(t, "the paint sweep covers every shipped theme", n > 0,
		fmt.tprintf("app.theme_count() = {}", n))

	ks := ui.KEYS_MODE[:]
	room : i32 = RENDER_COLS - 2
	wrong_key := 0
	wrong_desc := 0
	indistinct := 0
	detail := ""
	for i := 0; i < n; i += 1 {
		th := app.theme_at(i)
		pal := ui.palette_of(th)
		kh_paint_footer(ks, room, &pal)
		key_want := kh_attr(pal.key_fg)
		desc_want := kh_attr(pal.desc_fg)
		spans := ui.footer_spans(ks, room)
		x : i32 = 0
		for s in spans {
			w := ui.text_cols(s.text)
			if w == 0 { continue }
			cell := render_cell_at(x, 0)
			if s.kind == ui.Footer_Span_Kind.key && cell.fg != key_want {
				wrong_key += 1
				kh_first(&detail, fmt.tprintf("{} key '{}' at x={} fg=0x{:08X} want 0x{:08X}",
					th.name, s.text, x, u32(cell.fg), u32(key_want)))
			}
			if s.kind == ui.Footer_Span_Kind.desc && cell.fg != desc_want {
				wrong_desc += 1
				kh_first(&detail, fmt.tprintf("{} desc '{}' at x={} fg=0x{:08X} want 0x{:08X}",
					th.name, s.text, x, u32(cell.fg), u32(desc_want)))
			}
			x += w
		}
		delete(spans)
		// "The key is dominant" has to be something a screen shows. If both
		// roles mapped to one terminal attribute the footer would paint a
		// monotone line no matter which role it asked for.
		if key_want == desc_want {
			indistinct += 1
			kh_first(&detail, fmt.tprintf("{} key and desc collapse to one attribute 0x{:08X}",
				th.name, u32(key_want)))
		}
	}
	support.check(t, "every key span paints with key_fg, in every theme", wrong_key == 0,
		fmt.tprintf("{} wrong key cell(s); {}", wrong_key, detail))
	support.check(t, "every description span paints with desc_fg, in every theme", wrong_desc == 0,
		fmt.tprintf("{} wrong desc cell(s); {}", wrong_desc, detail))
	support.check(t, "and the key is visibly distinct from its description", indistinct == 0,
		fmt.tprintf("{} indistinct theme(s); {}", indistinct, detail))

	render_dump_rows(t, "footer units (key in key_fg, description in desc_fg)", 0, 0, 60, 1)
}

// The inventory this task's report is generated from: the new unit width per
// hint, and the width at which each hint stops being cut. Printed, because a
// number that only exists inside a passing assertion is not evidence a human
// can review.
@(test)
keyhints_unit_width_inventory :: proc(t: ^testing.T) {
	support.note_raw(t, "  keyhints — unit widths (Description: key) and survival points")
	tables := ui.all_hint_tables()
	rows := 0
	for th in tables {
		for i := 0; i < len(th.hints); i += 1 {
			k := th.hints[i]
			minw := kh_min_width(th.hints, i)
			// Plain values, joined by hand — no format template. The first
			// version of this line used `{:<12}` pad syntax, which Odin's fmt
			// does not have: it compiled, printed `%!(MISSING CLOSE BRACE)`, and
			// dumped the real values into an `%!(EXTRA …)` tail. That is the
			// exact bug class the footer is built to make unreachable, showing up
			// in the footer's own report. Never again from a template.
			support.note_raw(t, kh_join_str({
				"    ", th.name,
				"  key=", k.key,
				"  unit=", kh_i32(ui.footer_unit_cols(k)),
				"  on the line at max >= ", kh_i32(minw),
				"  '", kh_unit(k), "'",
			}))
			rows += 1
		}
	}
	support.eq_i(t, "the inventory covered every hint of every declared table",
		rows, kh_total_hints(tables[:]))
}

//-----------------------------------------------------------------------------
// local predicates
//-----------------------------------------------------------------------------

is_exit_action :: proc(a: string) -> bool {
	low := kh_lower(a)
	return strings_contains(low, "quit") || strings_contains(low, "back") ||
		strings_contains(low, "dismiss")
}

strings_contains :: proc(hay, needle: string) -> bool {
	if len(needle) == 0 { return true }
	if len(needle) > len(hay) { return false }
	for i := 0; i + len(needle) <= len(hay); i += 1 {
		match := true
		for k := 0; k < len(needle); k += 1 {
			if hay[i+k] != needle[k] { match = false; break }
		}
		if match { return true }
	}
	return false
}

// kh_no_half_unit — the footer's integrity predicate for the ` | ` format.
//
// THE OLD PREDICATE split the line on WHITESPACE and asked whether each word
// was a known action word. Under `Description: key` units it mis-slices: the
// ": " of a unit is not a word, and "Attach" / "New" / "remote" are words
// other hints use, so a line cut clean through a unit could still be made
// entirely of recognised words. It could not see the bug it was for.
//
// THE NEW PREDICATE splits on the UNIT SEPARATOR and requires every visible
// piece to be a whole `Description: key` unit (kh_is_whole_unit): the ": "
// seam must be present, something must sit before it, and a non-space must
// follow it. How this fails: if truncation ever emits "Attach: " with no key,
// or a bare "a", or a description whose key was cut away with it, a piece
// that is not a whole unit appears and partial > 0. The falsification lives in
// keyhints_half_unit_predicate_falsifies, which feeds it exactly those lines.
//
// HOW THE `…` FRONT-CUT MARKER INTERACTS WITH THE SPLIT
//
// footer_spans emits the marker as its OWN span followed by its OWN separator
// span, so on the line it is a piece all by itself: "… | Theme: t | Quit: esc"
// splits to ["…", "Theme: t", "Quit: esc"]. The predicate skips the exact
// string "…" (and "" from adjacent separators) as legal, so the marker can
// never be mistaken for a unit fragment — and a unit fragment can never borrow
// the marker's pass, because a glued "…Quit: esc" is a DIFFERENT piece that
// does not equal "…" and is not skipped. That is the reason the marker is a
// span of its own: glued to the next unit it would have contained ": " and
// slipped through the predicate entirely.
kh_no_half_unit :: proc(line: string) -> bool {
	return kh_half_unit_count(line) == 0
}

kh_half_unit_count :: proc(line: string) -> int {
	parts := kh_split(line, ui.SEP)
	defer delete(parts)
	partial := 0
	for p in parts {
		if p == "" || p == ui.CUT_MARKER { continue } // the front-cut marker stays legal
		if !kh_is_whole_unit(p) { partial += 1 }
	}
	return partial
}

// kh_is_whole_unit: the seam must exist AND something must sit after it.
//
// "Contains ': '" alone is not enough. A unit cut immediately after its colon
// leaves "Attach: ", which DOES contain ": " — the space is still there, the
// key is not — and would pass a containment-only check while advertising an
// action no key performs. So the piece is a whole unit only if a non-space
// byte follows the seam. The description must be non-empty too: a piece that
// starts at the seam is a bare key with its description cut away.
kh_is_whole_unit :: proc(p: string) -> bool {
	b := transmute([]u8)(p)
	i := kh_index_of_bytes(b, ": ")
	if i <= 0 { return false } // absent, or the description was cut away
	for j := i + 2; j < len(b); j += 1 {
		if b[j] != ' ' { return true }
	}
	return false // ": " with nothing but space after it: no key
}

kh_index_of_bytes :: proc(b: []u8, needle: string) -> int {
	nb := transmute([]u8)(needle)
	if len(nb) == 0 || len(nb) > len(b) { return -1 }
	for i := 0; i + len(nb) <= len(b); i += 1 {
		match := true
		for k := 0; k < len(nb); k += 1 {
			if b[i+k] != nb[k] { match = false; break }
		}
		if match { return i }
	}
	return -1
}

// kh_marker_only: the marker counts as the marker only where the separator
// made it a piece of its own, and nowhere else on the line.
kh_marker_only :: proc(line: string) -> bool {
	parts := kh_split(line, ui.SEP)
	defer delete(parts)
	found := false
	for p in parts {
		if p == ui.CUT_MARKER { found = true; continue }
		if strings_contains(p, ui.CUT_MARKER) { return false }
	}
	return found
}

// kh_min_width: the smallest `max` for which hint `i` is still on the line.
// Derived from the product's own widths exactly as footer_spans adds them —
// the units from i to the end, one join between each, plus the front-cut
// marker for as long as something still sits to the left of i.
kh_min_width :: proc(ks: []ui.Key_Hint, i: int) -> i32 {
	// The seed unit: footer_spans starts from the end and always keeps it as
	// long as it fits. It pays nothing for a marker, because it is not the
	// hint that got cut.
	if i == len(ks)-1 {
		return ui.footer_unit_cols(ks[i])
	}
	join := ui.text_cols(ui.SEP)
	total := ui.footer_unit_cols(ks[len(ks)-1])
	for j := len(ks) - 2; j >= i; j -= 1 {
		total += join + ui.footer_unit_cols(ks[j])
	}
	if i > 0 { total += ui.text_cols(ui.CUT_MARKER) + join }
	return total
}

kh_expected_kept :: proc(ks: []ui.Key_Hint, w: i32) -> [dynamic]string {
	out: [dynamic]string = {}
	for i := 0; i < len(ks); i += 1 {
		if w >= kh_min_width(ks, i) { append(&out, kh_unit(ks[i])) }
	}
	return out
}

kh_visible_units :: proc(pieces: []string, ks: []ui.Key_Hint) -> [dynamic]string {
	out: [dynamic]string = {}
	for k in ks {
		u := kh_unit(k)
		for p in pieces { if p == u { append(&out, u); break } }
	}
	return out
}

// kh_marker_shown: the marker is on the line iff the separator made it the
// first piece.
kh_marker_shown :: proc(pieces: []string) -> bool {
	if len(pieces) == 0 { return false }
	return pieces[0] == ui.CUT_MARKER
}

kh_same_units :: proc(a, b: []string) -> bool {
	if len(a) != len(b) { return false }
	for i := 0; i < len(a); i += 1 { if a[i] != b[i] { return false } }
	return true
}

kh_total_hints :: proc(tables: []ui.State_Hints) -> int {
	n := 0
	for th in tables { n += len(th.hints) }
	return n
}

// kh_unit is the test's OWN build of `Description: key`, so the expectation is
// not produced by the code under test.
kh_unit :: proc(k: ui.Key_Hint) -> string {
	return kh_cat3(k.action, ": ", k.key)
}

kh_join_units :: proc(us: []string) -> string {
	buf: [dynamic]byte
	for i := 0; i < len(us); i += 1 {
		if i > 0 { kh_append_str(&buf, ui.SEP) }
		kh_append_str(&buf, us[i])
	}
	return string(buf[:])
}

kh_append_str :: proc(o: ^[dynamic]byte, s: string) {
	b := transmute([]u8)(s)
	for x in b { append(o, x) }
}

kh_cat3 :: proc(a, b, c: string) -> string {
	out: [dynamic]byte
	kh_append_str(&out, a)
	kh_append_str(&out, b)
	kh_append_str(&out, c)
	return string(out[:])
}

// kh_i32 renders a number with exactly one slot and exactly one value, so an
// `%!(EXTRA …)` tail cannot occur, and with no pad syntax, so `%!(MISSING
// CLOSE BRACE)` cannot either.
kh_i32 :: proc(n: i32) -> string {
	return fmt.tprintf("{}", n)
}

// kh_join_str concatenates pieces with no template involved at all.
kh_join_str :: proc(parts: []string) -> string {
	out: [dynamic]byte
	for p in parts { kh_append_str(&out, p) }
	return string(out[:])
}

kh_kind_names :: proc(spans: []ui.Footer_Span) -> string {
	out := ""
	for s in spans {
		k := "?"
		switch s.kind {
		case .desc: k = "desc"
		case .key:  k = "key"
		case .sep:  k = "sep"
		}
		if out != "" { out = fmt.tprintf("{}, ", out) }
		out = fmt.tprintf("{}:{}", out, k)
	}
	return out
}

// kh_split splits on a literal separator (the unit join), not on whitespace.
kh_split :: proc(s: string, sep: string) -> [dynamic]string {
	out: [dynamic]string = {}
	if len(sep) == 0 { append(&out, s); return out }
	start := 0
	i := 0
	for i + len(sep) <= len(s) {
		if kh_starts_with_at(s[i:], sep) {
			append(&out, s[start:i])
			i += len(sep)
			start = i
			continue
		}
		i += 1
	}
	append(&out, s[start:])
	return out
}

kh_starts_with :: proc(s, prefix: string) -> bool {
	return kh_starts_with_at(s, prefix)
}

kh_starts_with_at :: proc(s, prefix: string) -> bool {
	if len(prefix) > len(s) { return false }
	for i := 0; i < len(prefix); i += 1 {
		if s[i] != prefix[i] { return false }
	}
	return true
}

kh_starts_upper :: proc(s: string) -> bool {
	if len(s) == 0 { return false }
	b := transmute([]u8)(s)
	c := b[0]
	return c >= 'A' && c <= 'Z'
}

kh_lower :: proc(s: string) -> string {
	src := transmute([]u8)(s)
	buf: [dynamic]byte
	for c in src {
		if c >= 'A' && c <= 'Z' { append(&buf, c + 32) } else { append(&buf, c) }
	}
	return string(buf[:])
}

// kh_first keeps the FIRST offender so the message points at the first thing
// that broke rather than the last.
kh_first :: proc(dst: ^string, msg: string) {
	if dst^ == "" { dst^ = msg }
}

kh_col_eq :: proc(a, b: clay.Color) -> bool {
	for i := 0; i < 4; i += 1 { if a[i] != b[i] { return false } }
	return true
}

// ── the paint probe ──────────────────────────────────────────────────────

kh_attr :: proc(c: clay.Color) -> tb.Attr {
	return render.attr_painted(c)
}

// kh_paint_footer paints the hint units into a bare root at (0,0), so the
// column a span starts at IS its display offset and no frame padding can hide
// a drift between what the layout chose and what the buffer holds.
kh_paint_footer :: proc(keys: []ui.Key_Hint, room: i32, pal: ^ui.Palette) {
	tb.tb_clear()
	clay.BeginLayout()
	if clay.UI(clay.ID("hs.uip5.footer.probe.root"))({
		layout = clay.LayoutConfig{
			sizing = clay.Sizing{
				width  = clay.SizingFixed(f32(RENDER_COLS)),
				height = clay.SizingFixed(f32(RENDER_ROWS)),
			},
			layoutDirection = clay.LayoutDirection.TopToBottom,
		},
		backgroundColor = pal.bg,
	}) {
		ui.footer_hints(keys, room, pal)
	}
	cmds := clay.EndLayout(0)
	render_paint_cmds(cmds)
}
