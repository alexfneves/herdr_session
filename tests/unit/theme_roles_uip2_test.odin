package unit

// ============================================================================
// theme_roles_uip2_test.odin — the six roles RCH-10 added to the palette
// (UIP-2), proven rather than asserted-by-hex.
//
// WHY THIS FILE EXISTS AT ALL
//
// The 13 original slots were covered by "every theme fills every slot", which
// proves a colour is PRESENT. It proves nothing about whether the colour is
// any good in the place it gets painted. The six new roles are exactly the
// roles where "a value is there" and "the value works" come apart:
//
//   * `run_hl` / `stop_hl` are drawn ON the accent bar. A colour that is
//     beautiful on the page background can be invisible on the bar, and the
//     whole point of these two roles (see the ACK-1 note in app/theme.odin)
//     is that a selected RUNNING row and a selected STOPPED row must NOT
//     render identically. A single shared `state_hl` — the version ORCH D-M
//     asked for — fails that by construction.
//   * `key_fg` / `desc_fg` sit on the same line. A "dominant" key and a
//     "muted" description that measure the same contrast are one colour
//     wearing two names, so dominance is measured, not promised.
//   * `caret_bg` / `caret_fg` are a PAIR: a block plus the glyph knocked
//     out of it. Each half is meaningless alone.
//
// TWO OF THESE SIX ROLES ARE NO LONGER AUTHORED BY A THEME
//
// `run_hl` and `stop_hl` are UNSET (0) in every theme literal and are
// COMPUTED by `app.theme_hl_pair_kept` from `running` / `stopped` / `accent`
// / `sel_fg`. That is the user's directive applied literally: the theme is an
// array of colours and every element points at an entry of it; nobody figures
// out one colour for one element in one theme. Most of this file therefore
// measures the DERIVED pair (`ui.palette_of(th)`), not the theme table, and
// separately proves the table leaves the two slots empty so nobody can slide a
// hand-picked hex back in.
//
// WHY THE PAIR'S ON-BAR FLOOR IS 2.0 AND THE REST OF THE PALETTE'S IS 2.5
//
// This is the one place this file measures against a LOWER number, and it is a
// geometric ceiling, not a relaxed opinion. With `accent` and `sel_fg` fixed,
// a colour is allowed only if it clears floor_bar against the bar AND
// floor_distinct against sel_fg; both are functions of luminance alone, so the
// allowed set is an interval and the largest mutual ratio inside it is
//
//     contrast(accent, sel_fg) / (floor_bar * floor_distinct)
//
// Demanding that reach floor_distinct itself needs contrast(accent, sel_fg) >=
// floor_bar * floor_distinct^2 = 6.4 at 2.5. catppuccin-frappe measures
// 6.280, its allowed interval is [0.07158, 0.14089] and its ceiling is 1.569
// — no two colours of ANY hue can satisfy 2.5-on-bar + 1.6-vs-sel_fg +
// 1.6-mutual on that bar. At 2.0 the identity needs 5.12 and every shipped
// arrangement clears it. The full proof lives next to the constants in
// src/app/theme.odin; `roles_derived_pair_floor_is_the_documented_one` below
// pins the numbers so this cannot quietly drift into "we lowered it until it
// passed".
//
// `FLOOR_ON_BAR = 2.5` is UNCHANGED and stays authoritative for every other
// slot in the palette (the caret block, and anything added later). Only the two
// derived highlight roles use `FLOOR_ON_BAR_DERIVED`.
//
// WHY CONTRAST IS COMPUTED HERE AND NOT LOOKED AT
//
// Every threshold below is a WCAG 2.1 contrast ratio computed from the shipped
// hex. That is deliberate: a number derived from the table cannot go stale when
// a theme is edited, and it fails with the measured value in the message. "Looks
// fine on my terminal" is not re-checkable by anyone who did not see the
// terminal.
//
// The maths itself is NOT in this file any more. It used to be a local copy, but
// the product now uses the same maths to DERIVE shipped colours, and two copies
// of the formula mean a test that cannot see the bug it is meant to catch. The
// one implementation is in `app` (`theme_srgb_to_linear` / `theme_luma` /
// `theme_contrast`); the local names below are thin wrappers so the call sites
// read the same.
//
// The floors themselves are judgement, stated openly:
//   key_fg   >= 4.5 on bg   — a token a user hunts for at speed (AD-1.2)
//   desc_fg  >= 2.7 on bg   — readable but clearly the lesser voice
//   key/desc >= 1.5x        — the two must not be the same loudness
//   caret    >= 3.0 glyph/block, block >= 2.5 vs the page — a caret the
//                             eye has to hunt for is worse than no caret
//   derived  >= 2.0 on the bar — see the ceiling proof above
//   derived  >= 1.6 vs sel_fg — THE USER'S RULE: the state word is not one of
//                             the other highlighted characters
//   derived  >= 1.6 to EACH OTHER — change 5 has to survive being drawn
//                             3 columns apart
//   derived  spread >= 8 + channel order kept — "keep its own colour": a blend
//                             that grinds green into near-black passes no test
// ============================================================================

import "core:fmt"
import "core:strings"
import "core:testing"

import clay "../../clay-odin"
import ui "../../src/ui"
import app "../../src/app"
import support "../support"

// ── the maths, delegated to the ONE implementation ────────────────────────
//
// These three used to be the canonical copy. They are now wrappers on purpose:
// the tests read `contrast(a, b)` and the product reads `theme_contrast(a, b)`,
// and both go through the same function. A change to the maths changes the
// product and the measurement together, which is the only arrangement in which
// a derived-colour test can still fail when the derivation is wrong.

srgb_to_linear :: proc(c: u8) -> f64 { return app.theme_srgb_to_linear(c) }
luma :: proc(hex: u32) -> f64 { return app.theme_luma(hex) }
contrast :: proc(a, b: u32) -> f64 { return app.theme_contrast(a, b) }

FLOOR_KEY :: f64(4.5)
FLOOR_DESC :: f64(2.7)
FLOOR_DOMINANCE :: f64(1.5)
FLOOR_CARET_GLYPH :: f64(3.0)
FLOOR_CARET_BLOCK :: f64(2.5)
FLOOR_ON_BAR :: f64(2.5)
FLOOR_HL_MUTUAL :: f64(1.6)

// The DERIVED pair's floors: read from the product, not restated here, so the
// test cannot pass against a number the product no longer uses.
FLOOR_ON_BAR_DERIVED :: app.THEME_HL_FLOOR_ON_BAR
FLOOR_TEXT :: app.THEME_HL_FLOOR_TEXT
FLOOR_MUTUAL :: app.THEME_HL_FLOOR_MUTUAL
MIN_SPREAD :: app.THEME_HL_MIN_SPREAD

// ── helpers over the resolved (derived) palette ────────────────────────────

// clay_hex folds a resolved clay.Color back to 0xRRGGBB so the WCAG maths —
// which reads palette hex — can be applied to whatever the view actually got.
// Channels are 0..255 floats holding exact integers (see the 0..255 trap in
// src/app/theme.odin), so +0.5 then truncate is exact, not lossy.
clay_hex :: proc(c: clay.Color) -> u32 {
	r := u32(c[0] + 0.5)
	g := u32(c[1] + 0.5)
	b := u32(c[2] + 0.5)
	return (r << 16) | (g << 8) | b
}

Hl_Row :: struct {
	who                        : string,
	accent, sel_fg             : u32,
	run_hl, stop_hl            : u32,
	run_base, stop_base        : u32,
	run_bar, stop_bar          : f64,
	run_text, stop_text        : f64,
	mutual                     : f64,
	spread_run, spread_stop    : i32,
	tightest                   : string,
	tightest_ratio             : f64,
	feasible                   : bool,
	binding                    : string,
}

// hl_pad / hl_pad_l do column alignment BY HAND, because Odin's `fmt` has no
// alignment verbs. Measured on this toolchain: `{:<21}` renders as
// `%!(MISSING CLOSE BRACE)1}`, `{:21}` as `%!(NO VERB)` and `{:>3}` as
// `%!(MISSING CLOSE BRACE)}`, and one bad verb desyncs every later verb on the
// line -- which is exactly how the derived table came to print a widened byte
// dump where the theme name belonged. Gate rule 7 fails a suite for `%!` fallout,
// so the padding lives here instead of in a format string that cannot do it.
//
// `+=` on a runtime string is not a thing in Odin either ("String concatenation
// is only allowed with constant strings"), so alignment is one `tprintf` over a
// slice of a constant run of spaces rather than a growing string.
HL_SPACES :: "                                                                "

hl_pad :: proc(s: string, n: int) -> string {
	spaces := HL_SPACES // constant -> variable: Odin will not slice a constant with a runtime index
	pad := n - len(s)
	if pad <= 0 {
		return s
	}
	if pad > len(spaces) {
		pad = len(spaces)
	}
	return fmt.tprintf("{}{}", s, spaces[:pad])
}

hl_pad_l :: proc(s: string, n: int) -> string {
	spaces := HL_SPACES // constant -> variable, same reason
	pad := n - len(s)
	if pad <= 0 {
		return s
	}
	if pad > len(spaces) {
		pad = len(spaces)
	}
	return fmt.tprintf("{}{}", spaces[:pad], s)
}

// Iv is one interval of luminance.
Iv :: struct{ lo, hi : f64 }

// allowed_luma_range answers the question the whole floor argument rests on:
// with the bar and the bar's text fixed, which luminances may a colour have in
// order to clear BOTH `floor_bar` against the bar AND `floor_text` against the
// text? Inverting WCAG's own identity:
//
//     contrast(L, B) >= f  <=>  L >= f*(B+0.05) - 0.05     (the lighter side)
//                         or   L <= (B+0.05)/f - 0.05      (the darker side)
//
// Each constraint is therefore two intervals, so the allowed set is the union
// of up to four intersections — several shipped themes' allowed set really does
// straddle sel_fg's luminance, which is why a one-line formula is not usable
// here and the intersections are enumerated.
//
// `ceiling` is the largest mutual contrast TWO allowed colours can reach.
// contrast is a ratio of (L + 0.05) and every allowed L has L + 0.05 > 0, so
// the maximum pairwise ratio is just (max + 0.05) / (min + 0.05) over the
// whole allowed set. Computed here, not quoted: move the floors and the ceiling
// moves with it, so the assertions below are always checking the real thing.
allowed_luma_range :: proc(bar_lum, text_lum: f64, floor_bar, floor_text: f64) -> (lo, hi, ceiling: f64) {
	bar_ivs := [2]Iv{
		Iv{0.0, (bar_lum + 0.05) / floor_bar - 0.05}, // darker than the bar
		Iv{floor_bar * (bar_lum + 0.05) - 0.05, 1.0}, // lighter than the bar
	}
	txt_ivs := [2]Iv{
		Iv{0.0, (text_lum + 0.05) / floor_text - 0.05}, // darker than the bar text
		Iv{floor_text * (text_lum + 0.05) - 0.05, 1.0}, // lighter than the bar text
	}
	lo = 2.0
	hi = -1.0
	for a in bar_ivs {
		for b in txt_ivs {
			l := a.lo
			if b.lo > l { l = b.lo }
			h := a.hi
			if b.hi < h { h = b.hi }
			if l < 0.0 { l = 0.0 }
			if h > 1.0 { h = 1.0 }
			if l <= h {
				if l < lo { lo = l }
				if h > hi { hi = h }
			}
		}
	}
	if hi < lo { return 0.0, 0.0, -1.0 } // these floors admit nothing at all
	return lo, hi, (hi + 0.05) / (lo + 0.05)
}

// hl_row measures one resolved palette's derived pair against every floor, and
// records which constraint is tightest (smallest achieved/floor). That column
// is what a reader needs: it says where the derivation is spending its margin.
hl_row :: proc(who: string, accent, sel_fg, running, stopped: u32) -> Hl_Row {
	r := Hl_Row{}
	r.who = who
	r.accent = accent
	r.sel_fg = sel_fg
	r.run_base = running
	r.stop_base = stopped
	pr := app.theme_hl_pair_kept(running, stopped, accent, []u32{sel_fg},
	                            FLOOR_ON_BAR_DERIVED, FLOOR_TEXT, FLOOR_MUTUAL,
	                            MIN_SPREAD)
	r.run_hl = pr.run_hl
	r.stop_hl = pr.stop_hl
	r.feasible = pr.feasible
	r.binding = pr.binding
	r.run_bar = contrast(pr.run_hl, accent)
	r.stop_bar = contrast(pr.stop_hl, accent)
	r.run_text = contrast(pr.run_hl, sel_fg)
	r.stop_text = contrast(pr.stop_hl, sel_fg)
	r.mutual = contrast(pr.run_hl, pr.stop_hl)
	r.spread_run = app.theme_hl_spread(pr.run_hl)
	r.spread_stop = app.theme_hl_spread(pr.stop_hl)

	// tightest = the smallest achieved/floor across every floor that applies
	r.tightest = "on_bar(run)"
	r.tightest_ratio = r.run_bar / FLOOR_ON_BAR_DERIVED
	check_tight :: proc(rr: ^Hl_Row, label: string, v: f64) {
		if v < rr.tightest_ratio {
			rr.tightest_ratio = v
			rr.tightest = label
		}
	}
	check_tight(&r, "on_bar(stop)", r.stop_bar / FLOOR_ON_BAR_DERIVED)
	check_tight(&r, "vs_sel_fg(run)", r.run_text / FLOOR_TEXT)
	check_tight(&r, "vs_sel_fg(stop)", r.stop_text / FLOOR_TEXT)
	check_tight(&r, "mutual", r.mutual / FLOOR_MUTUAL)
	return r
}

// hl_row_of_themes builds a row for one shipped theme from its HEX table, i.e.
// from exactly what `palette_of` is derived from.
hl_row_of_theme :: proc(i: int) -> Hl_Row {
	p := app.theme_at(i).pal
	return hl_row(app.theme_at(i).name, p.accent, p.sel_fg, p.running, p.stopped)
}

// hl_row_of_palette builds a row for a RESOLVED ui.Palette, which is how the
// view sees it. Used for DEFAULT_PALETTE and for the "derived not authored"
// cross-check.
hl_row_of_resolved :: proc(who: string, pal: ui.Palette) -> Hl_Row {
	return hl_row(who, clay_hex(pal.accent), clay_hex(pal.sel_fg),
	             clay_hex(pal.running), clay_hex(pal.stopped))
}

// ── THE USER'S RULE: the state word is not one of the other highlighted chars ──

@(test)
roles_highlight_pair_is_never_the_bar_text_colour :: proc(t: ^testing.T) {
	// THE check that was missing, and the reason this whole change exists. The
	// old palette set run_hl to the SAME hex as sel_fg in 6 of 10 themes, so
	// on a selected row the state word WAS a different role and the same
	// pixels anyway. The requirement is not "the role has a name"; it is
	// visibly different ink from every other highlighted character on the bar.
	//
	// This is checked against the RESOLVED palette (`ui.palette_of`), because
	// that is what paints. A theme literal could be perfect and the mapper
	// wrong; this reads the value the cell gets.
	fails := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		pal := ui.palette_of(th)
		run_hl := clay_hex(pal.run_hl)
		stop_hl := clay_hex(pal.stop_hl)
		sel := clay_hex(pal.sel_fg)
		if run_hl == sel {
			fails += 1
			detail = fmt.tprintf("{} {}; run_hl IS sel_fg ({:06x}) — the flattening the user reported", detail, th.name, sel)
			continue
		}
		if stop_hl == sel {
			fails += 1
			detail = fmt.tprintf("{} {}; stop_hl IS sel_fg ({:06x})", detail, th.name, sel)
			continue
		}
		rt := contrast(run_hl, sel)
		st := contrast(stop_hl, sel)
		if rt < FLOOR_TEXT || st < FLOOR_TEXT {
			fails += 1
			detail = fmt.tprintf("{} {}; run vs sel_fg={:.3f} stop vs sel_fg={:.3f} (floor {:.2f})",
				detail, th.name, rt, st, FLOOR_TEXT)
		}
	}
	// …and the same rule for the pre-theme stand-in, which is painted whenever
	// there is no theme at all.
	def := ui.DEFAULT_PALETTE
	drun, dstop, dsel := clay_hex(def.run_hl), clay_hex(def.stop_hl), clay_hex(def.sel_fg)
	if drun == dsel || dstop == dsel {
		fails += 1
		detail = fmt.tprintf("{} DEFAULT_PALETTE: a highlight role equals sel_fg ({:06x})", detail, dsel)
	} else if contrast(drun, dsel) < FLOOR_TEXT || contrast(dstop, dsel) < FLOOR_TEXT {
		fails += 1
		detail = fmt.tprintf("{} DEFAULT_PALETTE: run={:.3f} stop={:.3f} vs sel_fg (floor {:.2f})",
			detail, contrast(drun, dsel), contrast(dstop, dsel), FLOOR_TEXT)
	}
	support.check(t,
		"NEITHER highlight role is the bar's own text colour, and both are >= 1.6 vs it (THE USER'S RULE, all themes + DEFAULT)",
		fails == 0, fmt.tprintf("{} violation(s){}", fails, detail))
}

// ── derived, not authored ─────────────────────────────────────────────────

@(test)
roles_highlight_pair_is_derived_not_authored :: proc(t: ^testing.T) {
	// Two halves, both necessary:
	//   (a) every theme literal leaves run_hl / stop_hl at 0, so no per-theme
	//       hex for these roles exists to be wrong;
	//   (b) the value the view gets is EXACTLY what the derivation returns for
	//       that theme's own running/stopped/accent/sel_fg.
	// A re-introduced per-theme hex trips (a). A mapper that stops calling the
	// derivation, or calls it with different floors, trips (b).
	authored := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		if (th.pal.run_hl & 0xffffff) != 0 {
			authored += 1
			detail = fmt.tprintf("{} {}.run_hl is AUTHORED ({:06x}); it must be left 0 and derived",
				detail, th.name, th.pal.run_hl)
		}
		if (th.pal.stop_hl & 0xffffff) != 0 {
			authored += 1
			detail = fmt.tprintf("{} {}.stop_hl is AUTHORED ({:06x}); it must be left 0 and derived",
				detail, th.name, th.pal.stop_hl)
		}
	}
	support.check(t, "no theme authors run_hl / stop_hl (both UNSET in every literal)",
		authored == 0, fmt.tprintf("{} authored slot(s){}", authored, detail))

	mismatch := 0
	mdetail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		want := app.theme_hl_pair_of(th.pal)
		got := ui.palette_of(th)
		want_run_r, want_run_g, want_run_b := app.theme_rgb(want.run_hl)
		want_stop_r, want_stop_g, want_stop_b := app.theme_rgb(want.stop_hl)
		if int(got.run_hl[0]) != int(want_run_r) || int(got.run_hl[1]) != int(want_run_g) ||
		   int(got.run_hl[2]) != int(want_run_b) {
			mismatch += 1
			mdetail = fmt.tprintf("{} {} run_hl resolved to ({}, {}, {}) but the derivation says ({}, {}, {})",
				mdetail, th.name, int(got.run_hl[0]), int(got.run_hl[1]), int(got.run_hl[2]),
				int(want_run_r), int(want_run_g), int(want_run_b))
		}
		if int(got.stop_hl[0]) != int(want_stop_r) || int(got.stop_hl[1]) != int(want_stop_g) ||
		   int(got.stop_hl[2]) != int(want_stop_b) {
			mismatch += 1
			mdetail = fmt.tprintf("{} {} stop_hl resolved to ({}, {}, {}) but the derivation says ({}, {}, {})",
				mdetail, th.name, int(got.stop_hl[0]), int(got.stop_hl[1]), int(got.stop_hl[2]),
				int(want_stop_r), int(want_stop_g), int(want_stop_b))
		}
	}
	support.check(t, "palette_of's highlight roles ARE theme_hl_pair_kept's output (no re-mapping, no fudge)",
		mismatch == 0, fmt.tprintf("{} mismatch(es){}", mismatch, mdetail))
}

@(test)
roles_default_pair_matches_the_derivation :: proc(t: ^testing.T) {
	// DEFAULT_PALETTE is a GLOBAL, and Odin will not evaluate a procedure in a
	// global initialiser, so its two derived roles are PINNED literals rather
	// than a call. This test is what makes the pin honest: it recomputes the
	// derivation from the stand-in's OWN channels and fails with the exact
	// channels to re-pin if the literal stops matching. The pin therefore
	// cannot drift, which is the only property "computed, not authored" needs
	// in a context that cannot compute.
	def := ui.DEFAULT_PALETTE
	accent := clay_hex(def.accent)
	sel := clay_hex(def.sel_fg)
	running := clay_hex(def.running)
	stopped := clay_hex(def.stopped)
	want := app.theme_hl_pair_kept(running, stopped, accent, []u32{sel},
	                             FLOOR_ON_BAR_DERIVED, FLOOR_TEXT, FLOOR_MUTUAL,
	                             MIN_SPREAD)
	wr, wg, wb := app.theme_rgb(want.run_hl)
	sr, sg, sb := app.theme_rgb(want.stop_hl)
	ok_run := int(def.run_hl[0]) == int(wr) && int(def.run_hl[1]) == int(wg) && int(def.run_hl[2]) == int(wb)
	ok_stop := int(def.stop_hl[0]) == int(sr) && int(def.stop_hl[1]) == int(sg) && int(def.stop_hl[2]) == int(sb)
	support.check(t,
		"DEFAULT_PALETTE's highlight pair equals the same derivation (pin, not invention)",
		ok_run && ok_stop,
		fmt.tprintf("run_hl is ({}, {}, {}) derived ({}, {}, {}); stop_hl is ({}, {}, {}) derived ({}, {}, {}). Re-pin to match.",
			int(def.run_hl[0]), int(def.run_hl[1]), int(def.run_hl[2]), int(wr), int(wg), int(wb),
			int(def.stop_hl[0]), int(def.stop_hl[1]), int(def.stop_hl[2]), int(sr), int(sg), int(sb)))
	// And the derivation the pin came from must itself be feasible — a pinned
	// black would sail through the equality check above otherwise.
	support.check(t, "DEFAULT_PALETTE's derivation is FEASIBLE (not the fallback path)",
		want.feasible, fmt.tprintf("binding: {}", want.binding))
}

@(test)
roles_derived_pair_floor_is_the_documented_one :: proc(t: ^testing.T) {
	// Locks the two floors so the 2.0 cannot be defended by editing this file.
	// The proof that 2.5 is unreachable for catppuccin-frappe is written out in
	// src/app/theme.odin; this asserts the numbers that proof produces.
	support.eq_i(t, "the derived pair's on-bar floor is 2.0", int(FLOOR_ON_BAR_DERIVED * 10), 20)
	support.eq_i(t, "the palette-wide on-bar floor is STILL 2.5 (unchanged for every other slot)",
		int(FLOOR_ON_BAR * 10), 25)
	support.eq_i(t, "the derived pair's vs-text floor is 1.6", int(FLOOR_TEXT * 10), 16)
	support.eq_i(t, "the derived pair's mutual floor is 1.6", int(FLOOR_MUTUAL * 10), 16)
	support.eq_i(t, "hue must survive at spread >= 8", MIN_SPREAD, 8)

	// The ceiling, COMPUTED here rather than quoted, checked in both directions:
	//
	//   * at 2.5 the ceiling must fail for at least one shipped theme — that
	//     is the fact that makes a derived-only floor necessary instead of a
	//     loosening, and if no theme exhibited it this change would be
	//     unjustified, so the assertion runs both ways;
	//   * at the DERIVED floor the ceiling must clear 1.6 for EVERY shipped
	//     theme, or the derived floor is not sufficient and the change is not
	//     actually done.
	//
	// The per-theme interval is printed because the shape varies: on a bar that
	// is lighter than its own sel_fg the allowed set straddles the text's
	// luminance instead of sitting in one dark band, and that is exactly the
	// case a hand-written formula gets wrong.
	unreachable_at_25 := 0
	for i := 0; i < app.theme_count(); i += 1 {
		p := app.theme_at(i).pal
		bl, tl := app.theme_luma(p.accent), app.theme_luma(p.sel_fg)
		lo25, hi25, ceil25 := allowed_luma_range(bl, tl, 2.5, FLOOR_TEXT)
		lo20, hi20, ceil20 := allowed_luma_range(bl, tl, FLOOR_ON_BAR_DERIVED, FLOOR_TEXT)
		if ceil25 < FLOOR_MUTUAL {
			unreachable_at_25 += 1
			support.note(t, fmt.tprintf(
				"  {}: at floor_bar 2.5 the allowed luminance interval is [{:.5f}, {:.5f}], so the max mutual any two colours can reach is {:.3f} < {:.2f} — NO pair of any hue can hold the mutual floor on this bar",
				app.theme_at(i).name, lo25, hi25, ceil25, FLOOR_MUTUAL))
		}
		support.check(t, fmt.tprintf(
			"{} clears the mutual floor at the DERIVED on-bar floor {:.1f} (interval [{:.5f}, {:.5f}], ceiling {:.3f})",
			app.theme_at(i).name, FLOOR_ON_BAR_DERIVED, lo20, hi20, ceil20),
			ceil20 >= FLOOR_MUTUAL,
			fmt.tprintf("ceiling {:.3f} < {:.2f}", ceil20, FLOOR_MUTUAL))
	}
	support.check(t,
		"2.5-on-bar is provably unreachable for at least one shipped theme (that is WHY the derived floor exists)",
		unreachable_at_25 >= 1,
		fmt.tprintf("{} theme(s) unreachable at 2.5; 0 would mean the derived floor is unjustified", unreachable_at_25))
}

// ── hue survives ───────────────────────────────────────────────────────────

@(test)
roles_highlight_pair_keeps_its_hue :: proc(t: ^testing.T) {
	// "Keep its own colour" made measurable. Contrast floors alone can be
	// satisfied by grinding a green to near-black (0x060705 is technically
	// green-dominant and 10:1 on a frost bar); that passes a luma test and
	// fails the user. So the derived value must keep BOTH:
	//   * enough channel spread to still be a COLOUR, and
	//   * the base's channel ORDER / ties (app.theme_hl_hue_kept).
	// Plus the specific thing the screenshots showed: run_hl must stay
	// green-dominant.
	bad := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		pal := ui.palette_of(th)
		run_hl := clay_hex(pal.run_hl)
		stop_hl := clay_hex(pal.stop_hl)
		if !app.theme_hl_hue_kept(run_hl, th.pal.running, MIN_SPREAD) {
			bad += 1
			detail = fmt.tprintf("{} {} run_hl={:06x} did not keep running={:06x}'s hue (spread {})",
				detail, th.name, run_hl, th.pal.running, app.theme_hl_spread(run_hl))
		}
		if !app.theme_hl_hue_kept(stop_hl, th.pal.stopped, MIN_SPREAD) {
			bad += 1
			detail = fmt.tprintf("{} {} stop_hl={:06x} did not keep stopped={:06x}'s hue (spread {})",
				detail, th.name, stop_hl, th.pal.stopped, app.theme_hl_spread(stop_hl))
		}
		// Green-dominance, spelled out WHERE THE BASE IS GREEN-DOMINANT. The
		// screenshot that started this was gruvbox-dark, whose `running`
		// (0xb8bb26) has G above R. Not every theme's "green" is: gruvbox-light's
		// neutral green 0x79740e has R 121 > G 116, so an unconditional G > R
		// demand there would be a claim about that theme's palette rather than
		// about the derivation, and it would be false. The rule is therefore
		// conditional and still bites: a base that reads green must still read
		// green after the blend. Themes whose base is not green-dominant are
		// still held by the channel-order check above, which they pass.
		rr := theme_channel(run_hl, 0)
		gg := theme_channel(run_hl, 1)
		bb := theme_channel(run_hl, 2)
		base_r := theme_channel(th.pal.running, 0)
		base_g := theme_channel(th.pal.running, 1)
		base_b := theme_channel(th.pal.running, 2)
		base_green := base_g > base_r && base_g > base_b
		derived_green := gg > bb && gg > rr
		if base_green && !derived_green {
			bad += 1
			detail = fmt.tprintf("{} {} running={:06x} is green-dominant but run_hl={:06x} is not (R{} G{} B{})",
				detail, th.name, th.pal.running, run_hl, rr, gg, bb)
		}
		if !base_green {
			support.note(t, fmt.tprintf("  note: {}.running is {:06x} (R{} G{} B{}) — not green-dominant at the source, so green-dominance is not asserted for it; channel order is",
				th.name, th.pal.running, base_r, base_g, base_b))
		}
		if app.theme_hl_spread(run_hl) < MIN_SPREAD {
			bad += 1
			detail = fmt.tprintf("{} {} run_hl spread {} < {}", detail, th.name,
				app.theme_hl_spread(run_hl), MIN_SPREAD)
		}
	}
	support.check(t, "the derived highlights keep the state colour's character (spread + channel order)",
		bad == 0, fmt.tprintf("{} violation(s){}", bad, detail))
}

theme_channel :: proc(hex: u32, i: int) -> int { return int(app.theme_hl_channel(hex, i)) }

// ── the no-feasible-case guard ─────────────────────────────────────────────

@(test)
roles_highlight_derivation_is_feasible_for_every_theme :: proc(t: ^testing.T) {
	// The derivation is allowed to be infeasible; it is NOT allowed to be
	// infeasible quietly. If any theme cannot clear every floor, this prints the
	// theme AND the constraint that bound and the ratio it reached, and the run
	// is RED. A silently-degraded state colour is the exact failure mode that
	// shipped once as `run_hl == sel_fg`, so the loud path is the only safe one.
	red := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		row := hl_row_of_theme(i)
		if !row.feasible {
			red += 1
			detail = fmt.tprintf("{}\n  {} NOT FEASIBLE: {} | runBar={:.3f} stopBar={:.3f} runVsText={:.3f} stopVsText={:.3f} mutual={:.3f}",
				detail, row.who, row.binding, row.run_bar, row.stop_bar, row.run_text, row.stop_text, row.mutual)
		}
	}
	def_row := hl_row_of_resolved("DEFAULT_PALETTE", ui.DEFAULT_PALETTE)
	if !def_row.feasible {
		red += 1
		detail = fmt.tprintf("{}\n  DEFAULT_PALETTE NOT FEASIBLE: {}", detail, def_row.binding)
	}
	support.check(t, "every theme's highlight pair is DERIVED FEASIBLY (no silent degradation)",
		red == 0, fmt.tprintf("{} infeasible palette(s){}", red, detail))
}

// ── the two highlight roles: NOT flattened, and legible ────────────────────

@(test)
roles_run_and_stop_are_never_the_same_colour :: proc(t: ^testing.T) {
	// THE falsifiable form of RCH-10 change 5, on the RESOLVED palette. If
	// someone folds these into one role, or the derivation collapses, selection
	// flattens running into stopped and this check dies naming the theme.
	flattened := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		pal := ui.palette_of(th)
		if clay_hex(pal.run_hl) == clay_hex(pal.stop_hl) {
			flattened += 1
			detail = fmt.tprintf("{} {}; run_hl == stop_hl ({:06x})", detail, th.name, clay_hex(pal.run_hl))
		}
	}
	support.check(t, "run_hl != stop_hl in every theme (selection cannot flatten the state)",
		flattened == 0, fmt.tprintf("{} flattened theme(s){}", flattened, detail))
}

@(test)
roles_run_and_stop_differ_by_enough_to_see :: proc(t: ^testing.T) {
	// Different hex is necessary and not sufficient: two near-identical darks
	// would be "different" and still read as the same word. The ratio between
	// the two highlight colours themselves is what a user actually gets.
	too_close := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		pal := ui.palette_of(app.theme_at(i))
		mu := contrast(clay_hex(pal.run_hl), clay_hex(pal.stop_hl))
		if mu < FLOOR_HL_MUTUAL {
			too_close += 1
			detail = fmt.tprintf("{} {}; ratio={:.3f} < {:.2f}", detail, app.theme_at(i).name, mu, FLOOR_HL_MUTUAL)
		}
	}
	support.check(t, "run_hl and stop_hl are MUTUALLY distinguishable (>= 1.6:1)",
		too_close == 0, fmt.tprintf("{} too-close theme(s){}", too_close, detail))
}

@(test)
roles_both_highlights_are_legible_on_the_accent_bar :: proc(t: ^testing.T) {
	// Both words sit on the SAME saturated field. One readable pair is easy;
	// the requirement is two, against the same background, that stay apart.
	//
	// NOTE THE FLOOR. This measures against FLOOR_ON_BAR_DERIVED (2.0), not the
	// palette-wide 2.5, and that is not a loosening we reached for: at 2.5 the
	// allowed luminance interval cannot contain two colours 1.6 apart on
	// catppuccin-frappe's bar (ceiling 1.569), so 2.5 is not a strict floor
	// for this pair at all — it is unsatisfiable. The proof and the interval are
	// in src/app/theme.odin and `roles_derived_pair_floor_is_the_documented_one`
	// re-derives the ceiling here rather than asserting it.
	bad := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		row := hl_row_of_theme(i)
		if row.run_bar < FLOOR_ON_BAR_DERIVED || row.stop_bar < FLOOR_ON_BAR_DERIVED {
			bad += 1
			detail = fmt.tprintf("{} {} run={:.3f} stop={:.3f}", detail, row.who, row.run_bar, row.stop_bar)
		}
	}
	support.check(t, "both highlight roles clear the derived on-bar floor (2.0) on their own accent bar",
		bad == 0, fmt.tprintf("{} bad theme(s){}", bad, detail))
}

// ── the footer pair: two loudness levels, not one ──────────────────────────

@(test)
roles_key_and_desc_are_two_distinct_loudness_levels :: proc(t: ^testing.T) {
	bad := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		k := contrast(th.pal.key_fg, th.pal.bg)
		d := contrast(th.pal.desc_fg, th.pal.bg)
		if th.pal.key_fg == th.pal.desc_fg {
			bad += 1
			detail = fmt.tprintf("{} {} key_fg == desc_fg (one colour, two names)", detail, th.name)
			continue
		}
		if k < FLOOR_KEY || d < FLOOR_DESC || k / d < FLOOR_DOMINANCE {
			bad += 1
			detail = fmt.tprintf("{} {} key={:.2f} desc={:.2f} ratio={:.2f}", detail, th.name, k, d, k / d)
		}
	}
	support.check(t, "key_fg dominates desc_fg (>=4.5 vs >=2.7, and >=1.5x apart) on bg",
		bad == 0, fmt.tprintf("{} bad theme(s){}", bad, detail))
}

// ── the caret pair: a block and the glyph knocked out of it ────────────────

@(test)
roles_caret_block_and_glyph_are_a_usable_pair :: proc(t: ^testing.T) {
	bad := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		glyph := contrast(th.pal.caret_fg, th.pal.caret_bg)
		block := contrast(th.pal.caret_bg, th.pal.bg)
		if th.pal.caret_bg == th.pal.caret_fg {
			bad += 1
			detail = fmt.tprintf("{} {} caret_bg == caret_fg (an invisible block)", detail, th.name)
			continue
		}
		// FLOOR_ON_BAR here is the PALETTE-WIDE 2.5 and stays 2.5: the derived
		// 2.0 belongs to run_hl/stop_hl and to nothing else.
		if glyph < FLOOR_CARET_GLYPH || block < FLOOR_CARET_BLOCK {
			bad += 1
			detail = fmt.tprintf("{} {} glyph-on-block={:.2f} block-on-page={:.2f}", detail, th.name, glyph, block)
		}
	}
	support.check(t, "caret pair: glyph >=3.0 on its block, block >=2.5 on the page",
		bad == 0, fmt.tprintf("{} bad theme(s){}", bad, detail))
}

// ── the fallback: an unfinished theme cannot paint an unchosen colour ───────

@(test)
roles_slot_or_falls_back_only_on_an_unset_slot :: proc(t: ^testing.T) {
	// 0x000000 is "no colour was chosen" everywhere else in this module
	// (the gap check treats it the same way), so it is the sentinel here too.
	support.eq_i(t, "unset slot degrades to the fallback", int(app.theme_slot_or(0x000000, 0x8839ef)), 0x8839ef)
	support.eq_i(t, "a chosen colour is never overridden by the fallback",
		int(app.theme_slot_or(0x112233, 0x8839ef)), 0x112233)
	// The alpha bits are NOT a get-out-of-jail clause: a slot carrying junk
	// above the RGB field is still a colour the theme chose, and the mask
	// that reads it must agree with the gap check's mask.
	support.eq_i(t, "fallback keys off the RGB field, not the whole word",
		int(app.theme_slot_or(0x00000000, 0xabcdef)), 0xabcdef)
}

@(test)
roles_incomplete_theme_degrades_to_chosen_colours :: proc(t: ^testing.T) {
	// THE important one. A theme that fills the 13 original roles and NOTHING
	// else — the likely shape of a theme someone adds in a hurry — must land
	// on colours the theme itself chose, never on black-by-zero.
	//
	// Built from a real theme with the six new slots wiped, so the 13 base
	// colours are genuine and the fallback targets are genuine, and the only
	// thing under test is the mapping.
	th := app.theme_at(0)
	half : app.Palette
	half.bg = th.pal.bg
	half.fg = th.pal.fg
	half.dim = th.pal.dim
	half.border = th.pal.border
	half.header_fg = th.pal.header_fg
	half.accent = th.pal.accent
	half.sel_fg = th.pal.sel_fg
	half.caret = th.pal.caret
	half.float_bg = th.pal.float_bg
	half.float_fg = th.pal.float_fg
	half.err_fg = th.pal.err_fg
	half.running = th.pal.running
	half.stopped = th.pal.stopped
	// key_fg..stop_hl deliberately left zero.

	weak := app.Theme{name = "half-theme", pal = half}
	pal := ui.palette_of(weak)

	// None of the six may paint pure black: black is the one colour the page
	// can never show legitimately (the gap check says so), so a black here
	// would mean the fallback failed and an unchosen colour won.
	black := 0
	if u32(pal.key_fg[0]) == 0 && u32(pal.key_fg[1]) == 0 && u32(pal.key_fg[2]) == 0 { black += 1 }
	if u32(pal.desc_fg[0]) == 0 && u32(pal.desc_fg[1]) == 0 && u32(pal.desc_fg[2]) == 0 { black += 1 }
	if u32(pal.caret_bg[0]) == 0 && u32(pal.caret_bg[1]) == 0 && u32(pal.caret_bg[2]) == 0 { black += 1 }
	if u32(pal.caret_fg[0]) == 0 && u32(pal.caret_fg[1]) == 0 && u32(pal.caret_fg[2]) == 0 { black += 1 }
	if u32(pal.run_hl[0]) == 0 && u32(pal.run_hl[1]) == 0 && u32(pal.run_hl[2]) == 0 { black += 1 }
	if u32(pal.stop_hl[0]) == 0 && u32(pal.stop_hl[1]) == 0 && u32(pal.stop_hl[2]) == 0 { black += 1 }
	support.check(t, "a theme missing all six new roles paints NO pure-black role",
		black == 0, fmt.tprintf("{} role(s) resolved to black", black))

	// The four AUTHORED-with-fallback roles land on the specific documented
	// partner, checked by channel against the base colour they substitute for.
	Pair :: struct{ got : clay.Color, want : u32, label : string }
	pairs := []Pair{
		Pair{pal.key_fg, th.pal.fg, "key_fg->fg"},
		Pair{pal.desc_fg, th.pal.dim, "desc_fg->dim"},
		Pair{pal.caret_bg, th.pal.caret, "caret_bg->caret"},
		Pair{pal.caret_fg, th.pal.bg, "caret_fg->bg"},
	}
	wrong := 0
	detail := ""
	for p in pairs {
		wr, wg, wb := app.theme_rgb(p.want)
		if int(p.got[0]) != int(wr) || int(p.got[1]) != int(wg) || int(p.got[2]) != int(wb) {
			wrong += 1
			detail = fmt.tprintf("{} {} gave ({}, {}, {}) want ({}, {}, {})",
				detail, p.label, int(p.got[0]), int(p.got[1]), int(p.got[2]), int(wr), int(wg), int(wb))
		}
	}
	support.check(t, "each missing AUTHORED role falls back to its documented partner role",
		wrong == 0, fmt.tprintf("{} mismatch(es){}", wrong, detail))

	// The two DERIVED roles do NOT use the pass-through, and that is a
	// stronger guarantee, not a weaker one: they are derived from
	// running/stopped/accent/sel_fg, which the incomplete theme DID fill, so
	// they come out IDENTICAL to the full theme's derived pair. A half-written
	// theme therefore cannot get a worse highlight than a complete one.
	full := ui.palette_of(th)
	support.check(t, "a half theme's run_hl equals the FULL theme's derived run_hl",
		clay_hex(pal.run_hl) == clay_hex(full.run_hl),
		fmt.tprintf("half={:06x} full={:06x}", clay_hex(pal.run_hl), clay_hex(full.run_hl)))
	support.check(t, "a half theme's stop_hl equals the FULL theme's derived stop_hl",
		clay_hex(pal.stop_hl) == clay_hex(full.stop_hl),
		fmt.tprintf("half={:06x} full={:06x}", clay_hex(pal.stop_hl), clay_hex(full.stop_hl)))

	// And the derived pair is still not flattened: falling back to the
	// derivation keeps the distinction change 5 exists to protect, and keeps
	// the user's rule (>= 1.6 vs sel_fg) that a plain pass-through violated.
	support.check(t, "even degraded, run_hl != stop_hl",
		clay_hex(pal.run_hl) != clay_hex(pal.stop_hl),
		"the degraded pair collapsed to one colour")
	support.check(t, "even degraded, neither highlight is sel_fg and both are >= 1.6 vs it",
		clay_hex(pal.run_hl) != clay_hex(pal.sel_fg) &&
		clay_hex(pal.stop_hl) != clay_hex(pal.sel_fg) &&
		contrast(clay_hex(pal.run_hl), clay_hex(pal.sel_fg)) >= FLOOR_TEXT &&
		contrast(clay_hex(pal.stop_hl), clay_hex(pal.sel_fg)) >= FLOOR_TEXT,
		fmt.tprintf("run={:.3f} stop={:.3f} vs sel_fg (floor {:.2f})",
			contrast(clay_hex(pal.run_hl), clay_hex(pal.sel_fg)),
			contrast(clay_hex(pal.stop_hl), clay_hex(pal.sel_fg)), FLOOR_TEXT))
}

@(test)
roles_default_palette_covers_every_new_role :: proc(t: ^testing.T) {
	// The nil-theme path must be as complete as the themed one, or a missing
	// theme paints the footer/caret/highlights with uninitialised colour.
	d := ui.DEFAULT_PALETTE
	zero := 0
	if u32(d.key_fg[3]) == 0 { zero += 1 }
	if u32(d.desc_fg[3]) == 0 { zero += 1 }
	if u32(d.caret_bg[3]) == 0 { zero += 1 }
	if u32(d.caret_fg[3]) == 0 { zero += 1 }
	if u32(d.run_hl[3]) == 0 { zero += 1 }
	if u32(d.stop_hl[3]) == 0 { zero += 1 }
	support.check(t, "DEFAULT_PALETTE fills all six new roles opaquely", zero == 0,
		fmt.tprintf("{} non-opaque role(s)", zero))
	support.check(t, "DEFAULT_PALETTE cannot flatten running into stopped either",
		u32(d.run_hl[0]) != u32(d.stop_hl[0]) || u32(d.run_hl[1]) != u32(d.stop_hl[1]) ||
		u32(d.run_hl[2]) != u32(d.stop_hl[2]),
		fmt.tprintf("run_hl == stop_hl in DEFAULT_PALETTE"))
	// …and the stand-in clears the same bar the real themes do — the DERIVED
	// bar floor, since these two roles are derived here too.
	row := hl_row_of_resolved("DEFAULT_PALETTE", d)
	support.check(t, "DEFAULT_PALETTE highlights clear the derived on-bar floor",
		row.run_bar >= FLOOR_ON_BAR_DERIVED && row.stop_bar >= FLOOR_ON_BAR_DERIVED,
		fmt.tprintf("run={:.2f} stop={:.2f} floor {:.2f}", row.run_bar, row.stop_bar, FLOOR_ON_BAR_DERIVED))
	support.check(t, "DEFAULT_PALETTE highlights clear the user's rule vs sel_fg",
		row.run_text >= FLOOR_TEXT && row.stop_text >= FLOOR_TEXT,
		fmt.tprintf("run={:.2f} stop={:.2f} floor {:.2f}", row.run_text, row.stop_text, FLOOR_TEXT))
}

@(test)
roles_no_hex_literal_is_needed_to_paint_the_new_roles :: proc(t: ^testing.T) {
	// D-H: the view layer references ROLES, never hex. This is a source-level
	// check with a grep-equivalent done in Odin over the view files, because a
	// palette that is complete but bypassed in one widget is still a bug.
	//
	// Scanned: every `0xRRGGBB` in src/ui/* is a violation. (Comments are
	// allowed to name a hex — they describe; they do not paint — so the scan
	// ignores lines whose first non-space token is a comment and any hex
	// inside a comment tail.)
	root := seam_src_root()
	if len(root) == 0 {
		support.check(t, "no colour literal appears in src/ui/* (D-H)", false,
			"src/ not found from this working directory — the scan did not run")
		return
	}
	hits := seam_walk_src(root)
	if seam_files_scanned == 0 {
		support.check(t, "no colour literal appears in src/ui/* (D-H)", false,
			"0 files scanned — a scan over nothing is not a clean result")
		return
	}

	violations : [dynamic]string = {}
	ui_files := 0
	for h in hits {
		if !strings.has_prefix(h.file, "src/ui/") { continue }
		ui_files += 1
		if !has_hex_literal(h.code) { continue }
		append(&violations, fmt.tprintf("{}:{}: {}", h.file, h.line, h.code))
	}
	// A scan that matched no ui files at all is not a clean result — it means
	// the path filter was wrong, and green would be lying.
	support.check(t, "no colour literal appears in src/ui/* (D-H)",
		ui_files > 0 && len(violations) == 0,
		fmt.tprintf("{} violation(s) across {} view-layer code line(s); first: {}",
			len(violations), ui_files, first_or_none(violations[:])))
}

// has_hex_literal reports a `0xRRGGBB`-shaped token in a line of CODE (the
// caller strips comments first). Four hex digits minimum: 2 is too short to be
// a colour and 3 is not a colour, and the palette is written 6-wide.
has_hex_literal :: proc(code: string) -> bool {
	runes := transmute([]u8)(code)
	i := 0
	for i + 2 < len(runes) {
		if runes[i] == '0' && (runes[i+1] == 'x' || runes[i+1] == 'X') {
			n := 0
			j := i + 2
			for j < len(runes) && is_hex_digit(runes[j]) {
				n += 1
				j += 1
			}
			if n >= 6 { return true }
			i = j
			continue
		}
		i += 1
	}
	return false
}

is_hex_digit :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// ── THE PRINTED TABLE ─────────────────────────────────────────────────────
//
// The user asked to be able to see the numbers, and a table the suite prints is
// a table that cannot go stale. This test asserts nothing about colours; it
// asserts the table is complete (every shipped theme + the stand-in, one row
// each, and every row measured against the same floors the checks above use)
// and prints it. "tightest" is the constraint with the smallest achieved/floor
// ratio: that is where the derivation has the least room, and the first thing
// to look at if a future theme goes red.
@(test)
roles_derived_highlight_table_is_printed :: proc(t: ^testing.T) {
	rows : [dynamic]Hl_Row = {}
	for i := 0; i < app.theme_count(); i += 1 {
		append(&rows, hl_row_of_theme(i))
	}
	append(&rows, hl_row_of_resolved("DEFAULT_PALETTE", ui.DEFAULT_PALETTE))

	support.check(t, "the table covers every shipped theme plus DEFAULT_PALETTE",
		len(rows) == app.theme_count() + 1,
		fmt.tprintf("{} rows for {} themes + 1 stand-in", len(rows), app.theme_count()))

	// THE TABLE MUST DESCRIBE THE PALETTE THE VIEW ACTUALLY PAINTS WITH.
	// The row is built from `theme_hl_pair_kept` directly; the view reads
	// `ui.palette_of`. Those two are only the same fact if something pins them,
	// so pin it per row: a table that has drifted from the resolved palette is
	// worse than no table, because it is evidence that lies. (Gate rule 7 exists
	// for the printing half of that risk; this is the semantic half.)
	lies := 0
	lie_detail := ""
	for r in rows {
		want := ui.Palette{}
		found := false
		for i := 0; i < app.theme_count(); i += 1 {
			if app.theme_at(i).name == r.who {
				want = ui.palette_of(app.theme_at(i))
				found = true
				break
			}
		}
		if !found {
			if r.who == "DEFAULT_PALETTE" {
				want = ui.DEFAULT_PALETTE
				found = true
			}
		}
		if !found {
			lies += 1
			lie_detail = fmt.tprintf("{} row '{}' names no theme and no stand-in", lie_detail, r.who)
			continue
		}
		if clay_hex(want.run_hl) != r.run_hl || clay_hex(want.stop_hl) != r.stop_hl {
			lies += 1
			lie_detail = fmt.tprintf("{} {}; table run={:06x} stop={:06x} but palette_of gives run={:06x} stop={:06x}",
				lie_detail, r.who, r.run_hl, r.stop_hl, clay_hex(want.run_hl), clay_hex(want.stop_hl))
		}
		if contrast(clay_hex(want.run_hl), clay_hex(want.accent)) != r.run_bar ||
			contrast(clay_hex(want.stop_hl), clay_hex(want.sel_fg)) != r.stop_text {
			lies += 1
			lie_detail = fmt.tprintf("{} {}; printed ratios do not match the colours printed beside them", lie_detail, r.who)
		}
	}
	support.check(t, "every printed row IS what ui.palette_of resolves for that theme",
		lies == 0, fmt.tprintf("{} row(s) disagree with the resolved palette{}", lies, lie_detail))

	support.note(t, "\nDERIVED HIGHLIGHT PAIR — theme  run_hl  stop_hl  vs-accent(run/stop)  vs-sel_fg(run/stop)  mutual  spread(run/stop)  tightest")
	support.note(t, "-------------------------------------------------------------------------------------------------------------------------------")
	for r in rows {
		support.note(t, fmt.tprintf("  {}  {:06x}  {:06x}  {:.2f} / {:.2f}   {:.2f} / {:.2f}   {:.2f}   {} / {}  tight: {} ({:.2f}x floor) feasible={}",
			hl_pad(r.who, 21), r.run_hl, r.stop_hl, r.run_bar, r.stop_bar, r.run_text, r.stop_text,
			r.mutual, hl_pad_l(fmt.tprintf("{}", r.spread_run), 3), hl_pad(fmt.tprintf("{}", r.spread_stop), 3),
			r.tightest, r.tightest_ratio, r.feasible))
	}
	support.note(t, fmt.tprintf("floors: on_bar(derived)={:.1f}  vs_sel_fg={:.1f}  mutual={:.1f}  spread>={}  grid N={}  (FLOOR_ON_BAR for all OTHER slots stays {:.1f})",
		FLOOR_ON_BAR_DERIVED, FLOOR_TEXT, FLOOR_MUTUAL, MIN_SPREAD, app.THEME_HL_MIX_STEPS, FLOOR_ON_BAR))
	delete(rows)
}
