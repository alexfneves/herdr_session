package app

// ============================================================================
// app.theme — the compiled-in palette set (T6.2, plan D4)
//
// # WHAT THIS FILE OWNS
//
// The *names* and the *colours*. Nothing else. No file I/O (that is config.odin),
// no termbox call (that is render.attr_of), no Clay type. A palette here is a
// table of 0xRRGGBB integers behind semantic slot names, and the only thing that
// turns one into a `clay.Color` is `ui.palette_of` — one function, in one place,
// with the 0..255 fact written next to it.
//
// # WHY A U32 HEX AND NOT A clay.Color
//
//   * the values below are transcribed straight from the cited sources as hex, so
//     `bg = 0x282828` is diffable against gruvbox's own table without a
//     float-in-a-literal detour;
//   * it keeps this package free of the renderer's dependencies — `app` stays
//     testable without a terminal or a Clay archive in the picture;
//   * the conversion point is then impossible to miss, which matters because of
//     the trap below.
//
// # TRAP: Clay channels are 0..255, NOT 0.0..1.0
//
// `Clay_Color` is `[4]c.float` carrying 0..255 (clay-odin/clay.odin:51).
// Feeding 0.16 instead of 40 paints the whole UI black and every check goes red
// at once. Already paid for once; see render/renderer.odin's `attr_of` header.
//
// # TRAP: termbox2 reads a zero attr as "terminal default"
//
// In truecolour the attr's low 24 bits are the RGB, and an attr of 0 with no
// TB_HI_BLACK means "use whatever the terminal has", not "black" (termbox2.h:
// 3830, 3883). So a genuinely black cell needs TB_HI_BLACK set. That is
// handled inside `render.attr_of` — a theme asking for #000000 gets real black,
// not the terminal's background. `theme_rgb` keeps that a non-issue upstream by
// never rounding a requested colour toward zero.
//
// # SOURCES (scout-nix-packaging.md §f; do not "improve" a hex value)
//
//   gruvbox     morhetz/gruvbox          gruvbox_256palette.sh
//   catppuccin  catppuccin/palette       palette.json (v1.8.0)
//   tokyonight  folke/tokyonight.nvim   lua/tokyonight/colors/night.lua
//   nord        nordtheme/nord           src/nord.scss ($nord0..$nord15)
//   solarized   altercation/solarized    README palette table
//
// Every slot value below is one of those files' values, re-labelled. The *choice*
// of which documented colour fills which slot is ours and is stated per theme.
//
// # SLOT SET
//
// The rule for "no gaps" is: the palette has a slot for every semantic colour
// the view layer references, so a view never reaches for a colour the theme does
// not define. The nineteen slots are exactly the fields of `ui.Palette`:
//
//   bg, fg, dim, border (== the between-children rule colour; with D14 there is
//   no outer box, so border and rule are the same colour by construction),
//   header_fg, accent (the selection bar background), sel_fg (text drawn ON the
//   bar), caret, float_bg, float_fg, err_fg, running, stopped,
//   key_fg, desc_fg, caret_bg, caret_fg, run_hl, stop_hl.
//
// `running` / `stopped` are new with the theme work: the sessions table painted
// both with the default fg, so a theme could not distinguish a live session from
// a dormant one. Both now come from the palette.
//
// The six roles added by RCH-10 (`key_fg`, `desc_fg`, `caret_bg`, `caret_fg`,
// `run_hl`, `stop_hl`) exist because the footer, the caret and the selection bar
// each need a colour the existing slots cannot express: two DIFFERENT foregrounds
// in one line (key vs description), a colour PAIR for the caret block (the
// single `caret` slot is a fg for a bare glyph, not a block with a background),
// and a readable state word ON the accent bar.
//
// FOUR of those six are authored per theme. TWO of them — `run_hl` and `stop_hl`
// — are NOT authored at all and are UNSET (0) in every theme literal in `THEMES`
// below. They are derived at `ui.palette_of` time from four slots the theme
// already had to author (`running`, `stopped`, `accent`, `sel_fg`) by one rule,
// `theme_hl_pair_kept`, documented in full at its own section below. That is
// what "treat the theme as an array of colours and let elements point at it"
// means for these two roles: nobody picks a highlight colour for one state word
// in one theme, so it cannot be wrong in one theme.
//
// WHY TWO HIGHLIGHT ROLES AND NOT ONE (ORCH D-M corrected by ACK-1) — the
// original decision asked for a single `state_hl` (13 -> 18). That version is
// WRONG and is not what this palette ships: with one colour, a selected RUNNING
// row and a selected STOPPED row render identically, so selection would flatten
// the running/stopped distinction — the exact thing RCH-10 change 5 forbids. One
// colour cannot preserve a distinction it exists to preserve. `run_hl` +
// `stop_hl` is the only version the requirement can be falsified against, at the
// same mechanical cost, so the total is 19 and NOT 18. The deviation from the
// 18 in D-M is deliberate and is recorded here as well as in the worker report.
//
// ONE MORE WAY TO FLATTEN, AND IT IS NOW THE FORBIDDEN ONE. Two distinct role
// names are necessary but not sufficient: if `run_hl` is given the SAME colour
// as `sel_fg`, the state word is a different ROLE from the bar text and the
// same PIXELS anyway. Six of the ten shipped themes did exactly that
// (`run_hl = sel_fg` = "the loudest thing on a bright bar"), and the user's
// complaint was precisely that a selected row's `running` looked like every
// other highlighted character. `run_hl == sel_fg` is therefore not a legitimate
// styling choice any more: `theme_hl_pair_kept` must return a colour at least
// `THEME_HL_FLOOR_TEXT` (1.6:1) away from `sel_fg`, and
// `roles_highlight_pair_is_never_the_bar_text_colour` proves it for every theme.
// Any comment anywhere in this repo that calls `run_hl == sel_fg` deliberate is
// describing the bug, not the design.
//
// # DEFAULT IS gruvbox-dark (D4)
//
// `catppuccin-latte` ships and is selectable — the user asked for it by name —
// but it is explicitly NOT the default. `THEME_DEFAULT_NAME` is the fallback for
// "no config", "unreadable config" and "config names a theme we do not have",
// which is why it lives here rather than in the config module.
// ============================================================================

import "core:fmt"
import "core:math"
import "base:runtime"
import "core:strings"

//-----------------------------------------------------------------------------
// Slot model
//-----------------------------------------------------------------------------

// Palette is one theme's semantic colours as 0xRRGGBB.
//
// Field order matches `ui.Palette` one-for-one; `ui.palette_of` maps them by
// name, so a rename here that skips the mapper is a compile error rather than a
// silently-miscoloured widget.
Palette :: struct {
	bg        : u32, // terminal background
	fg        : u32, // default text
	dim       : u32, // secondary text: column headers, placeholders, key hints
	border    : u32, // box border AND the between-children rules (D14: no box)
	header_fg : u32, // the header title
	accent    : u32, // the selection bar background
	sel_fg    : u32, // text drawn on the selection bar
	caret     : u32, // edit caret
	float_bg  : u32, // floating pane background
	float_fg  : u32, // floating pane text
	err_fg    : u32, // error text / error pane border
	running   : u32, // a session that is up
	stopped   : u32, // a session that is not

	// ── RCH-10: the six roles the footer/caret/selection paint needs ────
	// Every one of these is theme-resolved and carries a fallback (see
	// `theme_slot_or`), so an incomplete theme cannot paint an unchosen colour.
	key_fg   : u32, // the KEY token in a footer hint — the token the eye hunts for (AD-1.2)
	desc_fg  : u32, // the DESCRIPTION token — muted relative to key_fg
	caret_bg : u32, // background of the cell the caret sits on
	caret_fg : u32, // the caret glyph itself
	run_hl   : u32, // the "running" word WHILE its row is selected — UNSET BY DESIGN, derived by `theme_hl_pair_kept`
	stop_hl  : u32, // the "stopped" word WHILE its row is selected — UNSET BY DESIGN, derived by `theme_hl_pair_kept`
}

// PALETTE_SLOTS names the count the smoke suite asserts on. Adding a slot to
// `Palette` without bumping this makes that check fail, which is the point: the
// view layer must never be left without a colour.
//
// 19 = the 13 original semantic slots + RCH-10's six (key_fg, desc_fg,
// caret_bg, caret_fg, run_hl, stop_hl). It is NOT 18: see the ACK-1 note in the
// header — a single shared highlight role would make selected-running and
// selected-stopped indistinguishable.
//
// Two of those 19 (run_hl, stop_hl) are counted as SLOTS but are never
// AUTHORED — they are derived, and `theme_set_test` asserts they are 0 in every
// literal while asserting the derived value fills them. The slot still has to
// exist, because the view layer still has to reference it.
PALETTE_SLOTS :: 19

// theme_slot_or resolves a slot that a theme may leave unset.
//
// Every shipped theme fills every AUTHORED slot and `theme_set_test` proves it,
// so this cannot rescue a typo in the table — it covers the case the table
// cannot: a theme added later that does not bother to fill a role it does not
// care about. A 0x000000 in a slot means "this theme never chose a colour here"
// (0 is never a shipped semantic colour; `theme_set_test` treats it as a gap for
// the same reason), and `fallback` is the nearest EXISTING role — a colour the
// theme did choose. That is the fallback D-H asks for: an incomplete theme
// degrades to a colour someone picked, never to an unchosen one.
//
// The pairing for each role is the role it visually substitutes for:
//   key_fg -> fg        (the key is still body text, just not emphasised)
//   desc_fg -> dim      (descriptions were already `dim`)
//   caret_bg -> caret   (the caret colour was always the caret's colour)
//   caret_fg -> bg      (glyph over a block: the block's own page colour)
//
// `run_hl` / `stop_hl` are DELIBERATELY absent from this list. They used to be
// here as `run_hl -> running` / `stop_hl -> stopped`, and that pass-through was
// the mechanism that let the bug ship: falling back to the unselected state
// colour is what painted the state word in a colour with nothing saying "this is
// the highlighted version, and it is a DIFFERENT colour from the bar text".
// Those two roles are computed by `theme_hl_pair_kept`, which is a strictly
// stronger guarantee than "fall back to something", so `ui.palette_of` does not
// call this proc for them.
theme_slot_or :: proc(hex: u32, fallback: u32) -> u32 {
	if (hex & 0xffffff) == 0 { return fallback }
	return hex
}

// theme_rgb splits a palette entry into 0..255 channels.
//
// Explicit shifts rather than a transmute: the caller must be able to see that a
// 0xRRGGBB becomes (R,G,B) with no normalisation anywhere near it.
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
// WCAG 2.1 luminance and contrast — IN THE PRODUCT, NOT JUST IN THE TESTS
//-----------------------------------------------------------------------------
//
// This maths used to live only inside tests/unit/theme_roles_uip2_test.odin, which
// is fine while it is only a measuring stick. It is no longer only a measuring
// stick: the highlight roles are now DERIVED with it (see `theme_hl_pair_kept`
// below), so the number that ships would be produced by the product module and
// judged by a second, hand-copied implementation in the test file. Two copies of
// a formula are two chances to disagree, and the disagreement would show up as a
// test that cannot see the bug it is meant to catch.
//
// So the one implementation lives here and the test file delegates to it.

// theme_srgb_to_linear inverts the sRGB transfer function. The linear segment
// near black is part of the standard, not a shortcut: skipping it mis-ranks dark
// colours, which is exactly the region this module's derivations work in.
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

// theme_contrast_lumina is the ratio from two already-computed luminances. It
// exists so a search that reuses a luminance a hundred times does not pay for
// two `pow` calls per candidate per comparison.
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

//-----------------------------------------------------------------------------
// THE DERIVED HIGHLIGHT PAIR — run_hl / stop_hl
//-----------------------------------------------------------------------------
//
// WHY THESE TWO SLOTS ARE COMPUTED AND NOT AUTHORED
//
// The design directive this replaces: "treat the themes as an ARRAY of colours;
// every element points at a number of that array; you don't figure out colours
// individually for each theme". `run_hl` / `stop_hl` are the two slots where
// per-theme authoring had already gone wrong: six of the ten shipped themes had
// run_hl set to the SAME hex as sel_fg, so the selected row painted its state
// word in the bar's own text colour and the running/stopped distinction
// disappeared at exactly the moment the row was highlighted. A hand-authored
// value can be wrong in ten places; a derivation is wrong or right once.
//
// So a theme authors `running`, `stopped`, `accent` and `sel_fg` — which it
// already had to author anyway — and the highlight pair is derived from those by
// ONE rule that is identical for every theme and for any theme added later.
//
// THE RULE IN ONE SENTENCE
//
//   Blend each state colour toward black or toward white by the SMALLEST amount
//   that leaves the two words legible on the bar, clearly different from the
//   bar's own text, clearly different from EACH OTHER, and still recognisably
//   the colour they started as.
//
// WHY THE SEARCH IS JOINT AND NOT ONE ROLE AFTER THE OTHER
//
// The obvious shape is sequential: derive run_hl against {sel_fg}, then derive
// stop_hl against {sel_fg, run_hl}. It does not work, and measurably so. The
// least-mixing answer for run_hl on its own lands at the TOP of the range that
// is still legible on the bar, which is the worst possible place to leave the
// other role: the band left over for stop_hl shrinks to a width of about
// 0.0007 in luminance, which the 1/64 blend grid cannot land in (it needed a
// grid of roughly 400 to hit it by luck). gruvbox-dark is exactly that case:
// sequential gives run_hl=0x626314 and then no stop_hl exists at all, and the
// prescribed "maximise contrast on the bar" fallback returns 0x000000 — pure
// black, zero spread, 1.28 against sel_fg, i.e. the unchosen-colour sentinel
// painted into the UI.
//
// Minimising t_run + t_stop SUBJECT TO ALL CONSTRAINTS AT ONCE is what lets the
// pair sit where both halves survive. It costs nothing: 129 candidates per role,
// 16,641 pairs, arithmetic on cached luminances.
//
// WHY THE ON-BAR FLOOR FOR THESE TWO ROLES IS 2.0 AND NOT 2.5
//
// NOT a widened threshold — a geometric impossibility at 2.5, stated here so
// the constant reads as reasoned.
//
// Fix the bar and the bar's text. A colour is allowed only if it clears
// `floor_bar` against `accent` AND `floor_distinct` against `sel_fg`. Both
// constraints are functions of luminance alone, so the allowed set is an
// interval (at most two) of luminance, and the MOST contrast two allowed colours
// can have with each other is fixed by that interval:
//
//     allowed:  L <= (Lbar + 0.05)/floor_bar - 0.05      (legible, dark side)
//               L >= floor_distinct*(Lsel + 0.05) - 0.05 (distinct from sel_fg)
//     =>  max mutual = [(Lbar + 0.05)/floor_bar] / [floor_distinct*(Lsel + 0.05)]
//                   = contrast(accent, sel_fg) / (floor_bar * floor_distinct)
//
// Requiring that to reach floor_distinct itself needs
//
//     contrast(accent, sel_fg) >= floor_bar * floor_distinct^2 = 2.5 * 2.56 = 6.4
//
// catppuccin-frappe ships accent=0xca9ee6 and sel_fg=0x292c3c, which measure
// contrast 6.280. The allowed interval is [0.07158, 0.14089] and the largest
// ratio inside it is 1.569 — under the 1.6 the pair must hold. No two colours
// of any hue can satisfy 2.5-on-bar + 1.6-vs-text + 1.6-mutual on that bar.
// Not "we could not find any": the interval does not contain any. That is
// why the derived pair carries its own floor; at 2.0 the same identity needs
// contrast(accent, sel_fg) >= 5.12 and every shipped arrangement clears it.
//
// FLOOR_ON_BAR = 2.5 in the test file is UNCHANGED and stays authoritative for
// every other slot (the caret block, the footer pair, the page). Only these two
// derived roles move, and only as far as the geometry forces.
//
// WHAT EACH CONSTRAINT IS FOR
//
//   on_bar  >= THEME_HL_FLOOR_ON_BAR  the word can be read off the bar at all
//   text    >= THEME_HL_FLOOR_TEXT     THE USER'S RULE: the state word is not
//                                    one of the other highlighted characters
//   mutual  >= THEME_HL_FLOOR_MUTUAL  a selected RUNNING row is not a selected
//                                    STOPPED row (RCH-10 change 5)
//   hue     >= THEME_HL_MIN_SPREAD +  the blend did not grind the state colour
//           channel order intact    into "a dark colour"; green still reads green
//
// IF NOTHING IS FEASIBLE
//
// The function says so (`feasible = false`) and names the constraint that bound,
// with the number it reached. The candidate is still chosen from the pool whose
// hue survived, so the fallback can never hand back pure black, a zero-spread
// grey, or anything that collides with the 0x000000 "nobody chose this" sentinel.
// The test suite is then RED with the theme and the binding constraint named.
// Silent degradation of the state colour is worse than a red suite: it is the
// bug this whole change exists to remove.
//-----------------------------------------------------------------------------

// THEME_HL_MIX_STEPS is the blend grid: t = 0, 1/N, …, 1 toward black and the
// same toward white, `t = 0` (the base unchanged) being a legal answer. 64 and
// not 32 because the feasible band is thin — see the note above on why the
// sequential version needed a grid of ~400 to land in it by accident; 64 is
// where the joint search lands in it on purpose, and 129 candidates per role is
// free.
THEME_HL_MIX_STEPS :: 64

// THEME_HL_CANDIDATES: one base candidate at t=0 plus two directions for every
// other step. Sized by the grid so the search needs no allocator.
THEME_HL_CANDIDATES :: THEME_HL_MIX_STEPS*2 + 1

// THEME_HL_MAX_OTHERS bounds the "must stay away from these colours" list. The
// product passes one (sel_fg); the tests pass up to three.
THEME_HL_MAX_OTHERS :: 3

// The derived pair's floors. `theme_roles_uip2_test` asserts these exact
// numbers so a silent edit here cannot out-argue the proof above.
THEME_HL_FLOOR_ON_BAR :: f64(2.0)
THEME_HL_FLOOR_TEXT   :: f64(1.6)
THEME_HL_FLOOR_MUTUAL :: f64(1.6)
THEME_HL_MIN_SPREAD   :: 8

// theme_hl_mix_channel is the per-channel blend: round(x*(1-t) + y*t).
theme_hl_mix_channel :: proc(x, y: u32, t: f64) -> u32 {
	return u32(math.round(f64(x) * (1.0 - t) + f64(y) * t))
}

// theme_hl_mix blends two colours, one step at a time. `t = 0` returns the base
// unchanged, which is a legal answer to the derivation and is kept that way.
theme_hl_mix :: proc(c, e: u32, t: f64) -> u32 {
	r := theme_hl_mix_channel((c >> 16) & 0xff, (e >> 16) & 0xff, t)
	g := theme_hl_mix_channel((c >> 8) & 0xff, (e >> 8) & 0xff, t)
	b := theme_hl_mix_channel(c & 0xff, e & 0xff, t)
	return (r << 16) | (g << 8) | b
}

// theme_hl_channel reads channel i (0=R, 1=G, 2=B) of a palette entry.
theme_hl_channel :: proc(hex: u32, i: int) -> i32 {
	if i == 0 { return i32((hex >> 16) & 0xff) }
	if i == 1 { return i32((hex >> 8) & 0xff) }
	return i32(hex & 0xff)
}

// theme_hl_spread is max-channel minus min-channel: the crude but honest "is
// there any colour left in this" measure. A blend toward black or white scales
// the spread by (1-t), so the spread is a direct read on how much of the base
// colour the mix kept.
theme_hl_spread :: proc(hex: u32) -> i32 {
	mx := theme_hl_channel(hex, 0)
	mn := theme_hl_channel(hex, 0)
	for i in 1..=2 {
		v := theme_hl_channel(hex, i)
		if v > mx { mx = v }
		if v < mn { mn = v }
	}
	return mx - mn
}

// theme_hl_hue_kept is the "still recognisably its own colour" test:
//
//   * every pairwise channel ORDER the base had is still there, and every pair
//     the base drew level is still level — a blend toward black or white cannot
//     flip an order, but rounding can collapse a near-tie, and a collapsed tie
//     is a lost piece of the hue, so it is rejected rather than excused;
//   * the spread has not been mixed away below `min_spread`.
theme_hl_hue_kept :: proc(cand, base: u32, min_spread: i32) -> bool {
	for i in 0..=2 {
		for j := i + 1; j <= 2; j += 1 {
			cb := theme_hl_channel(base, i) - theme_hl_channel(base, j)
			cc := theme_hl_channel(cand, i) - theme_hl_channel(cand, j)
			if cb == 0 {
				if cc != 0 { return false }
			} else if cc * cb <= 0 {
				return false
			}
		}
	}
	return theme_hl_spread(cand) >= min_spread
}

// Theme_Hl_Cand is one blend of one base colour with every number the pair
// search compares cached, so the inner loop is arithmetic only.
Theme_Hl_Cand :: struct {
	hex      : u32,
	t        : f64,
	lum      : f64,
	sprd     : i32,
	on_bar   : f64, // contrast against the highlight bar
	text_min : f64, // worst contrast against the colours it must stay clear of
	hue_ok   : bool,
	self_ok  : bool, // on_bar, text_min and hue all clear their floors
}

// Theme_Hl_Pair is the answer: the two derived roles, plus whether they were
// actually derivable under the floors and, if they were not, what stopped us.
Theme_Hl_Pair :: struct {
	run_hl   : u32,
	stop_hl  : u32,
	feasible : bool,
	binding  : string, // "" when feasible
}

// theme_hl_fill_candidates builds one role's blend ladder: t = 0 (the base
// itself) then both directions for every step, with the contrasts, the spread
// and the floor verdicts computed once per candidate. `others` is the set of
// colours this role must stay distinguishable from — the bar's own text, in the
// product. No allocator: the ladder is sized by THEME_HL_CANDIDATES.
theme_hl_fill_candidates :: proc(dst: ^[THEME_HL_CANDIDATES]Theme_Hl_Cand,
                               base, bar: u32, others: []u32,
                               floor_bar, floor_distinct: f64,
                               min_spread: i32) -> int {
	bar_lum := theme_luma(bar)
	oth_lum : [THEME_HL_MAX_OTHERS]f64
	for o, k in others { oth_lum[k] = theme_luma(o) }

	n := 0
	for i in 0..=THEME_HL_MIX_STEPS {
		t := f64(i) / f64(THEME_HL_MIX_STEPS)
		for d in 0..=1 {
			if i == 0 && d == 1 { continue } // t =0 is the base; do it once
			e: u32 = 0x000000
			if d == 1 { e = 0xffffff }
			c := &dst[n]
			c.hex = theme_hl_mix(base, e, t)
			c.t = t
			c.lum = theme_luma(c.hex)
			c.sprd = theme_hl_spread(c.hex)
			c.on_bar = theme_contrast_lumina(c.lum, bar_lum)
			c.text_min = f64(1.0e18)
			for k in 0..<len(others) {
				v := theme_contrast_lumina(c.lum, oth_lum[k])
				if v < c.text_min { c.text_min = v }
			}
			c.hue_ok = theme_hl_hue_kept(c.hex, base, min_spread)
			c.self_ok = c.on_bar >= floor_bar && c.hue_ok
			if len(others) > 0 { c.self_ok = c.self_ok && c.text_min >= floor_distinct }
			n += 1
		}
	}
	return n
}

// theme_hl_pair_kept is THE derivation. The block comment above the constants
// states what it guarantees and why the search is joint.
theme_hl_pair_kept :: proc(run_base, stop_base, bar: u32, others: []u32,
                          floor_bar, floor_distinct, floor_mutual: f64,
                          min_spread: i32) -> Theme_Hl_Pair {
	assert(len(others) <= THEME_HL_MAX_OTHERS,
	       "theme_hl_pair_kept: more `others` than THEME_HL_MAX_OTHERS")

	run_c : [THEME_HL_CANDIDATES]Theme_Hl_Cand
	stop_c : [THEME_HL_CANDIDATES]Theme_Hl_Cand
	n_run := theme_hl_fill_candidates(&run_c, run_base, bar, others,
	                                 floor_bar, floor_distinct, min_spread)
	n_stop := theme_hl_fill_candidates(&stop_c, stop_base, bar, others,
	                                  floor_bar, floor_distinct, min_spread)

	// ── pass 1: least TOTAL mixing among the pairs that clear everything ──
	// Minimising the sum is what makes this joint: a role is allowed to mix MORE
	// than it would have on its own if that is what leaves the other role a
	// place to sit. `peak` breaks ties toward the pair that does not hammer one
	// role while leaving the other untouched.
	best_t := f64(1.0e18)
	best_peak := f64(1.0e18)
	found := false
	ri, si := 0, 0
	for a in 0..<n_run {
		if !run_c[a].self_ok { continue }
		for b in 0..<n_stop {
			if !stop_c[b].self_ok { continue }
			if theme_contrast_lumina(run_c[a].lum, stop_c[b].lum) < floor_mutual { continue }
			sum := run_c[a].t + stop_c[b].t
			peak := run_c[a].t
			if stop_c[b].t > peak { peak = stop_c[b].t }
			if sum < best_t - 1.0e-9 ||
			   (math.abs(sum - best_t) < 1.0e-9 && peak < best_peak) {
				found = true
				best_t, best_peak, ri, si = sum, peak, a, b
			}
		}
	}
	if found {
		return Theme_Hl_Pair{run_c[ri].hex, stop_c[si].hex, true, ""}
	}

	// ── pass 2: no pair clears every floor — degrade LOUDLY ──────────────
	// Hue-kept candidates only, in BOTH roles, so the fallback can never hand
	// back pure black, a zero-spread grey, or a value that reads as the
	// 0x000000 "nobody chose this" sentinel. Of those, take the pair whose
	// WORST normalised margin is the largest — as close to every floor as the
	// geometry allows — and name the one that bound, with the number reached.
	best_min := f64(-1.0)
	best_label := ""
	for a in 0..<n_run {
		if !run_c[a].hue_ok { continue }
		for b in 0..<n_stop {
			if !stop_c[b].hue_ok { continue }
			mu := theme_contrast_lumina(run_c[a].lum, stop_c[b].lum)
			m := run_c[a].on_bar / floor_bar
			lab := "on_bar(run)"
			vb := stop_c[b].on_bar / floor_bar
			if vb < m { m, lab = vb, "on_bar(stop)" }
			if len(others) > 0 {
				vt := run_c[a].text_min / floor_distinct
				if vt < m { m, lab = vt, "vs_sel_fg(run)" }
				vt = stop_c[b].text_min / floor_distinct
				if vt < m { m, lab = vt, "vs_sel_fg(stop)" }
			}
			vm := mu / floor_mutual
			if vm < m { m, lab = vm, "mutual" }
			sum := run_c[a].t + stop_c[b].t
			if m > best_min + 1.0e-9 || (math.abs(m - best_min) < 1.0e-9 && sum < best_t) {
				best_min, best_t, best_label, ri, si = m, sum, lab, a, b
			}
		}
	}
	if best_min < 0 {
		// Not one candidate kept its hue in at least one role: that base colour
		// is too flat to survive any legible position on this bar. Return the
		// least hue-destroyed candidate of each role and say so.
		for a in 0..<n_run {
			if run_c[a].sprd > run_c[ri].sprd { ri = a }
		}
		for b in 0..<n_stop {
			if stop_c[b].sprd > stop_c[si].sprd { si = b }
		}
		best_label = fmt.tprintf("hue: no candidate of either role keeps spread >= {}", min_spread)
	}
	return Theme_Hl_Pair{run_c[ri].hex, stop_c[si].hex, false,
	                    fmt.tprintf("{} bound at {:.3f}x its floor", best_label, best_min)}
}

// theme_hl_pair_of is the product's own view of the rule: the pair for a
// palette, with the shipped floors. `ui.palette_of` calls this and so does the
// test that proves the roles are derived rather than authored — one call, one
// set of floors, no chance for the two to drift.
theme_hl_pair_of :: proc(p: Palette) -> Theme_Hl_Pair {
	return theme_hl_pair_kept(p.running, p.stopped, p.accent, []u32{p.sel_fg},
	                          THEME_HL_FLOOR_ON_BAR, THEME_HL_FLOOR_TEXT,
	                          THEME_HL_FLOOR_MUTUAL, THEME_HL_MIN_SPREAD)
}

//-----------------------------------------------------------------------------
// Theme identity
//-----------------------------------------------------------------------------

// Theme is one selectable entry: its canonical name, the names that also resolve
// to it, and its colours.
Theme :: struct {
	name    : string,   // canonical, kebab-case — what the config stores
	aliases : []string, // tolerant spellings for CONFIG resolution only
	pal     : Palette,
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
// THE SET
//
// Ten themes. The plan defers the size of the set ("extend later"), so the bar
// used here was: every value present in scout-nix-packaging.md §f with a cited
// upstream file, a coherent 13-slot mapping, and both required names.
//
// You will not find `run_hl` or `stop_hl` in any of the literals below. That is
// the point: those two are derived (see `theme_hl_pair_kept`), so a theme
// cannot get them wrong and a new theme does not have to choose them. Every
// other slot is authored here from its cited upstream colour.
//
// Aliases are deliberately NARROW: they exist so a hand-edited config written
// with the flavour word ("latte") rather than the canonical id still resolves.
// The picker's filter is a substring match over the canonical names, so
// "latte", "catppuccin" and "c-latte" all narrow the list without help from
// this field — see the note on theme_matches.
//-----------------------------------------------------------------------------

THEMES : [10]Theme = {
	// ── gruvbox-dark: the default (D4) ─────────────────────────────────
	// Source: gruvbox_256palette.sh. accent = bright yellow (gruvbox's own
	// highlight colour); sel_fg is dark0_hard so the bar stays readable.
	{
		name    = "gruvbox-dark",
		aliases = []string{"gruvbox", "gruvbox_dark"},
		pal = Palette{
			bg        = 0x282828, // dark0
			fg        = 0xebdbb2, // fg1
			dim       = 0xd5c4a1, // fg2
			border    = 0x504945, // dark2
			header_fg = 0xebdbb2, // fg1
			accent    = 0xd79921, // bright yellow
			sel_fg    = 0x1d2021, // dark0_hard
			caret     = 0xfe8019, // orange
			float_bg  = 0x32302f, // dark0_medium
			float_fg  = 0xebdbb2, // fg1
			err_fg    = 0xfb4934, // red
			running   = 0xb8bb26, // green
			stopped   = 0x928374, // gray
			key_fg    = 0xfabd2f, // bright yellow — the footer hunt-token
			desc_fg   = 0xa89984, // fg4 — muted against the key
			caret_bg  = 0xfe8019, // orange — == caret, the block the glyph sits in
			caret_fg  = 0x1d2021, // dark0_hard — the glyph knocked out of the block
		},
	},

	// ── gruvbox-light ──────────────────────────────────────────────────
	{
		name    = "gruvbox-light",
		aliases = []string{"gruvbox_light"},
		pal = Palette{
			bg        = 0xfbf1c7, // light0
			fg        = 0x3c3836, // dark1
			dim       = 0x504945, // dark2
			border    = 0xd5c4a1, // light3
			header_fg = 0x3c3836, // dark1
			accent    = 0xb57614, // dark yellow
			sel_fg    = 0xfbf1c7, // light0
			caret     = 0xaf3a03, // dark orange
			float_bg  = 0xf9f5d7, // light0_h
			float_fg  = 0x3c3836, // dark1
			err_fg    = 0x9d0006, // neutral red
			running   = 0x79740e, // neutral green
			stopped   = 0x928374, // mid gray (documented neutral)
			key_fg    = 0x076678, // faded blue — reads as the token, not the prose
			desc_fg   = 0x928374, // mid gray — muted against the key
			caret_bg  = 0xaf3a03, // dark orange — == caret
			caret_fg  = 0xfbf1c7, // light0 — the glyph knocked out of the block
		},
	},

	// ── catppuccin-latte: REQUIRED, and explicitly NOT the default ─────
	// Source: catppuccin/palette palette.json v1.8.0. The canonical spelling is
	// `catppuccin-latte` (the user wrote "catputin"); the misspelling is an
	// alias so the config forgives but the product name stays correct.
	{
		name    = "catppuccin-latte",
		aliases = []string{"latte", "catppuccin", "catpuccin-latte", "catppuccin_latte"},
		pal = Palette{
			bg        = 0xeff1f5, // base
			fg        = 0x4c4f69, // text
			dim       = 0x6c6f85, // subtext0
			border    = 0xbcc0cc, // surface1
			header_fg = 0x4c4f69, // text
			accent    = 0x8839ef, // mauve
			sel_fg    = 0xeff1f5, // base
			caret     = 0xfe640b, // peach
			float_bg  = 0xe6e9ef, // mantle
			float_fg  = 0x4c4f69, // text
			err_fg    = 0xd20f39, // red
			running   = 0x40a02b, // green
			stopped   = 0x9ca0b0, // overlay0
			// NOTE: `key_fg` repeats the accent hex. That is a deliberate choice,
			// not a laziness — latte has no second saturated colour that clears the
			// 4.5:1 floor for a text token on `base`, and mauve is the theme's own
			// "look here" colour. The roles stay distinct from the bar by context
			// (footer vs row) and the contrast is proven by the test either way.
			key_fg    = 0x8839ef, // mauve
			desc_fg   = 0x8c8fa1, // overlay1 — muted against the key
			// NOTE: the caret block is `blue`, not latte's own peach `caret` slot.
			// A peach block with base knocked out measures 2.6:1, under the 3.0:1
			// floor this palette enforces for a caret glyph; no documented latte
			// colour pairs with peach above it. Blue gives 4.3:1. Deviation flagged.
			caret_bg  = 0x1e66f5, // blue
			caret_fg  = 0xeff1f5, // base
		},
	},

	{
		name    = "catppuccin-frappe",
		aliases = []string{"frappe"},
		pal = Palette{
			bg        = 0x303446, // base
			fg        = 0xc6d0f5, // text
			dim       = 0xa5adce, // subtext0
			border    = 0x51576d, // surface1
			header_fg = 0xc6d0f5, // text
			accent    = 0xca9ee6, // mauve
			sel_fg    = 0x292c3c, // mantle
			caret     = 0xef9f76, // peach
			float_bg  = 0x292c3c, // mantle
			float_fg  = 0xc6d0f5, // text
			err_fg    = 0xe78284, // red
			running   = 0xa6d189, // green
			stopped   = 0x737994, // overlay0
			key_fg    = 0xe5c890, // yellow — the footer hunt-token
			desc_fg   = 0x838ba7, // overlay1 — muted against the key
			caret_bg  = 0xef9f76, // peach — == caret
			caret_fg  = 0x232634, // crust — the glyph knocked out of the block
		},
	},

	{
		name    = "catppuccin-macchiato",
		aliases = []string{"macchiato"},
		pal = Palette{
			bg        = 0x24273a, // base
			fg        = 0xcad3f5, // text
			dim       = 0xa5adcb, // subtext0
			border    = 0x494d64, // surface1
			header_fg = 0xcad3f5, // text
			accent    = 0xc6a0f6, // mauve
			sel_fg    = 0x1e2030, // mantle
			caret     = 0xf5a97f, // peach
			float_bg  = 0x1e2030, // mantle
			float_fg  = 0xcad3f5, // text
			err_fg    = 0xed8796, // red
			running   = 0xa6da95, // green
			stopped   = 0x6e738d, // overlay0
			key_fg    = 0xeed49f, // yellow — the footer hunt-token
			desc_fg   = 0x8087a2, // overlay1 — muted against the key
			caret_bg  = 0xf5a97f, // peach — == caret
			caret_fg  = 0x181926, // crust — the glyph knocked out of the block
		},
	},

	{
		name    = "catppuccin-mocha",
		aliases = []string{"mocha"},
		pal = Palette{
			bg        = 0x1e1e2e, // base
			fg        = 0xcdd6f4, // text
			dim       = 0xa6adc8, // subtext0
			border    = 0x45475a, // surface1
			header_fg = 0xcdd6f4, // text
			accent    = 0xcba6f7, // mauve
			sel_fg    = 0x181825, // mantle
			caret     = 0xfab387, // peach
			float_bg  = 0x181825, // mantle
			float_fg  = 0xcdd6f4, // text
			err_fg    = 0xf38ba8, // red
			running   = 0xa6e3a1, // green
			stopped   = 0x6c7086, // overlay0
			key_fg    = 0xf9e2af, // yellow — the footer hunt-token
			desc_fg   = 0x7f849c, // overlay1 — muted against the key
			caret_bg  = 0xfab387, // peach — == caret
			caret_fg  = 0x11111b, // crust — the glyph knocked out of the block
		},
	},

	// ── tokyonight-night ───────────────────────────────────────────────
	{
		name    = "tokyonight-night",
		aliases = []string{"tokyonight", "tokyo-night", "tokyo_night"},
		pal = Palette{
			bg        = 0x1a1b26, // bg
			fg        = 0xc0caf5, // fg
			dim       = 0xa9b1d6, // fg
			border    = 0x3b4261, // fg_gutter
			header_fg = 0xc0caf5, // fg
			accent    = 0x7aa2f7, // blue
			sel_fg    = 0x1a1b26, // bg
			caret     = 0xff9e64, // orange
			float_bg  = 0x16161e, // bg_dark
			float_fg  = 0xc0caf5, // fg
			err_fg    = 0xf7768e, // red
			running   = 0x9ece6a, // green
			stopped   = 0x565f89, // comment
			key_fg    = 0xe0af68, // yellow — the footer hunt-token
			desc_fg   = 0x565f89, // comment — muted against the key
			caret_bg  = 0xff9e64, // orange — == caret
			caret_fg  = 0x0c0e14, // bg_crust — the glyph knocked out of the block
		},
	},

	// ── nord: nord0..nord15 maps 1:1 onto the slots ───────────────────
	{
		name    = "nord",
		aliases = []string{"nord-theme", "nordtheme"},
		pal = Palette{
			bg        = 0x2e3440, // nord0
			fg        = 0xe5e9f0, // nord5
			dim       = 0xd8dee9, // nord4
			border    = 0x4c566a, // nord3
			header_fg = 0xeceff4, // nord6
			accent    = 0x88c0d0, // nord8 (frost)
			sel_fg    = 0x2e3440, // nord0
			caret     = 0xd08770, // nord12
			float_bg  = 0x3b4252, // nord1
			float_fg  = 0xe5e9f0, // nord5
			err_fg    = 0xbf616a, // nord11
			running   = 0xa3be8c, // nord14
			stopped   = 0x4c566a, // nord3
			key_fg    = 0xebcb8b, // nord13 — the footer hunt-token
			desc_fg   = 0x5e81ac, // nord10 — muted against the key
			caret_bg  = 0xd08770, // nord12 — == caret
			caret_fg  = 0x2e3440, // nord0 — the glyph knocked out of the block
		},
	},

	// ── solarized ──────────────────────────────────────────────────────
	// Dark and light share the accent set exactly; only the monotone pairs swap
	// (base03<->base3, base02<->base2, base01<->base1, base00<->base0).
	{
		name    = "solarized-dark",
		aliases = []string{"solarized", "solarized_dark"},
		pal = Palette{
			bg        = 0x002b36, // base03
			fg        = 0x839496, // base0
			dim       = 0x586e75, // base01
			border    = 0x073642, // base02
			header_fg = 0x93a1a1, // base1
			accent    = 0x268bd2, // blue
			sel_fg    = 0x002b36, // base03
			caret     = 0xcb4b16, // orange
			float_bg  = 0x073642, // base02
			float_fg  = 0x839496, // base0
			err_fg    = 0xdc322f, // red
			running   = 0x859900, // green
			stopped   = 0x586e75, // base01
			key_fg    = 0xb58900, // yellow — the footer hunt-token
			desc_fg   = 0x586e75, // base01 — muted against the key
			caret_bg  = 0xcb4b16, // orange — == caret
			caret_fg  = 0x002b36, // base03 — the glyph knocked out of the block
		},
	},

	{
		name    = "solarized-light",
		aliases = []string{"solarized_light"},
		pal = Palette{
			bg        = 0xfdf6e3, // base3
			fg        = 0x657b83, // base00
			dim       = 0x93a1a1, // base1
			border    = 0xeee8d5, // base2
			header_fg = 0x586e75, // base01
			accent    = 0x268bd2, // blue (identical in both modes)
			sel_fg    = 0xfdf6e3, // base3
			caret     = 0xcb4b16, // orange
			float_bg  = 0xeee8d5, // base2
			float_fg  = 0x657b83, // base00
			err_fg    = 0xdc322f, // red
			running   = 0x859900, // green
			stopped   = 0x93a1a1, // base1
			key_fg    = 0x586e75, // base01 — the footer hunt-token on cream
			desc_fg   = 0x839496, // base0 — muted against the key
			caret_bg  = 0xcb4b16, // orange — == caret
			caret_fg  = 0xfdf6e3, // base3 — the glyph knocked out of the block
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
// a second entry in it. Listing both would let the user "pick" two names for one
// palette and then the config would disagree with the screen.
//
// The picker's *filter* is `theme_matches`, which lives with the state machine in
// state.odin and is a case-insensitive substring test over the canonical name.
// The alias list is deliberately NOT consulted there: the filter narrows a list
// the user is looking at, and showing `latte` and `catppuccin-latte` as two rows
// for one palette would misreport how many themes exist. Aliases belong to
// config resolution (theme_resolve), where the user typed a name and meant one.
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
// naming something we do not ship. It is a lookup, so the default can never be a
// palette that drifted away from the table.
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
// The three answers are why this returns a kind rather than a bool: ISC-19 needs
// an unknown name to be LOUD (a warning) and an absent name to be SILENT (a
// default). A bool would collapse the two and the footer would either spam on a
// fresh install or stay quiet over a typo.
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

// Unknown_Theme_Message is the one line ISC-19 asks for: it names the value that
// was wrong, what is being used instead, and where the list lives.
Unknown_Theme_Message :: proc(requested: string) -> string {
	return fmt.tprintf(
		"unknown theme '%s' - using %s (available: %s)",
		requested, THEME_DEFAULT_NAME, theme_list_string(context.allocator))
}

// theme_list_string is the shipped set, canonical spelling, in picker order.
//
// strings.join, not `+`: Odin does not concatenate strings with an operator (the
// plan's trap list), and the result is allocated from the caller's allocator.
theme_list_string :: proc(alloc: runtime.Allocator) -> string {
	names, _ := theme_names(alloc)
	joined, _ := strings.join(names, ", ", alloc)
	return joined
}
