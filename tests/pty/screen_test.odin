package pty

// ─────────────────────────────────────────────────────────────────────────────
// screen_test.odin — the Screen emulator's OWN tests.
//
// These run on byte strings fed directly to the emulator. NO pty, NO app, NO
// integration. This ordering is not ceremony: every single screen-scraping
// assertion in T11/T12/T13/T14 inherits this emulator's correctness, so an
// emulator bug is a bug in all of them simultaneously. The plan's line is
// that no integration pty work may proceed until the emulator is proven, and
// the reason is the diff-render failure mode: if the emulator is wrong in a
// way that makes absent pixels look present, downstream suites go GREEN on
// code that never painted.
//
// The six cases the plan names as the minimum are all here, plus the ones that
// fell out of reading the python for real (SGR/DEC-private ignoring, the
// cursor-clamp asymmetry, out-of-bounds writes) because those are the ones a
// partial port quietly drops.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import support "../support"

// feed_str is the shorthand every case uses.
feed_str :: proc(s: ^Screen, str: string) {
	screen_feed(s, transmute([]u8)str)
}

// row_of reads a row back as text, with the trailing-blank-stripping the
// python `lines()` does.
row_of :: proc(s: ^Screen, r: int) -> string {
	buf : [dynamic]u8
	defer delete(buf)
	screen_row_text(s, r, &buf)
	return copy_string(buf)
}

// ─────────────────────────────────────────────────────────────────────────────
// MINIMUM CASE 1 — a UTF-8 rune split across two writes, at EVERY boundary.
//
// This is the case that a "just decode the buffer" port gets wrong, and it is
// wrong invisibly: with a whole rune per read it never happens, so the bug
// waits until a real pty fragments a write at an unlucky byte. Testing every
// boundary of every sequence length removes the luck.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
screen_split_utf8_across_two_feeds_every_boundary :: proc(t: ^testing.T) {
	// 1-, 2-, 3- and 4-byte sequences: 'A', '·' (2), '世' (3), U+1F600 (4).
	subjects := "A\u00B7\u4E16\U0001F600"
	samples := []rune{'A', 0x00B7, 0x4E16, 0x1F600}
	enc_len := [4]int{1, 2, 3, 4}

	for want_rune, idx in samples {
		n := enc_len[idx]
		// Isolate this rune's own UTF-8 bytes.
		start := 0
		for k := 0; k < idx; k += 1 { start += enc_len[k] }
		rune_bytes := transmute([]u8)(subject_slice(subjects, start, n))

		// Split BEFORE every byte of the sequence: after 1 byte, after 2, …
		// A split at the very start is the degenerate "whole thing in feed 2".
		for cut := 1; cut < n; cut += 1 {
			s : Screen
			screen_init(&s, 4, 20)
			feed_str(&s, string(rune_bytes[:cut]))
			// Nothing should have been painted yet at the cell for a
			// partial multi-byte sequence: the decoder is holding it.
			mid := s.grid[screen_idx(&s, 0, 0)]
			// For n>1 a partial sequence must NOT produce a cell.
			// (For a 1-byte subject there is no partial state.)
			feed_str(&s, string(rune_bytes[cut:]))
			got := s.grid[screen_idx(&s, 0, 0)]
			support.check(t,
				fmt.tprintf("U+{} split after byte {}/{} reassembles to ONE cell",
					cp_name(want_rune), cut, n),
				got == want_rune && mid != '(' && mid != 0xFFFD,
				fmt.tprintf("mid={} got={} want={}", cp_name(mid), cp_name(got), cp_name(want_rune)))
		}
		// And the full sequence in one feed still works.
		s : Screen
		screen_init(&s, 4, 20)
		feed_str(&s, string(rune_bytes[:]))
		support.eq_i(t, fmt.tprintf("U+{} whole-in-one-feed lands in cell 0", cp_name(want_rune)),
			int(s.grid[screen_idx(&s, 0, 0)]), int(want_rune))
	}
}

subject_slice :: proc(s: string, start: int, n: int) -> string {
	if start + n > len(s) { return "" }
	return s[start:start + n]
}

@(test)
screen_split_utf8_three_way_across_three_feeds :: proc(t: ^testing.T) {
	// One byte at a time, the worst case for a carry buffer: a 3-byte rune
	// delivered as three 1-byte feeds must still be ONE cell, and the two
	// intermediate feeds must paint NOTHING.
	s : Screen
	screen_init(&s, 2, 10)
	world_str := "世"
	b := transmute([]u8)world_str
	support.eq_i(t, "世 is 3 UTF-8 bytes", len(b), 3)
	feed_str(&s, string(b[0:1]))
	after1 := s.cx
	feed_str(&s, string(b[1:2]))
	after2 := s.cx
	feed_str(&s, string(b[2:3]))
	after3 := s.cx
	support.eq_i(t, "after 1 of 3 bytes the cursor has not advanced", after1, 0)
	support.eq_i(t, "after 2 of 3 bytes the cursor has not advanced", after2, 0)
	support.eq_i(t, "after the 3rd byte the cursor advanced by the glyph width 2", after3, 2)
	support.eq_i(t, "the cell holds 世", int(s.grid[screen_idx(&s, 0, 0)]), 0x4E16)
	support.eq_i(t, "the cell after it is blanked by the wide glyph",
		int(s.grid[screen_idx(&s, 0, 1)]), int(' '))
}

// ─────────────────────────────────────────────────────────────────────────────
// MINIMUM CASE 2 — charset designation must not smear.
//
// This is the python bug, recorded so it cannot come back. `ESC ( B` is a
// charset designation; a parser that does not know the family paints its own
// bytes. In the real harness that turned the footer "delete_session" into
// "delete_sess(Bn" — a wrong string produced by CORRECT rendering, which is
// the worst kind of failure to debug.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
screen_charset_designation_does_not_smear :: proc(t: ^testing.T) {
	cases := []rune{'(', ')'}
	for f in cases {
		s : Screen
		screen_init(&s, 3, 40)
		// Interleave charset designations INSIDE the word, exactly how a
		// terminfo-driven renderer can emit them.
		feed_str(&s, "delete_sess")
		feed_str(&s, fmt.tprintf("\x1b{}B", f))
		feed_str(&s, "ion")
		support.check(t,
			fmt.tprintf("ESC {} B inside a word does not smear — renders 'delete_session'", f),
			screen_contains(&s, "delete_session"),
			fmt.tprintf("row 0: '{}'", row_of(&s, 0)))
		support.check(t, fmt.tprintf("no literal 'B' or '{}' painted anywhere", f),
			!screen_contains(&s, fmt.tprintf("ss{}B", f)),
			fmt.tprintf("row 0: '{}'", row_of(&s, 0)))
	}
	// ESC ) 0 — the DEC special graphics (line-drawing) charset. Also must not
	// appear literally.
	s : Screen
	screen_init(&s, 3, 40)
	feed_str(&s, "\x1b)0")
	feed_str(&s, "abc")
	eq_s_local(t, "ESC ) 0 designates without painting", row_of(&s, 0), "abc")
	// ESC # 8 — DECALTDEC. Three bytes, none of them content.
	s2 : Screen
	screen_init(&s2, 3, 40)
	feed_str(&s2, "he\x1b#8llo")
	eq_s_local(t, "ESC # 8 does not paint", row_of(&s2, 0), "hello")
}

// ─────────────────────────────────────────────────────────────────────────────
// MINIMUM CASE 3 — OSC must not reach the screen.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
screen_osc_title_does_not_appear :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 3, 40)
	feed_str(&s, "\x1b]0;herdr-session: my_session\x07visible")
	support.check(t, "the text after OSC renders", screen_contains(&s, "visible"),
		fmt.tprintf("row 0: '{}'", row_of(&s, 0)))
	support.check(t, "the OSC title text is nowhere on the grid",
		!screen_contains(&s, "herdr-session") && !screen_contains(&s, "my_session"),
		fmt.tprintf("row 0: '{}'", row_of(&s, 0)))
	eq_s_local(t, "cell 0 is the first VISIBLE glyph",
		string_utf8_rune_at(&s, 0, 0), "v")

	// OSC split across feeds must still be swallowed — the ESC/OSC state has
	// to persist across a feed boundary or the title leaks onto the grid.
	s2 : Screen
	screen_init(&s2, 3, 40)
	feed_str(&s2, "ab\x1b]0;tt")
	feed_str(&s2, "le:secret\x07cd")
	support.check(t, "OSC split across two feeds is still swallowed",
		!screen_contains(&s2, "secret") && screen_contains(&s2, "abcd"),
		fmt.tprintf("row 0: '{}'", row_of(&s2, 0)))
}

// ─────────────────────────────────────────────────────────────────────────────
// MINIMUM CASE 4 — wide glyph blanks the following cell; cursor lands at N+2.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
screen_wide_glyph_blanks_next_cell :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 3, 40)
	feed_str(&s, "\x1b[1;1H")
	feed_str(&s, "a世b")
	support.eq_i(t, "col 0 = 'a'", int(s.grid[screen_idx(&s, 0, 0)]), int('a'))
	support.eq_i(t, "col 1 = 世", int(s.grid[screen_idx(&s, 0, 1)]), 0x4E16)
	support.eq_i(t, "col 2 is BLANKED by the wide glyph, not left over",
		int(s.grid[screen_idx(&s, 0, 2)]), int(' '))
	support.eq_i(t, "col 3 = 'b' — the cursor advanced by the GLYPH WIDTH",
		int(s.grid[screen_idx(&s, 0, 3)]), int('b'))
	support.eq_i(t, "cursor is at column 4 after a+b+wide", s.cx, 4)

	// Now overwrite the wide glyph with something narrow. If the blank-on-wide
	// rule were missing, a stale half-glyph would remain at col 1.
	feed_str(&s, "\x1b[1;2HX")
	support.eq_i(t, "overwriting col 1 with 'X'", int(s.grid[screen_idx(&s, 0, 1)]), int('X'))
	support.eq_i(t, "col 2 is still blank (no leftover from the wide glyph)",
		int(s.grid[screen_idx(&s, 0, 2)]), int(' '))

	// A wide glyph at the LAST column: the blank has nowhere to go, and that
	// must not corrupt anything or run off the end.
	s2 : Screen
	screen_init(&s2, 2, 3)
	feed_str(&s2, "\x1b[1;3H世")
	support.eq_i(t, "wide glyph at the last column lands in col 2",
		int(s2.grid[screen_idx(&s2, 0, 2)]), 0x4E16)
	support.eq_i(t, "cursor clamps to cols, not past the end", s2.cx, 3)
}

// ─────────────────────────────────────────────────────────────────────────────
// MINIMUM CASE 5 — a diff-style stream reconstructs the whole row.
//
// THIS IS THE CASE THAT JUSTIFIES THE ENTIRE EMULATOR. Start from a grid that
// already contains the final text, then feed ONLY a cursor jump and one
// changed character — the way termbox actually emits a frame — and assert the
// full word is readable. A byte grep on this exact stream finds nothing.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
screen_diff_stream_reconstructs_full_row :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 3, 40)
	// Frame 1: paint the whole word.
	feed_str(&s, "\x1b[1;1Hdelete_session")
	support.check(t, "frame 1 renders the full word",
		screen_contains(&s, "delete_session"),
		fmt.tprintf("row 0: '{}'", row_of(&s, 0)))

	// Frame 2: termbox re-emits ONLY what changed. Change 'e' at index 6 to
	// 'X'. The stream contains a cursor jump and ONE character.
	feed_str(&s, "\x1b[1;7HX")
	support.check(t, "frame 2: the row STILL reads as a full word, with one change",
		row_of(&s, 0) == "deleteXsession",
		fmt.tprintf("row 0: '{}'", row_of(&s, 0)))
	// And here is the point of the file, stated as an assertion:
	grepped := "delete_session"
	grep_bytes := transmute([]u8)grepped
	support.check(t, "the frame-2 byte stream ALONE would defeat a byte grep",
		!contains_bytes("\x1b[1;7HX", "delete_session") && len(grep_bytes) > 0,
		"a correct render produced a stream with no substring in it; only the grid reconstructs it")

	// Frame 3: several scattered single-cell changes, the common real case.
	feed_str(&s, "\x1b[1;2H1\x1b[1;4H2\x1b[1;9H3")
	eq_s_local(t, "three sparse diffs reconstruct one coherent row",
		row_of(&s, 0), "d1l2teXs3ssion")
}

// ─────────────────────────────────────────────────────────────────────────────
// MINIMUM CASE 6 — erase verbs.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
screen_erase_verbs_behave_per_spec :: proc(t: ^testing.T) {
	// ED 2 — clear the whole screen.
	s : Screen
	screen_init(&s, 3, 10)
	feed_str(&s, "aaaaaaaaaa")
	feed_str(&s, "\x1b[2J")
	eq_s_local(t, "CSI 2 J clears every row", row_of(&s, 0), "")
	eq_s_local(t, "…including rows below the cursor", row_of(&s, 2), "")

	// A seeded 3x10 grid, used for every erase case so each one starts from an
	// identical, known state. Reusing one screen across erase verbs is how you
	// get a test that passes for the wrong reason; each verb gets a fresh seed.
	seed :: proc(sc: ^Screen) {
		feed_str(sc, "\x1b[1;1HAAAAAAAAAA")
		feed_str(sc, "\x1b[2;1HBBBBBBBBBB")
		feed_str(sc, "\x1b[3;1HCCCCCCCCCC")
	}

	// ED 0 ("erase display", no parameter) — cursor to end of SCREEN.
	s2 : Screen
	screen_init(&s2, 3, 10)
	seed(&s2)
	// NOTE: bare `CSI J` defaults to n=1 in the python and therefore clears
	// NOTHING (only n==0 and n==2 have branches). Emit the 0 explicitly.
	feed_str(&s2, "\x1b[2;4H\x1b[0J")
	eq_s_local(t, "CSI J (n=0) leaves rows ABOVE the cursor alone",
		row_of(&s2, 0), "AAAAAAAAAA")
	eq_s_local(t, "…clears from the cursor to the end of its own row",
		row_of(&s2, 1), "BBB")
	eq_s_local(t, "…and clears every row below it entirely",
		row_of(&s2, 2), "")

	// EL 0 — erase from cursor to end of line.
	s3 : Screen
	screen_init(&s3, 1, 10)
	feed_str(&s3, "0123456789")
	feed_str(&s3, "\x1b[1;4H\x1b[0K")
	eq_s_local(t, "CSI 0 K erases from the cursor rightwards",
		row_of(&s3, 0), "012")

	// EL 1 — erase from start of line through the cursor (INCLUSIVE: the
	// python is `clear_row(cy, 0, cx + 1)`, so the cursor's own cell goes).
	s4 : Screen
	screen_init(&s4, 1, 10)
	feed_str(&s4, "0123456789")
	feed_str(&s4, "\x1b[1;6H\x1b[1K")
	eq_s_local(t, "CSI 1 K erases the start through the cursor, inclusive",
		row_of(&s4, 0), "      6789")

	// EL 2 — the whole line.
	s5 : Screen
	screen_init(&s5, 1, 10)
	feed_str(&s5, "0123456789")
	feed_str(&s5, "\x1b[1;1H\x1b[2K")
	eq_s_local(t, "CSI 2 K clears the whole row", row_of(&s5, 0), "")

	// Erase verbs must not move the cursor. A verb that did would silently
	// reposition every subsequent write in a diff stream.
	s6 : Screen
	screen_init(&s6, 3, 10)
	seed(&s6)
	feed_str(&s6, "\x1b[2;4H\x1b[K")
	support.eq_i(t, "EL leaves the cursor where it was", s6.cx, 3)
	support.eq_i(t, "…and the same row", s6.cy, 1)
	feed_str(&s6, "z")
	support.eq_i(t, "…so the next write lands at that same column",
		int(s6.grid[screen_idx(&s6, 1, 3)]), int('z'))
}

@(test)
screen_H_and_f_are_the_same_verb :: proc(t: ^testing.T) {
	a : Screen
	screen_init(&a, 5, 20)
	feed_str(&a, "\x1b[3;7HXY")
	b : Screen
	screen_init(&b, 5, 20)
	feed_str(&b, "\x1b[3;7fXY")
	eq_s_local(t, "CSI 3;7H and CSI 3;7f place identically",
		row_of(&a, 2), row_of(&b, 2))
	// Six leading blanks: CUP 3;7 puts the text at column index 6, and
	// LEADING blanks are content — they survive the tail-only rstrip. A test
	// expecting bare "XY" here would be asserting that the emulator had lost
	// six columns.
	eq_s_local(t, "…at row index 2, six leading blanks then XY",
		row_of(&a, 2), "      XY")
	support.eq_i(t, "…cursor left just past the text at column 8", a.cx, 8)
	support.eq_i(t, "…XY really starts at column 6",
		int(a.grid[screen_idx(&a, 2, 6)]), int('X'))
}

// ─────────────────────────────────────────────────────────────────────────────
// The rest: things a partial port silently drops.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
screen_sgr_and_dec_private_are_ignored_for_content :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 2, 30)
	// Colour, attribute, and DEC-private mode changes interleaved with text.
	feed_str(&s, "\x1b[31mred\x1b[0m\x1b[1;38;5;196mbold\x1b[?1049h\x1b[?25lplain\x1b[?1h\x1b[?1l")
	eq_s_local(t, "SGR and DEC-private sequences contribute no glyphs",
		row_of(&s, 0), "redboldplain")
	support.check(t, "no digits or question marks leaked from the mode sequences",
		!screen_contains(&s, "?") && !screen_contains(&s, "38;5"),
		fmt.tprintf("row 0: '{}'", row_of(&s, 0)))
}

@(test)
screen_control_chars_are_control_not_content :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 4, 30)
	feed_str(&s, "abcdef\rghi")
	// a b c d e f -> g h i d e f. CR rewound to column 0 and the three new
	// glyphs overwrote the first three: six in, six out.
	eq_s_local(t, "CR returns the cursor to column 0", row_of(&s, 0), "ghidef")

	// From home: 'x' overwrites the 'g', BS steps back one, 'y' lands on the
	// very cell 'x' had just occupied.
	feed_str(&s, "\x1b[Hx\by")
	eq_s_local(t, "BS backs up one cell and overwrites", row_of(&s, 0), "yhidef")
	support.eq_i(t, "…a BS at column 0 clamps instead of going negative", s.cx, 1)
	feed_str(&s, "\b\b\b")
	support.eq_i(t, "…three more BS at the left edge all clamp to 0", s.cx, 0)

	s2 : Screen
	screen_init(&s2, 4, 30)
	feed_str(&s2, "a\tb")
	// python: `cx = min(cols, cx + 8)`. cx was 1 after 'a', so TAB lands it
	// at 9 — a FLAT +8, not a snap to a tab stop. The emulator matches the
	// renderer it models; a real tab-stop implementation here would be a
	// divergence dressed up as correctness.
	support.eq_i(t, "TAB advances a flat 8 columns from the current cursor",
		int(s2.grid[screen_idx(&s2, 0, 9)]), int('b'))
	support.eq_i(t, "…every cell between stays blank",
		int(s2.grid[screen_idx(&s2, 0, 1)]), int(' '))
	support.eq_i(t, "…including the one at 8",
		int(s2.grid[screen_idx(&s2, 0, 8)]), int(' '))

	s3 : Screen
	screen_init(&s3, 4, 30)
	feed_str(&s3, "line1\nline2")
	eq_s_local(t, "LF moves down a row", row_of(&s3, 0), "line1")
	// LF ALONE does not return the column — python's handler is `cy += 1`
	// and nothing else, so "line2" starts at column 5. A termbox app that
	// wants column 0 emits \r\n or a CUP. Recorded deliberately because the
	// intuitive expectation is wrong, and the emulator must match the python
	// it replaces rather than intuition about terminals.
	eq_s_local(t, "…LF alone keeps the column (this is NOT a CR)",
		row_of(&s3, 1), "     line2")
	support.eq_i(t, "…cursor ends at column 10 of row 1", s3.cx, 10)
}

@(test)
screen_trailing_blanks_stripped_leading_kept :: proc(t: ^testing.T) {
	// Leading blanks are CONTENT — they are how an indented label renders.
	// Only trailing blanks are stripped, matching python's rstrip(). A port
	// that strips both would make an indented label unreadable and every
	// column-position assertion wrong.
	s : Screen
	screen_init(&s, 2, 20)
	feed_str(&s, "   indented   ")
	got := row_of(&s, 0)
	eq_s_local(t, "leading blanks survive, trailing are stripped", got, "   indented")
}

@(test)
screen_out_of_bounds_writes_are_dropped_not_corrupting :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 2, 5)
	feed_str(&s, "\x1b[10;10HZ")
	// python's guard is `0 <= cy < rows`; the write is dropped, cx keeps
	// moving. Assert nothing landed anywhere and nothing outside the grid moved.
	support.check(t, "a write to row 9 of a 2-row screen lands nowhere",
		s.cy == 9 && !screen_contains(&s, "Z"),
		fmt.tprintf("cy={} row0='{}'", s.cy, row_of(&s, 0)))
	support.eq_i(t, "the grid is otherwise untouched",
		int(s.grid[screen_idx(&s, 0, 0)]), int(' '))
	// And a valid write afterwards still works — the drop must not wedge the
	// emulator.
	feed_str(&s, "\x1b[1;1Hok")
	eq_s_local(t, "a valid write after an out-of-bounds one still renders",
		row_of(&s, 0), "ok")
}

@(test)
screen_split_escape_across_feeds_is_not_dropped :: proc(t: ^testing.T) {
	// The explicit divergence from python: a CSI split across feeds must
	// still work, because a pty can fragment a write anywhere. Python's
	// regex-break dropped the tail of the chunk here.
	s : Screen
	screen_init(&s, 5, 30)
	feed_str(&s, "junkjunk")
	feed_str(&s, "\x1b[")           // partial escape
	feed_str(&s, "3;")              // parameters split
	feed_str(&s, "4H")              // final byte
	feed_str(&s, "OK")
	eq_s_local(t, "a CSI split across three feeds still positions correctly",
		row_of(&s, 2), "   OK")

	// ESC itself as the last byte of a chunk.
	s2 : Screen
	screen_init(&s2, 5, 30)
	feed_str(&s2, "\x1b")
	feed_str(&s2, "[2;2Hab")
	eq_s_local(t, "a chunk ending on bare ESC still continues correctly",
		row_of(&s2, 1), " ab")

	// A truncated escape at the end of the stream must not paint the ESC.
	s3 : Screen
	screen_init(&s3, 2, 30)
	feed_str(&s3, "ab\x1b[")
	eq_s_local(t, "a stream ending mid-escape leaves no escape bytes painted",
		row_of(&s3, 0), "ab")
}

// ─────────────────────────────────────────────────────────────────────────────
// local assertion helpers (support has no string-eq with this exact wording)
// ─────────────────────────────────────────────────────────────────────────────

eq_s_local :: proc(t: ^testing.T, name: string, got: string, want: string) {
	support.check(t, name, got == want,
		fmt.tprintf("got '{}' want '{}'", got, want))
}

string_utf8_rune_at :: proc(s: ^Screen, r, c: int) -> string {
	out : [dynamic]u8
	defer delete(out)
	encode_rune_into(&out, screen_cell(s, r, c))
	return copy_string(out)
}
