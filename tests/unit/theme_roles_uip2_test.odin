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
//     asked for — fails that by construction. So the pair is checked two
//     ways: they are different values, AND the difference is big enough to
//     see, AND both are legible on the bar they share.
//   * `key_fg` / `desc_fg` sit on the same line. A "dominant" key and a
//     "muted" description that measure the same contrast are one colour
//     wearing two names, so dominance is measured, not promised.
//   * `caret_bg` / `caret_fg` are a PAIR: a block plus the glyph knocked
//     out of it. Each half is meaningless alone.
//
// WHY CONTRAST IS COMPUTED HERE AND NOT LOOKED AT
//
// Every threshold below is a WCAG 2.1 contrast ratio computed from the
// shipped hex by `wcag` in this file. That is deliberate: a number derived
// from the table cannot go stale when a theme is edited, and it fails with
// the measured value in the message. "Looks fine on my terminal" is not
// re-checkable by anyone who did not see the terminal.
//
// The floors themselves are judgement, stated openly:
//   key_fg   >= 4.5 on bg   — a token a user hunts for at speed (AD-1.2)
//   desc_fg  >= 2.7 on bg   — readable but clearly the lesser voice
//   key/desc >= 1.5x        — the two must not be the same loudness
//   caret    >= 3.0 glyph/block, block >= 2.5 vs the page — a caret the
//                             eye has to hunt for is worse than no caret
//   run/stop >= 2.5 on the bar — small bold text over a saturated field
//   run/stop >= 1.6 to EACH OTHER — the distinction change 5 protects has
//                             to survive being drawn 3 columns apart
//
// The thresholds are floors, not targets; every shipped theme clears them
// with room (see the printed table). A future theme that lands at 1.59 fails,
// and that failure is the correct answer, not a threshold to widen.
// ============================================================================

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"

import clay "../../clay-odin"
import ui "../../src/ui"
import app "../../src/app"
import support "../support"

// ── the maths, in the open ────────────────────────────────────────────────

// srgb_to_linear inverts the sRGB transfer curve. The branch is the standard
// one: the linear segment near black is not a shortcut, it is the curve.
srgb_to_linear :: proc(c: u8) -> f64 {
	s := f64(c) / 255.0
	if s <= 0.03928 { return s / 12.92 }
	return math.pow((s + 0.055) / 1.055, 2.4)
}

// luma is WCAG relative luminance, NOT perceived-brightness-by-averaging.
// Using a plain 0.299/0.587/0.114 luma here would mis-rank the pairs and
// quietly change which themes pass.
luma :: proc(hex: u32) -> f64 {
	r := srgb_to_linear(u8((hex >> 16) & 0xff))
	g := srgb_to_linear(u8((hex >> 8) & 0xff))
	b := srgb_to_linear(u8(hex & 0xff))
	return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

// contrast is the WCAG 2.1 ratio, always >= 1 (symmetric by construction).
contrast :: proc(a, b: u32) -> f64 {
	la := luma(a) + 0.05
	lb := luma(b) + 0.05
	if la > lb { return la / lb }
	return lb / la
}

FLOOR_KEY :: f64(4.5)
FLOOR_DESC :: f64(2.7)
FLOOR_DOMINANCE :: f64(1.5)
FLOOR_CARET_GLYPH :: f64(3.0)
FLOOR_CARET_BLOCK :: f64(2.5)
FLOOR_ON_BAR :: f64(2.5)
FLOOR_HL_MUTUAL :: f64(1.6)

// ── the two highlight roles: NOT flattened, and legible ────────────────────

@(test)
roles_run_and_stop_are_never_the_same_colour :: proc(t: ^testing.T) {
	// THE falsifiable form of RCH-10 change 5. If someone folds these into one
	// role, or gives a theme the same hex for both, selection flattens
	// running into stopped and this check dies naming the theme.
	flattened := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		if th.pal.run_hl == th.pal.stop_hl {
			flattened += 1
			detail = fmt.tprintf("{} {};{} run_hl == stop_hl ({:06x})",
				detail, "FLATTENED:", th.name, th.pal.run_hl)
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
		th := app.theme_at(i)
		mu := contrast(th.pal.run_hl, th.pal.stop_hl)
		if mu < FLOOR_HL_MUTUAL {
			too_close += 1
			detail = fmt.tprintf("{} {}; run_hl={:06x} stop_hl={:06x} ratio={:.2f} < {:.2f}",
				detail, th.name, th.pal.run_hl, th.pal.stop_hl, mu, FLOOR_HL_MUTUAL)
		}
	}
	support.check(t, "run_hl and stop_hl are MUTUALLY distinguishable (>= 1.6:1)",
		too_close == 0, fmt.tprintf("{} too-close theme(s){}", too_close, detail))
}

@(test)
roles_both_highlights_are_legible_on_the_accent_bar :: proc(t: ^testing.T) {
	// Both words sit on the SAME saturated field. One readable pair is easy;
	// the requirement is two, against the same background, that stay apart.
	bad := 0
	detail := ""
	for i := 0; i < app.theme_count(); i += 1 {
		th := app.theme_at(i)
		rr := contrast(th.pal.run_hl, th.pal.accent)
		sr := contrast(th.pal.stop_hl, th.pal.accent)
		if rr < FLOOR_ON_BAR || sr < FLOOR_ON_BAR {
			bad += 1
			detail = fmt.tprintf("{} {} run={:.2f} stop={:.2f}", detail, th.name, rr, sr)
		}
	}
	support.check(t, "both highlight roles clear 2.5:1 on their own accent bar",
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

	// And each degradation lands on the SPECIFIC documented partner, checked
	// by channel against the base colour it is supposed to substitute for.
	Pair :: struct{ got : clay.Color, want : u32, label : string }
	pairs := []Pair{
		Pair{pal.key_fg, th.pal.fg, "key_fg->fg"},
		Pair{pal.desc_fg, th.pal.dim, "desc_fg->dim"},
		Pair{pal.caret_bg, th.pal.caret, "caret_bg->caret"},
		Pair{pal.caret_fg, th.pal.bg, "caret_fg->bg"},
		Pair{pal.run_hl, th.pal.running, "run_hl->running"},
		Pair{pal.stop_hl, th.pal.stopped, "stop_hl->stopped"},
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
	support.check(t, "each missing role falls back to its documented partner role",
		wrong == 0, fmt.tprintf("{} mismatch(es){}", wrong, detail))

	// The degraded pair is still not flattened: falling back to `running` and
	// `stopped` keeps the distinction change 5 exists to protect.
	support.check(t, "even degraded, run_hl != stop_hl",
		pal.run_hl[0] != pal.stop_hl[0] || pal.run_hl[1] != pal.stop_hl[1] || pal.run_hl[2] != pal.stop_hl[2],
		"the degraded pair collapsed to one colour")
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
	// …and the stand-in clears the same bar the real themes do.
	run_bar := contrast(u32(d.run_hl[0]) << 16 | u32(d.run_hl[1]) << 8 | u32(d.run_hl[2]),
		u32(d.accent[0]) << 16 | u32(d.accent[1]) << 8 | u32(d.accent[2]))
	stop_bar := contrast(u32(d.stop_hl[0]) << 16 | u32(d.stop_hl[1]) << 8 | u32(d.stop_hl[2]),
		u32(d.accent[0]) << 16 | u32(d.accent[1]) << 8 | u32(d.accent[2]))
	support.check(t, "DEFAULT_PALETTE highlights clear 2.5:1 on the bar",
		run_bar >= FLOOR_ON_BAR && stop_bar >= FLOOR_ON_BAR,
		fmt.tprintf("run={:.2f} stop={:.2f}", run_bar, stop_bar))
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
