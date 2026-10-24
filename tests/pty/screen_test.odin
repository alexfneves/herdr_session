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
import "core:unicode/utf8"

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
// MINIMUM CASE 1b — THE CARRY BUFFER MUST SURVIVE A screen_resize.
//
// THE DEFECT THESE TESTS WERE WRITTEN AGAINST (harness, not product).
// `screen_resize` was a bare call to `screen_init`, and `screen_init` zeroes
// `carry_len`. A resize landing between the LEAD BYTE of a UTF-8 sequence and
// its continuation bytes therefore THREW THE PARTIAL SEQUENCE AWAY. When the
// tail arrived it had no lead byte to decode against and landed in the grid as
// U+FFFD.
//
// That is the real shape of the resize_flood failure this lane was sent to
// chase: `the surviving frame is the FINAL size, not a stale one — spine
// widths lo=118 hi=118 want 118 (rules=1)`. The width was CORRECT. The row
// held 115 good `─` glyphs plus 3 U+FFFD, so `rh_is_rule` rejected it and
// `rh_rule_count` read 1 where the app had drawn 2. The check said "stale
// frame" about a frame that was fine, because the EMULATOR had eaten bytes the
// app really wrote.
//
// THE RULE THIS ESTABLISHES
//   A partial UTF-8 sequence belongs to the BYTE STREAM, not to the screen
//   geometry. Resizing the grid must not consume it, must not reset it, and
//   must not reorder it. Grid CONTENT legitimately blanks on resize (that
//   is python's behaviour and it stays — the harness invents no reflow rule);
//   pending BYTES are not grid content and do not blank with it.
//
// Every boundary of every sequence length is covered, because the boundary the
// flood hits is chosen by frame size and read fragmentation, not by us.
// ─────────────────────────────────────────────────────────────────────────────

Carry_Glyph :: struct {
	label : string,
	want  : rune,
	bytes : [4]u8,
	n     : int,
}

// The bytes are spelled out rather than derived: this is a byte-stream test and
// the wire form IS the thing under test. 2-, 3- and 4-byte sequences plus the
// specific 3-byte glyph the flood draws its spine with (U+2500), and an
// astral-plane 4-byte case, whose boundary can fall at any of THREE positions.
CARRY_GLYPHS :: []Carry_Glyph{
	Carry_Glyph{"·  U+00B7  2-byte Latin-1 accent", 0x00B7, [4]u8{0xC2, 0xB7, 0x00, 0x00}, 2},
	Carry_Glyph{"世  U+4E16  3-byte CJK", 0x4E16, [4]u8{0xE4, 0xB8, 0x96, 0x00}, 3},
	Carry_Glyph{"─  U+2500  3-byte box drawing (THE FLOOD'S SPINE GLYPH)", 0x2500, [4]u8{0xE2, 0x94, 0x80, 0x00}, 3},
	Carry_Glyph{"U+1F600  4-byte ASTRAL PLANE (emoji)", 0x1F600, [4]u8{0xF0, 0x9F, 0x98, 0x80}, 4},
}

feed_bytes :: proc(s: ^Screen, b: []u8) {
	screen_feed(s, b)
}

// grid_count_rune scans the LIVE grid (rows x cols), not a rstripped row
// string, so a U+FFFD cannot hide past the end of what a row accessor shows.
grid_count_rune :: proc(s: ^Screen, r: rune) -> int {
	n := 0
	for row := 0; row < s.rows; row += 1 {
		for col := 0; col < s.cols; col += 1 {
			if s.grid[screen_idx(s, row, col)] == r { n += 1 }
		}
	}
	return n
}

// grid_first_rune locates the first live cell holding `r` so a failure detail
// says WHERE the corruption is, not merely that there is some.
grid_first_rune :: proc(s: ^Screen, r: rune) -> (row, col: int) {
	for row := 0; row < s.rows; row += 1 {
		for col := 0; col < s.cols; col += 1 {
			if s.grid[screen_idx(s, row, col)] == r { return row, col }
		}
	}
	return -1, -1
}

hex_bytes :: proc(b: []u8) -> string {
	digits := "0123456789ABCDEF"
	parts : [dynamic]u8
	defer delete(parts)
	for i := 0; i < len(b); i += 1 {
		if i > 0 { append(&parts, ' ') }
		append(&parts, digits[b[i] >> 4])
		append(&parts, digits[b[i] & 0x0F])
	}
	return copy_string(parts)
}

// carry_detail puts the whole state on one line: a `rules=1`-style mystery is
// only debuggable if the counter, the cell and the corruption position are
// all printed together.
carry_detail :: proc(tag: string, s: ^Screen, want: rune, cut: int, n: int) -> string {
	fr, fc := grid_first_rune(s, 0xFFFD)
	return fmt.tprintf("{} cell(0,0)=U+{} want=U+{} carry_len={} (split at {}/{}) U+FFFD on grid={} first-at=({},{}) rows={} cols={}",
		tag, cp_name(s.grid[screen_idx(s, 0, 0)]), cp_name(want), s.carry_len, cut, n,
		grid_count_rune(s, 0xFFFD), fr, fc, s.rows, s.cols)
}

@(test)
screen_resize_preserves_utf8_carry_at_every_boundary :: proc(t: ^testing.T) {
	x_seed := "x"
	for g in CARRY_GLYPHS {
		glyph_arr := g.bytes
		glyph := glyph_arr[0:g.n]

		// ── CONTROL 1 — whole glyph, NO resize. Must be intact. ──────────────
		c1 : Screen
		screen_init(&c1, 4, 20)
		feed_bytes(&c1, glyph)
		support.check(t, fmt.tprintf("CONTROL 1 {} whole glyph, no resize -> one intact cell", g.label),
			c1.grid[screen_idx(&c1, 0, 0)] == g.want &&
				grid_count_rune(&c1, 0xFFFD) == 0 &&
				c1.carry_len == 0,
			fmt.tprintf("cell(0,0)=U+{} want=U+{} carry_len={} FFFD={}",
				cp_name(c1.grid[screen_idx(&c1, 0, 0)]), cp_name(g.want),
				c1.carry_len, grid_count_rune(&c1, 0xFFFD)))

		for cut := 1; cut < g.n; cut += 1 {
			head := glyph[0:cut]
			tail := glyph[cut:g.n]

			// ── CONTROL 2 — split glyph, NO resize. Works today; prove it keeps
			// working so nobody "fixes" the resize by breaking the feed. ────────
			c2 : Screen
			screen_init(&c2, 4, 20)
			feed_bytes(&c2, head)
			mid2 := grid_count_rune(&c2, 0xFFFD)
			pending2 := c2.carry_len
			feed_bytes(&c2, tail)
			support.check(t, fmt.tprintf("CONTROL 2 {} split after byte {}/{} with NO resize -> one intact cell", g.label, cut, g.n),
				c2.grid[screen_idx(&c2, 0, 0)] == g.want &&
					mid2 == 0 && pending2 == cut &&
					grid_count_rune(&c2, 0xFFFD) == 0 && c2.carry_len == 0,
				fmt.tprintf("cell(0,0)=U+{} want=U+{} carry_after_head={} (want {}) FFFD={} carry_len={} head=[{}] tail=[{}]",
					cp_name(c2.grid[screen_idx(&c2, 0, 0)]), cp_name(g.want), pending2, cut,
					grid_count_rune(&c2, 0xFFFD), c2.carry_len, hex_bytes(head), hex_bytes(tail)))

			// ── CASE 3 — split glyph WITH a resize across the split. THIS IS THE
			// DEFECT: pre-fix, the resize drops the held lead byte(s) and the tail
			// decodes as orphans into U+FFFD. ─────────────────────────────────
			s : Screen
			screen_init(&s, 4, 20)
			// Seed one painted cell first so "the grid blanked" is a measurable
			// statement rather than an unset-memory coincidence.
			feed_bytes(&s, transmute([]u8)x_seed)
			feed_bytes(&s, head)
			support.check(t, fmt.tprintf("pre-resize {} the held partial paints nothing and FFFDs nothing (split {}/{})", g.label, cut, g.n),
				grid_count_rune(&s, 0xFFFD) == 0 && s.carry_len == cut && s.grid[screen_idx(&s, 0, 0)] == 'x',
				carry_detail("pre-resize", &s, g.want, cut, g.n))

			screen_resize(&s, 3, 30)
			support.check(t, fmt.tprintf("resize blanks GRID CONTENT but not the pending BYTES: {} still holds {} byte(s) of U+{} (split {}/{})", g.label, cut, cp_name(g.want), cut, g.n),
				s.rows == 3 && s.cols == 30 &&
					s.grid[screen_idx(&s, 0, 0)] == ' ' &&
					s.carry_len == cut,
				carry_detail("post-resize", &s, g.want, cut, g.n))

			feed_bytes(&s, tail)
			support.check(t, fmt.tprintf("CASE 3 {} split across screen_resize reassembles into ONE cell (split after byte {}/{})", g.label, cut, g.n),
				s.grid[screen_idx(&s, 0, 0)] == g.want &&
					grid_count_rune(&s, 0xFFFD) == 0 &&
					s.carry_len == 0,
				carry_detail("post-tail", &s, g.want, cut, g.n))
		}
	}
}

// is_spine_row mirrors resize_harness.rh_is_rule EXACTLY (non-blank, and
// nothing but the 3-byte `─` sequence, byte for byte). It lives here rather
// than being imported because resize_harness is in another package and its
// matcher is deliberately NOT loosened: the point of this test is that the
// emulator produces a row the UNCHANGED matcher accepts.
is_spine_row :: proc(s: string) -> bool {
	t := s
	for len(t) > 0 && t[0] == ' ' { t = t[1:] }
	for len(t) > 0 && t[len(t) - 1] == ' ' { t = t[:len(t) - 1] }
	if len(t) == 0 { return false }
	spine := "\u2500"
	k := 0
	for k < len(t) {
		if k + len(spine) > len(t) { return false }
		for m := 0; m < len(spine); m += 1 {
			if t[k + m] != spine[m] { return false }
		}
		k += len(spine)
	}
	return true
}

// The same defect seen the way the flood sees it. rh_is_rule accepts a row
// only if EVERY non-blank cell is the 3-byte `─` sequence, so a single
// U+FFFD anywhere in the row makes rh_rule_count read one short of what the
// app painted — which is the flood's "rules=1, width correct, stale frame?"
// message with nothing stale about it.
//
// The grid legitimately BLANKS on resize (that is python's behaviour and it
// is not changed), so the assertion is stated in the two phases the flood
// actually produces:
//
//   phase A  the glyph that straddled the boundary reassembles into ONE
//            spine cell, and NOTHING on the grid is U+FFFD;
//   phase B  the app then repaints the rest of the row, and the finished row
//            is a PURE rule row of `total` glyphs that rh_is_rule accepts.
@(test)
screen_resize_mid_glyph_leaves_a_pure_spine_row :: proc(t: ^testing.T) {
	spine_wire := "\u2500"
	spine_bytes := transmute([]u8)spine_wire
	support.eq_i(t, "the spine glyph is 3 UTF-8 bytes", len(spine_bytes), 3)
	totals := [3]int{1, 7, 20}

	for cut := 1; cut <= 2; cut += 1 {
		for total in totals {
			s : Screen
			screen_init(&s, 4, 60)
			// Draw the row, splitting the LAST glyph across the resize boundary —
			// the ordering a TIOCSWINSZ landing mid-frame produces.
			for i := 0; i < total - 1; i += 1 { feed_bytes(&s, spine_bytes) }
			feed_bytes(&s, spine_bytes[0:cut])
			screen_resize(&s, 5, 60)
			feed_bytes(&s, spine_bytes[cut:])
			row := row_of(&s, 0)

			support.check(t, fmt.tprintf("phase A: the spine glyph split after byte {} across a resize reassembles as ONE cell, zero U+FFFD", cut),
				grid_count_rune(&s, 0xFFFD) == 0 && utf8_rune_count(row) == 1 && is_spine_row(row),
				fmt.tprintf("row='{}' rune_len={} FFFD={} carry_len={} first-FFFD-at=({},{})",
					row, utf8_rune_count(row), grid_count_rune(&s, 0xFFFD), s.carry_len,
					grid_first_rune(&s, 0xFFFD)))

			// Phase B: the app repaints the remainder of the row after the resize.
			for i := 0; i < total - 1; i += 1 { feed_bytes(&s, spine_bytes) }
			row = row_of(&s, 0)
			support.check(t, fmt.tprintf("phase B: the repainted spine of {} is a PURE rule row, zero U+FFFD", total),
				is_spine_row(row) && grid_count_rune(&s, 0xFFFD) == 0,
				fmt.tprintf("row='{}' rune_len={} FFFD={}", row, utf8_rune_count(row),
					grid_count_rune(&s, 0xFFFD)))
			eq_s_local(t, fmt.tprintf("spine of {} round-trips byte-exact through the resize", total), row, spine_of(total))
		}
	}
}

spine_of :: proc(n: int) -> string {
	spine_wire := "\u2500"
	b := transmute([]u8)spine_wire
	buf : [dynamic]u8
	for i := 0; i < n; i += 1 {
		for j := 0; j < len(b); j += 1 { append(&buf, b[j]) }
	}
	out := copy_string(buf)
	delete(buf)
	return out
}

// ─────────────────────────────────────────────────────────────────────────────
// MINIMUM CASE 1c — THE 4096-BYTE WORKING-BUFFER FLUSH IS A SECOND PLACE A
// GLYPH CAN BE LOST, AND IT FIRES ON EVERY FULL-SCREEN REPAINT.
//
// screen_feed copies the feed into a FEED_CHUNK_CAP-byte stack buffer and
// flushes it when the buffer fills. Mid-way through ONE feed is therefore a
// sequence boundary that has nothing to do with where the WRITES were split.
// Before the fix, that flush handed any unfinished lead bytes to `carry` and
// then went on decoding the rest of the SAME feed — but `carry` is only
// prepended at the START of a feed, so those bytes sat there while the
// continuation bytes further down the buffer decoded as orphans.
//
// The result is the flood's signature exactly: a U+FFFD painted into the
// middle of an otherwise correct row, plus a `carry` left dirty, which then
// corrupts the NEXT feed as well. This is not the resize bug wearing a
// different hat — it needs no resize at all. A full termbox frame is larger
// than FEED_CHUNK_CAP, so every repaint crosses the flush, and whether it
// lands mid-glyph depends on that frame's byte layout. That is the residual
// resize_flood flake the carry/resize fix alone did not remove (measured:
// carry/resize fix only = 2/96 storms still red; this fix added = 0/96).
//
// A naive 'A'*N test cannot see this: with no autowrap in this emulator the
// cursor clamps at cols long before the flush boundary can do damage. The
// stream has to be CUP-addressed the way a real frame is, which is what
// build_cup_frame produces.
// ─────────────────────────────────────────────────────────────────────────────

// build_cup_frame builds a CUP-addressed frame of `rows` rows of `cols` 'A'
// cells, with ONE `glyph` spliced in so that its bytes straddle the
// FEED_CHUNK_CAP boundary `cut` bytes into the glyph: the glyph starts at
// byte FEED_CHUNK_CAP - cut, so `cut` of its bytes sit before the flush and
// the remainder lands after it. It reports where it actually spliced so the
// caller can assert the intended cut really was the cut produced.
build_cup_frame :: proc(glyph: []u8, cut: int, rows, cols: int) -> (buf: [dynamic]u8, spliced_at: int) {
	buf = make([dynamic]u8, 0, rows * (cols + 16))
	target := FEED_CHUNK_CAP - cut
	spliced_at = -1
	for r := 1; r <= rows; r += 1 {
		cup := fmt.tprintf("\x1b[{};1H", r)
		cb := transmute([]u8)cup
		// Splice only between cells. If `target` ever fell inside the CUP escape
		// itself the splice would corrupt the escape, not the glyph, so we refuse
		// to splice there and let the caller see spliced_at != target.
		for k := 0; k < len(cb); k += 1 { append(&buf, cb[k]) }
		for c := 0; c < cols; c += 1 {
			if spliced_at < 0 && len(buf) == target {
				for j := 0; j < len(glyph); j += 1 { append(&buf, glyph[j]) }
				spliced_at = target
				continue
			}
			append(&buf, 'A')
		}
	}
	return buf, spliced_at
}

@(test)
screen_feed_chunk_boundary_never_strands_a_glyph :: proc(t: ^testing.T) {
	cases := []Carry_Glyph{
		Carry_Glyph{"─ U+2500 3-byte spine", 0x2500, [4]u8{0xE2, 0x94, 0x80, 0x00}, 3},
		Carry_Glyph{"U+1F600 4-byte astral", 0x1F600, [4]u8{0xF0, 0x9F, 0x98, 0x80}, 4},
	}

	for g in cases {
		garr := g.bytes
		glyph := garr[0:g.n]
		// cut = 1..n-1 are the straddling positions. cut = n is the CONTROL:
		// the glyph ends exactly ON the boundary, so nothing is split.
		for cut := 1; cut <= g.n; cut += 1 {
			frame, spliced_at := build_cup_frame(glyph, cut, 24, 200)
			tag := "STRADDLE"
			if cut == g.n { tag = "CONTROL " }

			support.check(t, fmt.tprintf("{} {} frame splices the glyph at the intended offset (cut={})", tag, g.label, cut),
				spliced_at == FEED_CHUNK_CAP - cut,
				fmt.tprintf("spliced_at={} want {}", spliced_at, FEED_CHUNK_CAP - cut))
			support.check(t, fmt.tprintf("{} {} frame is larger than the {}-byte flush so the flush really fires", tag, g.label, FEED_CHUNK_CAP),
				len(frame) > FEED_CHUNK_CAP,
				fmt.tprintf("len={} cap={}", len(frame), FEED_CHUNK_CAP))

			s : Screen
			screen_init(&s, 24, 200)
			feed_bytes(&s, frame[:])

			fffd := grid_count_rune(&s, 0xFFFD)
			found := grid_count_rune(&s, g.want)
			support.check(t, fmt.tprintf("{} {} across the {} flush (cut={}): the glyph is present exactly once", tag, g.label, FEED_CHUNK_CAP, cut),
				found == 1,
				fmt.tprintf("count(U+{})={} want 1; U+FFFD={} carry_len={}", cp_name(g.want), found, fffd, s.carry_len))
			support.check(t, fmt.tprintf("{} {} across the {} flush (cut={}): NOTHING on the grid is U+FFFD", tag, g.label, FEED_CHUNK_CAP, cut),
				fffd == 0,
				fmt.tprintf("U+FFFD={} glyph_count={} carry_len={}", fffd, found, s.carry_len))
			support.check(t, fmt.tprintf("{} {} across the {} flush (cut={}): no bytes left stranded in carry after a COMPLETE feed", tag, g.label, FEED_CHUNK_CAP, cut),
				s.carry_len == 0,
				fmt.tprintf("carry_len={} — a non-zero carry after a whole, complete stream is the lead byte(s) the flush never re-prepended", s.carry_len))
			delete(frame)
		}
	}
}

utf8_rune_count :: proc(s: string) -> int {
	n := 0
	b := transmute([]u8)s
	i := 0
	for i < len(b) {
		want := utf8_seq_len(b[i])
		if want == 0 { n += 1; i += 1; continue }
		r, consumed := utf8.decode_rune(b[i:])
		if consumed == 0 { n += 1; i += 1; continue }
		_ = r
		n += 1
		i += consumed
	}
	return n
}

// ─────────────────────────────────────────────────────────────────────────────
// MINIMUM CASE 1d — THE ESCAPE PARSER IS STREAM STATE TOO, SO A RESIZE MUST
// NOT RESET IT. (The sibling of the carry bug above, and the worse half of it.)
//
// The carry bug corrupted a GLYPH. This one puts CONTROL-SEQUENCE BYTES ON THE
// GRID AS VISIBLE CONTENT: mid-CSI painted `3HAGAIN`, a mid-OSC leaked the
// WINDOW TITLE onto row 0, a mid-`ESC (` re-created the exact charset smear
// this emulator exists to prevent. A suite that drives resizes while the app is
// mid-escape reads a row that never existed, and a mid-OSC leak puts a string
// into a frame assertion that was never meant to be content.
//
// THE RULE, same as carry's and for the same reason
//   What a resize changes is the GRID. It does not change what the next byte
//   MEANS. `state`, `csi_buf` and `csi_len` belong to the byte stream, so they
//   cross the boundary with the stream and the sequence COMPLETES afterwards,
//   evaluated against the new geometry — which is what a real terminal does:
//   the parser lives in the input layer, SIGWINCH reshapes the grid and never
//   touches it.
//
// Every row of the reported leak table gets its own case below, plus the two
// bounds cases (a completed CUP that no longer fits, by row and by column), and
// three controls: a resize with nothing pending still blanks normally, a resize
// after a COMPLETE sequence is unaffected, and `screen_init` still wipes the
// parser so two unrelated byte streams cannot inherit each other's state.
// ─────────────────────────────────────────────────────────────────────────────

// parser_state_line puts every field of the stream side of the Screen on one
// line, because "the parser was reset" and "the parser was preserved but the
// grid was wrong" look identical in a row dump.
parser_state_line :: proc(tag: string, s: ^Screen) -> string {
	return fmt.tprintf("{} state={} csi_len={} carry_len={} dropped={} rows={} cols={} cx={} cy={}",
		tag, s.state, s.csi_len, s.carry_len, s.dropped, s.rows, s.cols, s.cx, s.cy)
}

// grid_is_blank scans the LIVE grid (rows x cols) rather than a rstripped row,
// so "nothing was painted" is a statement about cells, not about the tail a
// row accessor chose to hide.
grid_is_blank :: proc(s: ^Screen) -> bool {
	for row := 0; row < s.rows; row += 1 {
		for col := 0; col < s.cols; col += 1 {
			if s.grid[screen_idx(s, row, col)] != ' ' { return false }
		}
	}
	return true
}

// CASE 1 — resize lands between ESC and its '[' (state == ESC).
// Pre-fix: the parser resets, so "[2;3HWORLD" paints literally on row 0 and
// the CUP never happens.
@(test)
screen_resize_mid_esc_completes_the_sequence_instead_of_painting_it :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 4, 40)
	feed_str(&s, "hello")
	feed_str(&s, "\x1b")
	support.check(t, "pre-resize the parser owes the family byte",
		s.state == .ESC && s.csi_len == 0, parser_state_line("pre", &s))

	screen_resize(&s, 4, 40)
	support.check(t, "the resize leaves the parser parked in ESC — it is stream state, not grid state",
		s.state == .ESC && s.csi_len == 0 && s.carry_len == 0,
		parser_state_line("post-resize", &s))

	feed_str(&s, "[2;3HWORLD")
	support.check(t, "the CUP completes after the resize and places the text at 2;3",
		row_of(&s, 1) == "  WORLD",
		fmt.tprintf("row1='{}' row0='{}' {}", row_of(&s, 1), row_of(&s, 0), parser_state_line("post-feed", &s)))
	support.check(t, "NO escape bytes were painted as text",
		!screen_contains(&s, "[2;3H") && !screen_contains(&s, "[") && row_of(&s, 0) == "",
		fmt.tprintf("row0='{}'", row_of(&s, 0)))
	support.eq_i(t, "and nothing was dropped — the sequence was parsed, not swallowed", s.dropped, 0)
}

// CASE 2 — resize lands mid-parameters (state == CSI_PARAMS, csi_len > 0).
// Pre-fix: the accumulated parameters are thrown away and repaint as text:
// `3HAGAIN` on the row.
@(test)
screen_resize_mid_csi_params_preserves_the_parameters_being_built :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 4, 40)
	feed_str(&s, "hello")
	feed_str(&s, "\x1b[2;")
	support.check(t, "pre-resize two parameter runes are in flight",
		s.state == .CSI_PARAMS && s.csi_len == 2, parser_state_line("pre", &s))

	screen_resize(&s, 4, 40)
	support.check(t, "the resize carries the half-built parameter list across unchanged",
		s.state == .CSI_PARAMS && s.csi_len == 2 && s.carry_len == 0,
		parser_state_line("post-resize", &s))

	feed_str(&s, "3HAGAIN")
	support.check(t, "the parameters rejoin: CUP 2;3 lands the text at row 1 col 2",
		row_of(&s, 1) == "  AGAIN",
		fmt.tprintf("row1='{}' row0='{}'", row_of(&s, 1), row_of(&s, 0)))
	support.check(t, "the parameter bytes never painted ('3HAGAIN' is not content anywhere)",
		!screen_contains(&s, "3H") && !screen_contains(&s, ";") && row_of(&s, 0) == "",
		fmt.tprintf("row0='{}' row1='{}'", row_of(&s, 0), row_of(&s, 1)))
	support.eq_i(t, "nothing dropped", s.dropped, 0)
}

// CASE 3 — resize lands between the last parameter DIGIT and the final byte.
// Pre-fix: the CUP is destroyed, so the glyph after it lands at column 0 of
// row 0 instead of row 3 column 4.
@(test)
screen_resize_mid_csi_digit_still_lands_the_final_byte_where_it_means :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 4, 40)
	feed_str(&s, "\x1b[3;4")
	support.check(t, "pre-resize: 3 parameter runes held, final byte not yet seen",
		s.state == .CSI_PARAMS && s.csi_len == 3, parser_state_line("pre", &s))

	screen_resize(&s, 4, 40)
	support.check(t, "the held digits survive the resize",
		s.state == .CSI_PARAMS && s.csi_len == 3,
		parser_state_line("post-resize", &s))

	feed_str(&s, "HZ")
	support.check(t, "'H' is still the final byte of the CUP, not a glyph",
		s.state == .NORMAL && s.csi_len == 0 &&
			!screen_contains(&s, "H"),
		fmt.tprintf("row0='{}' row2='{}' {}", row_of(&s, 0), row_of(&s, 2), parser_state_line("post-feed", &s)))
	support.eq_i(t, "Z lands at row 2, col 3 (CUP 3;4 against the NEW grid)",
		int(s.grid[screen_idx(&s, 2, 3)]), int('Z'))
	support.eq_i(t, "Z did NOT land at column 0 of the top row",
		int(s.grid[screen_idx(&s, 0, 0)]), int(' '))
	eq_s_local(t, "the row reads as three blanks then Z", row_of(&s, 2), "   Z")
}

// CASE 4 — resize lands mid-OSC. This is the leak that matters most: the OSC
// payload is the WINDOW TITLE, a string that must never appear as content.
// Pre-fix: `tle:secretcd` on row 0 — the title body plus the text after it.
@(test)
screen_resize_mid_osc_never_leaks_the_window_title_onto_the_grid :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 4, 40)
	feed_str(&s, "ab\x1b]0;ti")
	support.check(t, "pre-resize the parser is inside the OSC payload",
		s.state == .OSC, parser_state_line("pre", &s))

	screen_resize(&s, 4, 40)
	support.check(t, "the resize keeps us inside the OSC — the payload has no grid to leak into yet",
		s.state == .OSC && s.csi_len == 0,
		parser_state_line("post-resize", &s))

	feed_str(&s, "tle:secret\x07cd")
	support.check(t, "the title body is NOT on the grid",
		!screen_contains(&s, "secret") && !screen_contains(&s, "tle") && !screen_contains(&s, "0;"),
		fmt.tprintf("row0='{}'", row_of(&s, 0)))
	support.check(t, "the BEL still terminates the OSC and the text after it renders",
		s.state == .NORMAL && row_of(&s, 0) == "cd",
		fmt.tprintf("row0='{}' {}", row_of(&s, 0), parser_state_line("post-feed", &s)))
	support.eq_i(t, "swallowing an OSC is parsing, not loss — nothing counted as dropped", s.dropped, 0)
}

// CASE 5 — resize lands between ESC and the charset DESIGNATOR byte.
// Pre-fix: `Bion` on the row — the designator painted, i.e. the exact smear
// class ("delete_sess(Bn") this emulator was written to eliminate.
@(test)
screen_resize_mid_charset_never_paints_the_designator_byte :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 4, 40)
	feed_str(&s, "delete_sess")
	feed_str(&s, "\x1b(")
	support.check(t, "pre-resize the parser owes exactly one designator byte",
		s.state == .CHARSET, parser_state_line("pre", &s))

	screen_resize(&s, 4, 40)
	support.check(t, "the resize keeps the designation pending",
		s.state == .CHARSET && s.carry_len == 0,
		parser_state_line("post-resize", &s))

	feed_str(&s, "Bion")
	support.check(t, "the designator 'B' is consumed by the resize-straddling designation, never painted",
		!screen_contains(&s, "B") && !screen_contains(&s, "("),
		fmt.tprintf("row0='{}'", row_of(&s, 0)))
	support.check(t, "only the three real glyphs render (the grid blanked on resize, so the row is 'ion', not 'Bion')",
		row_of(&s, 0) == "ion" && utf8_rune_count(row_of(&s, 0)) == 3,
		fmt.tprintf("row0='{}' runes={}", row_of(&s, 0), utf8_rune_count(row_of(&s, 0))))
	support.eq_i(t, "and they were parsed, not dropped", s.dropped, 0)
}

// THE BOUNDS EDGE THE FIX HAS TO ANSWER: a CUP whose coordinates were valid for
// the OLD size and are out of bounds for the NEW one. That is a bounds
// question — screen_in_bounds / the put guards — not a parser question, and the
// answer must be "counted and harmless", never "silent loss" and never a crash.
// Completing the sequence after the resize is what makes this reachable at all,
// so both axes get proven here: row out of range, and column out of range.
@(test)
screen_resize_out_of_bounds_cup_is_counted_not_corrupting :: proc(t: ^testing.T) {
	// ── ROW out of range: CUP written for a 10-row screen, grid is now 3. ────
	s : Screen
	screen_init(&s, 10, 20)
	feed_str(&s, "\x1b[9;4")
	support.check(t, "row 9 is legal while the screen is 10 rows deep",
		s.state == .CSI_PARAMS && s.csi_len == 3, parser_state_line("pre", &s))

	screen_resize(&s, 3, 20)
	feed_str(&s, "HNOPE")
	support.check(t, "the sequence still COMPLETES (it was not voided on suspicion of the bounds)",
		s.state == .NORMAL && s.csi_len == 0, parser_state_line("post-completion", &s))
	support.check(t, "the cursor really is off the grid the glyphs were aimed at",
		s.cy == 8 && s.rows == 3 && !screen_in_bounds(&s, s.cy, s.cx),
		parser_state_line("aim", &s))
	support.check(t, "nothing painted anywhere on the grid",
		!screen_contains(&s, "NOPE") && grid_is_blank(&s),
		fmt.tprintf("row0='{}' blank={}", row_of(&s, 0), grid_is_blank(&s)))
	support.eq_i(t, "EVERY glyph that could not land is COUNTED in dropped (no silent loss)",
		s.dropped, 4)

	// Recovery: the drop must not wedge the emulator.
	feed_str(&s, "\x1b[1;1Hback")
	eq_s_local(t, "the next IN-BOUNDS CUP renders normally", row_of(&s, 0), "back")
	support.eq_i(t, "…and the earlier drops are still counted (the audit survives)", s.dropped, 4)

	// ── COLUMN out of range: CUP written for a 20-col screen, grid is now 10. ─
	c : Screen
	screen_init(&c, 3, 20)
	feed_str(&c, "\x1b[1;18")
	screen_resize(&c, 3, 10)
	feed_str(&c, "H")
	support.check(t, "the completed CUP aims at a column the new grid does not have",
		c.cx == 17 && c.cols == 10 && !screen_in_bounds(&c, c.cy, c.cx),
		parser_state_line("col-aim", &c))
	feed_str(&c, "gone")
	support.check(t, "the column is what no longer fits, and every glyph lost to it is counted",
		c.dropped == 4,
		parser_state_line("col-drop", &c))
	support.check(t, "…with nothing painted on the narrower grid",
		grid_is_blank(&c) && !screen_contains(&c, "gone"),
		fmt.tprintf("row0='{}' blank={}", row_of(&c, 0), grid_is_blank(&c)))
	feed_str(&c, "\x1b[1;1Hstill_here")
	eq_s_local(t, "…and the emulator recovers on the narrower grid", row_of(&c, 0), "still_here")

	// ── The IN-BOUNDS half: coordinates valid for BOTH sizes must be untouched
	// by any of this. A 2;3 CUP is legal before and after 40 -> 10 columns.
	b : Screen
	screen_init(&b, 4, 40)
	feed_str(&b, "\x1b[2;3")
	screen_resize(&b, 4, 10)
	feed_str(&b, "Hfine")
	eq_s_local(t, "a CUP valid on both grids lands the same way after the resize",
		row_of(&b, 1), "  fine")
	support.eq_i(t, "…with nothing dropped", b.dropped, 0)
}

// ── CONTROL 1 — a resize with NO pending escape blanks the grid normally.
// This is unchanged behaviour; it passes before the fix too, which is the
// point: preserving parser state must not disturb the ordinary path.
@(test)
screen_resize_with_no_pending_escape_still_blanks_normally :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 3, 10)
	feed_str(&s, "0123456789")
	feed_str(&s, "\x1b[3;1Habcdefghij")
	support.check(t, "the control starts from a QUIESCENT parser (so it is not accidentally testing the new path)",
		s.state == .NORMAL && s.csi_len == 0 && s.carry_len == 0,
		parser_state_line("pre", &s))
	eq_s_local(t, "…with content painted on two rows", row_of(&s, 2), "abcdefghij")

	// One more in-bounds glyph so the pre-resize state is a live, mid-frame one
	// rather than a just-initialised screen.
	feed_str(&s, "\x1b[2;1Hmid-frame")
	initial_dropped := s.dropped
	screen_resize(&s, 2, 5)
	support.check(t, "the grid blanks exactly as python's `self.grid = [[' ']*cols …]` does",
		grid_is_blank(&s) && s.rows == 2 && s.cols == 5,
		fmt.tprintf("blank={} rows={} cols={} row0='{}'", grid_is_blank(&s), s.rows, s.cols, row_of(&s, 0)))
	support.check(t, "…and the stream side is quiescent, so nothing was carried that need not be",
		s.state == .NORMAL && s.csi_len == 0 && s.carry_len == 0 && s.dropped == initial_dropped,
		parser_state_line("post-resize", &s))
	feed_str(&s, "abcde")
	eq_s_local(t, "…and the resized grid renders normally afterwards", row_of(&s, 0), "abcde")
}

// ── CONTROL 2 — a COMPLETE escape sequence entirely before the resize is
// unaffected by the preservation. Nothing in the parser outlives a completed
// sequence, and the cursor is geometry state that legitimately re-homes.
@(test)
screen_resize_after_a_complete_escape_sequence_is_unaffected :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 4, 40)
	feed_str(&s, "\x1b[2;7Hdone")
	eq_s_local(t, "the sequence rendered before the resize", row_of(&s, 1), "      done")
	support.check(t, "…leaving a completed parser: NORMAL, no parameters pending",
		s.state == .NORMAL && s.csi_len == 0, parser_state_line("pre", &s))

	initial_dropped := s.dropped
	screen_resize(&s, 4, 40)
	support.check(t, "the resize preserved NOTHING from a finished sequence",
		s.state == .NORMAL && s.csi_len == 0 && s.carry_len == 0 && s.dropped == initial_dropped,
		parser_state_line("post-resize", &s))
	support.check(t, "…and blanked its output like any other content",
		grid_is_blank(&s),
		fmt.tprintf("row1='{}' blank={}", row_of(&s, 1), grid_is_blank(&s)))
	feed_str(&s, "more")
	eq_s_local(t, "the cursor re-homed with the grid: the text lands at 0,0, NOT at the pre-resize CUP",
		row_of(&s, 0), "more")
	support.eq_i(t, "…cx proves it", s.cx, 4)
}

// ── CONTROL 3 — screen_init is still a FULL reset of the parser.
// This is the guard on the fix itself: init is the CONSTRUCTION path, and a
// parser that survived from one scenario into the next would be cross-talk
// between unrelated byte streams — a far worse bug than the one resize needs.
@(test)
screen_init_still_full_resets_the_parser_no_stream_crosstalk :: proc(t: ^testing.T) {
	s : Screen
	screen_init(&s, 3, 20)
	// Park the parser mid-CSI *and* strand a UTF-8 lead byte, so both kinds of
	// in-flight stream state are present at once.
	stalled := "\x1b[5;\xE2"
	feed_bytes(&s, transmute([]u8)stalled)
	support.check(t, "the stream is mid-escape AND mid-glyph",
		s.state == .CSI_PARAMS && s.csi_len == 2 && s.carry_len == 1,
		parser_state_line("mid-stream", &s))

	// resize keeps it — that is the fix.
	screen_resize(&s, 3, 20)
	support.check(t, "resize preserves it",
		s.state == .CSI_PARAMS && s.csi_len == 2 && s.carry_len == 1,
		parser_state_line("post-resize", &s))

	// …but construction wipes it.
	screen_init(&s, 2, 10)
	support.check(t, "screen_init resets the parser, the parameter buffer, the carry AND the drop audit",
		s.state == .NORMAL && s.csi_len == 0 && s.carry_len == 0 && s.dropped == 0 && grid_is_blank(&s),
		parser_state_line("post-init", &s))

	// And no cross-talk in the observable stream: the 'H' that WOULD have been
	// the final byte of the dead CUP is now ordinary TEXT.
	feed_str(&s, "Hx")
	eq_s_local(t, "a fresh screen over the same variable sees TEXT, not the tail of a stranger's sequence",
		row_of(&s, 0), "Hx")
	support.check(t, "…and stayed quiescent",
		s.state == .NORMAL && s.csi_len == 0 && s.carry_len == 0,
		parser_state_line("post-fresh-feed", &s))
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
