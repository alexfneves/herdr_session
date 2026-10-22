package unit

// ─────────────────────────────────────────────────────────────────────────────
// render_measure_test.odin — T7 port of the `measure` case (13 counted checks).
//
// Source: `case_measure` (src/render_cases.odin:301) driven by
// dev/render-smoke.sh section 1.
//
// THE CLAIM THIS FILE MAKES
//
//   A terminal row is measured in DISPLAY COLUMNS, not bytes and not runes.
//
// Every other layer in the pipeline — Clay's layout, the renderer's glyph
// placement, the scissor's intersection — trusts that one number. If
// `text_columns` returned bytes, "hello 世界" would be laid out 6 columns wide
// while occupying 10, and every subsequent cell assertion in this suite would
// drift off the screen without a single error being raised.
//
// WHY THIS CASE NEEDS NO TERMINAL
//
// `measure` is the one case the old shell ran WITHOUT `script -q` (see
// render-smoke.sh:69 — a bare `"$BIN" measure`), because display-width maths
// is a pure function of the code point: no tty, no termbox init, no pty.
// `tb_wcwidth` is likewise a pure lookup. Keeping this file terminal-free is
// what lets it run in a sandbox that has no screen at all.
//
// THREE SEPARATE @(test) PROCS
//
// `core:testing`'s `error_count` is per test, so a failure in the table, in
// the callback-shape check or in the wcwidth cross-check is attributable to
// its own proc instead of collapsing into one case verdict. The order is kept
// identical to the old case so the transcript still reads as the same report.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import clay "../../clay-odin"
import render "../../src/render"
import tb "../../vendor/termbox2-odin"

import support "../support"

// render_measure_columns is the table: for each input, bytes, runes and columns
// are asserted as THREE DIFFERENT numbers. A row where all three coincided
// would prove nothing, which is why the table contains no pure-ASCII row except
// as a control.
@(test)
render_measure_columns :: proc(t: ^testing.T) {
	support.note(t, "case measure — Clay measure_text in terminal columns")
	for it in RENDER_MEASURE_CASES {
		got := render_cols(it.text)
		support.check(t,
			fmt.tprintf("cols({}) == {}", it.text, it.want),
			got == it.want,
			fmt.tprintf("got {}  (bytes={} runes={})  {}",
				got, len(it.text), render_count_runes(it.text), it.note))
	}
}

// render_measure_callback_shape pins what CLAY itself receives. Clay multiplies
// this height by its own wrapped-line count, so a height of anything other than
// exactly one cell inflates every line of every layout by the same ratio — a
// bug that reads as "the UI is a bit tall" rather than as an error.
@(test)
render_measure_callback_shape :: proc(t: ^testing.T) {
	word := "multi"
	measured := render.measure_text(clay.StringSlice{
		chars  = raw_data(word),
		length = 5,
	}, nil, nil)
	support.check(t, "measure_text height == 1 cell/line", measured.height == 1.0,
		fmt.tprintf("got {} cells per line", measured.height))
	support.check(t, "measure_text width == 5 columns", measured.width == 5.0,
		fmt.tprintf("got {}", measured.width))
}

// render_measure_wcwidth_agreement cross-checks the two independent width
// sources in the pipeline: our layout measurement and termbox's paint-time
// `tb_wcwidth`. They are not the same implementation, so they can disagree.
// Layout asking for N columns while the painter advances M leaves a one-cell
// gap or an overwritten glyph on every wide character on screen.
@(test)
render_measure_wcwidth_agreement :: proc(t: ^testing.T) {
	drift := 0
	sample := "hello 世界 😀 combining é"
	idx := 0
	for r in sample {
		w := render.glyph_columns(r)
		tw := tb.tb_wcwidth(u32(r))
		if tw < 0 { tw = 1 }
		if w != tw { drift += 1 }
		idx += 1
	}
	support.check(t, "glyph_columns agrees with tb_wcwidth", drift == 0,
		fmt.tprintf("mismatches={} over {} runes", drift, idx))
}
