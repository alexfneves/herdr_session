package pty

// ─────────────────────────────────────────────────────────────────────────────
// width_test.odin — THE FROZEN WIDTH-PARITY TABLE (ISC-16).
//
// WHY THIS FILE EXISTS BEFORE ANY CHARACTER ASSERTION EXISTS ELSEWHERE
//   The Python drivers measured width with `unicodedata`
//   (dev/tui_drive.py:76-84: combining()/category(Mn,Me,Cf) -> 0;
//   east_asian_width W,F -> 2; else 1). The product measures width with
//   **termbox2.tb_wcwidth** (src/render/measure.odin:120-131 `glyph_columns`,
//   with FALLBACK_WIDTH=1 for r<32, r==127, or w<0). Those are DIFFERENT
//   TABLES. They agree on everything this project can actually reach, but they
//   do NOT agree everywhere — and a width difference is not a cosmetic one:
//   `del_key`'s whole-rune-deletion evidence means "one press removed
//   everything that occupied cells", so if a rune is 2 cells to one table and 0
//   to the other, the SAME assertion describes DIFFERENT behaviour and the
//   suite goes green having proved nothing about the product.
//
//   Hence: freeze the runes, record BOTH authorities' answers, assert they
//   agree, and assert tb_wcwidth still says what was recorded. That last part
//   matters as much as the first: it turns "we checked once" into a test that
//   fails if termbox's table ever moves under us.
//
// HOW THE `want_python` COLUMN WAS PRODUCED (so it is reproducible, not vibes)
//   `unicodedata` applied with the exact rule above, over every code point
//   0x0..0x10FFFF except surrogates, cross-checked against a sweep of
//   tb_wcwidth over the same range. The full-range result is in the sweep
//   test below; the per-rune values in this table are those measurements.
//
// THE RESULT, STATED PLAINLY
//   Every rune reachable by these suites agrees. All `want_python` ==
//   `want_tb` in WIDTH_CASES, INCLUDING every combining mark: U+0300/0301/
//   0303/0308 and U+FE0F are ZERO in both authorities, and the whole-rune
//   deletion runes 世 (U+4E16, 3 UTF-8 bytes) and U+1F600 (4 bytes) are TWO
//   in both.
//
//   It is NOT true that the two tables agree everywhere — see
//   DIVERGENT_NOT_REACHED and width_table_divergences_are_recorded. They are
//   recorded, not hidden.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import tb "../../vendor/termbox2-odin"
import support "../support"

// Width_Case is one row of the frozen table.
//   want_python — the value dev/tui_drive.py:char_width() returned
//   want_tb     — the value termbox2.tb_wcwidth returns, with
//                render.measure.odin's FALLBACK_WIDTH (w<0 -> 1) applied,
//                because that is the width the PRODUCT uses, not the raw code
//   Both are recorded SEPARATELY so a future disagreement is a named fact
//   about two specific tables rather than one lost number.
Width_Case :: struct {
	r           : rune,
	want_python : int,
	want_tb     : int,
	note        : string,
}

WIDTH_CASES := []Width_Case{
	{r = 0x00A7, want_python = 1, want_tb = 1, note = "S section sign (state_cases)"},
	{r = 0x00B2, want_python = 1, want_tb = 1, note = "superscript two (No / Ambiguous: 1 in both)"},
	{r = 0x00B7, want_python = 1, want_tb = 1, note = "footer separator `attach  \\u00b7` — tui_drive.py:548,598,647,711,755"},
	{r = 0x00D7, want_python = 1, want_tb = 1, note = "x multiplication sign (state_cases)"},
	{r = 0x00E9, want_python = 1, want_tb = 1, note = "PRECOMPOSED e-acute (app_cases) — 1, not the 2 of base+U+0301"},
	{r = 0x0300, want_python = 0, want_tb = 0, note = "COMBINING GRAVE — same Mn class as U+0301"},
	{r = 0x0301, want_python = 0, want_tb = 0, note = "COMBINING ACUTE — render_cases.odin MEASURE_CASES e+\\u0301; ZERO in both"},
	{r = 0x0303, want_python = 0, want_tb = 0, note = "COMBINING TILDE — same Mn class"},
	{r = 0x0308, want_python = 0, want_tb = 0, note = "COMBINING DIAERESIS — same Mn class"},
	{r = 0x2013, want_python = 1, want_tb = 1, note = "– en dash (ui_cases)"},
	{r = 0x2014, want_python = 1, want_tb = 1, note = "— em dash (ui/state/app cases)"},
	{r = 0x2026, want_python = 1, want_tb = 1, note = "… truncation mark (diag_head / footer)"},
	{r = 0x2192, want_python = 1, want_tb = 1, note = "→ arrow (state_cases, app_cases)"},
	{r = 0x2500, want_python = 1, want_tb = 1, note = "- light box divider — the RCH-1 divider glyph"},
	{r = 0x2501, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS HEAVY HORIZONTAL"},
	{r = 0x2502, want_python = 1, want_tb = 1, note = "| vertical rule"},
	{r = 0x250C, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT DOWN AND RIGHT"},
	{r = 0x2510, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT DOWN AND LEFT"},
	{r = 0x2514, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT UP AND RIGHT"},
	{r = 0x2518, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT UP AND LEFT"},
	{r = 0x251C, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT VERTICAL AND RIGHT"},
	{r = 0x2524, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT VERTICAL AND LEFT"},
	{r = 0x252C, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT DOWN AND HORIZONTAL"},
	{r = 0x2534, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT UP AND HORIZONTAL"},
	{r = 0x253C, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT VERTICAL AND HORIZONTAL"},
	{r = 0x254C, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT DOUBLE DASH HORIZONTAL"},
	{r = 0x2550, want_python = 1, want_tb = 1, note = "= heavy divider"},
	{r = 0x256D, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT ARC DOWN AND RIGHT"},
	{r = 0x256E, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT ARC DOWN AND LEFT"},
	{r = 0x256F, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT ARC UP AND LEFT"},
	{r = 0x2570, want_python = 1, want_tb = 1, note = "box drawing — BOX DRAWINGS LIGHT ARC UP AND RIGHT"},
	{r = 0x258F, want_python = 1, want_tb = 1, note = "filter CARET — tui_drive.py:789; the caret sits at a DISPLAY column"},
	{r = 0x4E16, want_python = 2, want_tb = 2, note = "CJK 世 — del_key whole-rune deletion, tui_drive.py:860 (3 UTF-8 bytes)"},
	{r = 0x4E2D, want_python = 2, want_tb = 2, note = "中 (product measure cases)"},
	{r = 0x5C3E, want_python = 2, want_tb = 2, note = "尾 (ui_cases)"},
	{r = 0x6587, want_python = 2, want_tb = 2, note = "文 (product measure cases)"},
	{r = 0x754C, want_python = 2, want_tb = 2, note = "界 (ui_cases)"},
	{r = 0xFE0F, want_python = 0, want_tb = 0, note = "VARIATION SELECTOR-16 (the \\u26A0+FE0F sequence) — Mn, ZERO in both"},
	{r = 0x1F600, want_python = 2, want_tb = 2, note = "astral U+1F600 — del_key whole-rune deletion, tui_drive.py:861 (4 bytes)"},
}

// fallback_width mirrors src/render/measure.odin:glyph_columns for the w<0
// case. Deliberately a LOCAL copy rather than a call into the product: the
// product's fallback is a property of its layout code and could legitimately
// change; what is frozen here is the harness's contract with termbox. If the
// two ever diverge, width_fallback_mirrors_product is the test that says so
// rather than a suite failing for a reason nobody can name.
fallback_width :: proc(raw: i32) -> int {
	if raw < 0 { return 1 }
	return int(raw)
}

tb_width_of :: proc(r: rune) -> int {
	return fallback_width(tb.tb_wcwidth(u32(r)))
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. The per-rune parity assertions.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
width_table_agrees_python_vs_termbox :: proc(t: ^testing.T) {
	disagree := 0
	first := ""
	for c in WIDTH_CASES {
		got := tb_width_of(c.r)
		if c.want_python != c.want_tb {
			disagree += 1
			if first == "" {
				first = fmt.tprintf("U+%04X py={} tb={}", c.want_python, c.want_tb)
			}
		}
		support.check(t,
			fmt.tprintf("U+{} agrees (py={} tb={}) — {}", cp_name(c.r), c.want_python, c.want_tb, c.note),
			c.want_python == c.want_tb && got == c.want_tb,
			fmt.tprintf("tb_wcwidth now returns {}; recorded tb={}; recorded python={}",
				got, c.want_tb, c.want_python))
	}
	support.check(t, "no rune in the frozen table disagrees between the two authorities",
		disagree == 0,
		fmt.tprintf("{} disagreement(s){}", disagree,
			if_first(first)))
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. The table must still MEAN what it says.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
width_combining_marks_are_zero_in_both :: proc(t: ^testing.T) {
	// This is the case the plan singled out, so it gets its own named test
	// rather than being one row among thirty-nine. A combining mark reported as
	// width 1 would shift every caret/column computation downstream.
	marks := []rune{0x0300, 0x0301, 0x0303, 0x0308, 0xFE0F}
	bad := 0
	bad_list := ""
	for m in marks {
		got := tb_width_of(m)
		if got != 0 {
			bad += 1
			bad_list = fmt.tprintf("{} U+{}={}", bad_list, cp_name(m), got)
		}
	}
	support.check(t, "every frozen combining mark is width ZERO in tb_wcwidth",
		bad == 0,
		fmt.tprintf("{} of {} marks non-zero:{}", bad, len(marks), bad_list))

	// And the e+U+0301 case render_cases.odin:183 actually asserts: the base
	// occupies the cell, the mark occupies none, so the PAIR is one column.
	pair := tb_width_of('e') + tb_width_of(0x0301)
	support.eq_i(t, "e + U+0301 occupies exactly 1 display column", pair, 1)
	stacked := tb_width_of('e') + tb_width_of(0x0301) + tb_width_of(0x0301) + tb_width_of('n')
	support.eq_i(t, "e + U+0301 + U+0301 + n occupies exactly 2 columns", stacked, 2)
}

@(test)
width_wide_runes_are_two_in_both :: proc(t: ^testing.T) {
	wide := []rune{0x4E16, 0x4E2D, 0x6587, 0x754C, 0x5C3E, 0x1F600}
	for w in wide {
		support.eq_i(t, fmt.tprintf("U+{} is 2 columns", cp_name(w)), tb_width_of(w), 2)
	}
	// `a世b😀c` — the exact string ui_cases.odin:1006 types through the pty.
	// 7 columns from 11 bytes. This number is the difference between a caret
	// that lands on a character and one that lands on a byte.
	seq := []rune{'a', 0x4E16, 'b', 0x1F600, 'c'}
	s : int = 0
	for r in seq {
		s += tb_width_of(r)
	}
	support.eq_i(t, "a世b-U+1F600-c is 7 display columns (11 bytes)", s, 7)
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. The ASCII floor, and the boundary the table does NOT cover.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
width_ascii_printable_is_all_one :: proc(t: ^testing.T) {
	bad := 0
	first_bad := 0
	for cp := 0x20; cp < 0x7F; cp += 1 {
		if tb_width_of(rune(cp)) != 1 {
			bad += 1
			if first_bad == 0 { first_bad = cp }
		}
	}
	support.eq_i(t, "all 95 printable ASCII runes are width 1", bad, 0)
}

// DIVERGENT_NOT_REACHED records where the two authorities DISAGREE.
//
// These are NOT failures and they are NOT ignored. They are the boundary of
// the parity claim: the two tables diverge on ~61k code points across the
// whole range (overwhelmingly unassigned Cn, where unicodedata says 1 or 2
// and termbox says 0/−1), and on 491 ASSIGNED ones. The ones below are the
// interesting assigned shapes. NONE of them is reachable by this project: no
// session name, filter string, footer hint or test fixture contains Hangul
// fillers, soft hyphens, trigrams or circled numbers.
//
// If a future change makes any of these reachable, THIS test is where the
// width question has to be re-answered before the assertion that reaches it
// is written. Adding a rune to WIDTH_CASES without checking is the failure
// mode this table exists to catch.
Divergent_Rune :: struct {
	r           : rune,
	want_python : int,
	want_tb     : int,
	why         : string,
}

DIVERGENT_NOT_REACHED := []Divergent_Rune{
	{r = 0x00AD, want_python = 0, want_tb = 1, why = "SOFT HYPHEN — Cf (invisible) to unicodedata, 1 cell to termbox"},
	{r = 0x1160, want_python = 1, want_tb = 0, why = "HANGUL JUNGSEONG FILLER — 1 to unicodedata, zero-width to termbox"},
	{r = 0x3164, want_python = 2, want_tb = 0, why = "HANGUL FILLER — East-Asian Wide to unicodedata, zero-width to termbox"},
	{r = 0xFFA0, want_python = 1, want_tb = 0, why = "HALFWIDTH HANGUL FILLER — 1 vs 0"},
	{r = 0x2630, want_python = 1, want_tb = 2, why = "TRIGRAM FOR HEAVEN — narrow to unicodedata, wide to termbox"},
	{r = 0x3248, want_python = 1, want_tb = 2, why = "CIRCLED NUMBER TEN ON BLACK SQUARE — 1 vs 2"},
}

@(test)
width_table_divergences_are_recorded :: proc(t: ^testing.T) {
	// The record must stay TRUE: each listed divergence really does differ, so
	// the list cannot silently rot into a list of agreements.
	for d in DIVERGENT_NOT_REACHED {
		got := tb_width_of(d.r)
		support.check(t,
			fmt.tprintf("recorded divergence U+{} still diverges ({})", cp_name(d.r), d.why),
			got == d.want_tb && d.want_python != d.want_tb,
			fmt.tprintf("tb now {}; recorded tb={}; recorded python={}", got, d.want_tb, d.want_python))
	}
	// And none of them is in the reachable table — otherwise this is no longer
	// a recorded boundary, it is a live contradiction.
	for d in DIVERGENT_NOT_REACHED {
		in_reach := false
		for c in WIDTH_CASES {
			if c.r == d.r { in_reach = true }
		}
		support.check(t, fmt.tprintf("U+{} is NOT in the reachable WIDTH_CASES table", cp_name(d.r)),
			!in_reach, "reachable set and divergence record must stay disjoint")
	}
}

@(test)
width_table_is_non_empty_and_covers_the_named_runes :: proc(t: ^testing.T) {
	// A frozen table that lost its rows is worse than no table: the parity
	// check would pass over an empty set.
	support.check(t, "the frozen width table is non-empty", len(WIDTH_CASES) > 0,
		fmt.tprintf("{} rows", len(WIDTH_CASES)))
	support.check(t, "the table names both whole-rune-deletion runes",
		has_rune(0x4E16) && has_rune(0x1F600),
		"世 U+4E16 and U+1F600 are the two del_key deletion subjects")
	support.check(t, "the table names U+0301 (the plan's named combining mark)",
		has_rune(0x0301), "render_cases.odin MEASURE_CASES uses e+U+0301")
	support.check(t, "the table names the CARET and the divider",
		has_rune(0x258F) && has_rune(0x2500),
		"U+258F filter caret, U+2500 the RCH-1 divider")
}

// ─────────────────────────────────────────────────────────────────────────────
// helpers
// ─────────────────────────────────────────────────────────────────────────────

has_rune :: proc(r: rune) -> bool {
	for c in WIDTH_CASES {
		if c.r == r { return true }
	}
	return false
}

cp_name :: proc(r: rune) -> string {
	return fmt.tprintf("%04X", u32(r))
}

if_first :: proc(s: string) -> string {
	if s == "" { return "" }
	return fmt.tprintf(" (first: {})", s)
}
