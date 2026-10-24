package pty

// ─────────────────────────────────────────────────────────────────────────────
// screen.odin — the Screen emulator, PORTED from dev/tui_drive.py:55-196.
//
// WHY THIS EXISTS AT ALL (port of the python header comment, which is the
// single most important sentence in this migration)
//   termbox's renderer emits a CELL DIFF: it cursor-addresses and writes only
//   the characters whose cell actually CHANGED. Grepping the raw byte stream
//   for "delete_session" therefore FAILS ON A CORRECT RENDER — the `e` at
//   column 4 was already `e` in the previous frame, so nothing was sent for
//   it, and the word arrives with holes ("delte_sss"). A check written that
//   way gives you a red suite on working code and, far worse, **a green suite
//   on code that never painted**. Byte-grep is not a weaker substitute for
//   this emulator; it is a *different and invalid assertion*, and replacing
//   screen-scraping with it is a regression, not a simplification.
//
//   So the harness keeps a screen: cursor + grid, updated from the same bytes
//   the terminal sees. What we assert on is **what a user would read**.
//
// WHAT WAS DELIBERATELY CHANGED FROM THE PYTHON, AND WHY (both are
// improvements with a named failure mode behind them; nothing else differs)
//   1. **Escape state persists across `feed()` calls.** The python parser used
//      a regex match and, on a *truncated* escape at the end of a chunk,
//      `break`-ed out of the whole feed loop — dropping the rest of that
//      chunk. With a pty, an escape sequence can be split across reads at ANY
//      byte, so that drop is data loss on a correct stream. Here the parser is
//      an explicit state machine (Esc_State) whose state survives a feed
//      boundary, so a sequence split mid-parameters still parses when the rest
//      arrives. Unit-tested: screen_split_escape_across_feeds.
//   2. **Carry buffer is per-Screen, not module-global.** Same decoding, but
//      two Screens cannot corrupt each other.
//
// WHAT IS NOT IMPLEMENTED, ON PURPOSE
//   Colours, attributes, wrap-around, scrolling, alternate screen, autowrap.
//   This emulator models POSITION AND CONTENT ONLY, because that is the entire
//   surface the assertions need and every unimplemented feature is a feature
//   that cannot silently diverge. A write outside the grid is dropped exactly
//   as python's `0 <= cy < rows` guard drops it, and that is recorded by
//   test rather than assumed.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:unicode/utf8"

MAX_SCREEN_ROWS :: 64
MAX_SCREEN_COLS :: 256

// FEED_CHUNK_CAP is the size of screen_feed's stack working buffer. Named so
// the flush boundary and the tests that straddle it agree on what it is.
FEED_CHUNK_CAP :: 4096

// Esc_State is the parser's position in an escape sequence. The whole point
// of spelling it out is change (1) above: python's regex could not pause, so
// a truncated escape dropped bytes.
Esc_State :: enum {
	NORMAL,
	ESC,          // saw ESC, next byte decides the family
	CSI_PARAMS,   // saw ESC [, accumulating parameter runes
	OSC,          // saw ESC ] (OSC … BEL / ST)
	CHARSET,      // saw ESC ( / ESC ) / ESC #, one more byte completes it
}

Screen :: struct {
	rows : int,
	cols : int,
	cx   : int,
	cy   : int,

	// Grid is row-major, rows*cols cells, each holding ONE rune. A cell holds
	// a rune rather than a string because width-2 glyphs must blank the cell
	// AFTER them, which requires the cell to be a fixed-size unit.
	grid : [MAX_SCREEN_ROWS * MAX_SCREEN_COLS]rune,

	state : Esc_State,

	// csi_buf holds the parameter runes of the CSI sequence being parsed.
	// 64 is generous: termbox emits at most two parameters.
	csi_buf   : [64]rune,
	csi_len   : int,

	// carry holds a UTF-8 sequence split across feed() calls. 4 bytes is the
	// maximum length of a UTF-8 sequence, so this cannot overflow.
	carry     : [4]u8,
	carry_len : int,

	// How many bytes were dropped because they could not fit the model. Kept
	// so a test can assert the emulator silently swallowed nothing it should
	// have handled.
	dropped : int,
}

// screen_init zeroes and sizes the screen. Grid is pre-blanked so an unread
// cell reads as ' ' rather than 0, matching python's [[" "]*cols].
//
// This stays a FULL reset, including `carry`, and it must: screen_init is the
// CONSTRUCTION path. Its call sites are `pty_spawn` (tests/pty/pty.odin, one
// brand-new driver per scenario) and every test that builds a Screen from
// scratch. None of them has a stream history to keep, and a `carry` that
// survived from one scenario into the next would be cross-talk between
// unrelated byte streams — a far worse bug than the one resize needed.
// Only `screen_resize` preserves anything, and what it preserves is the state of
// the BYTE STREAM: the pending UTF-8 bytes AND where the escape parser stands
// inside a sequence.
screen_init :: proc(s: ^Screen, rows, cols: int) {
	s.rows = rows
	s.cols = cols
	s.cx = 0
	s.cy = 0
	s.state = .NORMAL
	s.csi_len = 0
	s.carry_len = 0
	s.dropped = 0
	for i := 0; i < MAX_SCREEN_ROWS * MAX_SCREEN_COLS; i += 1 {
		s.grid[i] = ' '
	}
}

// screen_resize replaces the grid, keeping nothing — exactly python's
// `self.grid = [[" "] * cols for _ in range(rows)]`. Keeping content across a
// resize would be inventing a reflow rule the harness has no business having.
//
// EXCEPT THE BYTES THAT ARE NOT GRID CONTENT YET.
//
// `carry` holds a UTF-8 sequence whose tail has not arrived. It belongs to the
// BYTE STREAM, not to the screen geometry: there is no reflow question to
// invent a rule for, because it has no cell yet. `screen_init` resets it for
// good reason — init is the CONSTRUCTION path and a brand-new Screen has no
// stream history to preserve. A resize is not a construction, it is the same
// stream continuing over a different grid, so resize takes the pending bytes
// with it and hands them straight back, same bytes, same order, still
// incomplete.
//
// WHY THE OLD `screen_resize == screen_init` WAS A REAL DEFECT, NOT A CORNER
// CASE. A TIOCSWINSZ landing between a lead byte and its continuation bytes
// dropped the lead byte. The continuation then decoded with no lead and painted
// U+FFFD — one replacement character per orphaned byte, so TWO for the
// 3-byte `─` split after its lead and THREE for a 4-byte astral glyph split
// after its lead. resize_flood read that as `rules=1` on a row whose WIDTH
// was correct: "the surviving frame is the FINAL size, not a stale one" was
// reported about a frame that was fine, because the EMULATOR had eaten bytes
// the app really wrote. Proven by screen_resize_preserves_utf8_carry_at_every_
// boundary and screen_resize_mid_glyph_leaves_a_pure_spine_row, both of which
// fail against the pre-fix code and pass against this.
//
// THE ESCAPE PARSER IS STREAM STATE TOO, AND ITS RESET WAS THE WORSE HALF.
//
// The exact same reasoning covers `state`, `csi_buf` and `csi_len`. What a
// resize changes is the GRID. It does not change what the next BYTE MEANS. A
// resize landing inside an escape sequence used to send the parser back to
// NORMAL with an empty parameter buffer, so the rest of that sequence decoded
// as TEXT and got painted: mid-CSI left `3HAGAIN` on the row, a mid-OSC leaked
// the window title onto the grid, and a mid-`ESC (` re-created the very
// charset smear this emulator exists to prevent — control-sequence bytes as
// visible content, which is exactly the class of wrong reading that byte-
// grepping would have produced.
//
// WHY PRESERVING IS WHAT A REAL TERMINAL DOES. The parser is a property of the
// input layer (xterm's state machine, VTE's parser); the grid is the terminal
// object. SIGWINCH re-shapes the grid and never touches the parser, so a
// sequence that straddles a resize simply CONTINUES and is evaluated against
// the NEW geometry. Preserving it is the same call the carry fix made, for the
// same reason: the bytes are mid-flight, they are not content yet.
//
// THE ALTERNATIVE CONSIDERED AND REJECTED — void the pending sequence but
// SWALLOW it (never paint it, never complete it). That stops the smear and is
// still wrong. A real terminal DOES complete the sequence, so voiding it drops
// a positioning verb the app really sent and leaves the cursor at its pre-
// resize position while the app believes it moved: every following write of
// that frame lands one cursor-jump off. That positional desync is invisible to
// the "no literal escape bytes on the grid" check that voiding exists to
// satisfy, and it corrupts the NEXT frame rather than this one. Completion
// cannot do that: the sequence means what it meant before the resize, it is
// just applied to a different grid.
//
// AND WHEN THE COMPLETED SEQUENCE NO LONGER FITS? That is a BOUNDS question,
// not a parser question, and it goes through the guards that already exist. A
// CUP written for a 10-row screen that completes after a resize to 3 puts the
// cursor at row 9 of a 3-row grid; `screen_put_cursor`'s guards drop the write
// and COUNT it in `dropped`, and the next in-bounds CUP renders normally — the
// same recovery an out-of-bounds CUP with no resize at all already had. Not a
// crash, not silent loss: see screen_resize_out_of_bounds_cup_*. `dropped` is
// therefore lifted across the resize too — it is a cumulative audit of the
// STREAM, not grid content, and wiping it at a resize would delete the very
// evidence the counter exists to provide.
screen_resize :: proc(s: ^Screen, rows, cols: int) {
	// Lift the whole byte-stream side of the Screen across the reset, field by
	// field, so a future stream-level field cannot be silently forgotten, then
	// rebuild the grid from blank.
	carry     := s.carry
	carry_len := s.carry_len
	state     := s.state
	csi_buf   := s.csi_buf
	csi_len   := s.csi_len
	dropped   := s.dropped

	screen_init(s, rows, cols)

	s.carry     = carry
	s.carry_len = carry_len
	s.state     = state
	s.csi_buf   = csi_buf
	s.csi_len   = csi_len
	s.dropped   = dropped
}

screen_idx :: proc(s: ^Screen, r, c: int) -> int {
	return r * s.cols + c
}

screen_in_bounds :: proc(s: ^Screen, r, c: int) -> bool {
	return 0 <= r && r < s.rows && 0 <= c && c < s.cols
}

// screen_cell is the raw accessor. Out of bounds reads are a blank cell rather
// than a trap so a test asking about row 40 of a 24-row screen gets ' ' and a
// separate, explicit bounds assertion rather than a crash.
screen_cell :: proc(s: ^Screen, r, c: int) -> rune {
	if !screen_in_bounds(s, r, c) { return ' ' }
	return s.grid[screen_idx(s, r, c)]
}

// screen_put is a direct write, used by tests that need to pre-seed a grid.
screen_put :: proc(s: ^Screen, r, c: int, ch: rune) {
	if !screen_in_bounds(s, r, c) { return }
	s.grid[screen_idx(s, r, c)] = ch
}

// ─────────────────────────────────────────────────────────────────────────────
// _put — placing one glyph, including the wide-character blank
// ─────────────────────────────────────────────────────────────────────────────
//
// The width comes from `tb_wcwidth` (T3), NOT from a local guess, because the
// product's layout uses the same authority. The two width-2 behaviours here
// are the ones that make whole-rune-deletion evidence mean anything:
//   * the cell AFTER a wide glyph is forced to blank, so a later narrow write
//     cannot leave half a glyph behind; and
//   * the cursor advances by the GLYPH WIDTH, not by one, so the next write
//     lands at N+2.
// ─────────────────────────────────────────────────────────────────────────────
screen_put_cursor :: proc(s: ^Screen, ch: rune) {
	if !(0 <= s.cy && s.cy < s.rows) {
		s.dropped += 1
		return
	}
	w := tb_width_of(ch)
	if 0 <= s.cx && s.cx < s.cols {
		s.grid[screen_idx(s, s.cy, s.cx)] = ch
		if w == 2 && s.cx + 1 < s.cols {
			s.grid[screen_idx(s, s.cy, s.cx + 1)] = ' '
		}
	} else {
		// Column-wise, the same story as the row guard above: this emulator has
		// no autowrap, so a glyph past the last column is genuinely gone and has
		// to be COUNTED. Un-counted, "the grid has no room left" and "the
		// emulator lost a byte" are indistinguishable — which matters most right
		// after a resize, when a cursor placed by a sequence written for the OLD
		// width routinely lands past the NEW one.
		s.dropped += 1
	}
	s.cx += w
	if s.cx > s.cols { s.cx = s.cols }
}

screen_clear_row :: proc(s: ^Screen, y, x0, x1: int) {
	if !(0 <= y && y < s.rows) { return }
	for x := max(0, x0); x < min(s.cols, x1); x += 1 {
		s.grid[screen_idx(s, y, x)] = ' '
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// feed — the entry point
// ─────────────────────────────────────────────────────────────────────────────
screen_feed :: proc(s: ^Screen, data: []u8) {
	// Decode incrementally FIRST, then parse runes. A rune split across two
	// writes must not corrupt the grid; the carry buffer is what guarantees
	// that, and screen_feed_split_utf8 is the test.
	//
	// We work on a stack copy: leftover bytes go back into `carry` and are
	// prepended to the NEXT feed. Max pending is one incomplete sequence
	// (<=3 bytes) plus the new chunk, so the working buffer is sized for
	// carry + input with a fixed bound.
	local_cap :: FEED_CHUNK_CAP
	local : [local_cap]u8
	li := 0
	for i := 0; i < s.carry_len; i += 1 {
		local[li] = s.carry[i]
		li += 1
	}
	s.carry_len = 0

	for i := 0; i < len(data); i += 1 {
		if li >= local_cap {
			// Flush what we have and continue. Bounded, never unbounded.
			screen_decode_into(s, local[:li])
			// THE FLUSH IS NOT THE END OF THE STREAM. If the flush boundary cut a
			// multi-byte sequence, decode_into stashed the unfinished lead bytes
			// in `carry` — but those bytes belong to the MIDDLE of this feed, not
			// to its end, and nothing prepends them again until the NEXT call. So
			// the continuation bytes further down `data` would decode as orphans:
			// U+FFFD painted into an otherwise correct row, and a stale `carry`
			// that then corrupts whatever comes next. Reclaim the stash to the
			// head of the working buffer so the sequence continues in order.
			//
			// This is the SECOND loss path behind the resize_flood flake: a full
			// termbox frame is >4096 bytes, so the flush happens on every repaint
			// and lands mid-glyph whenever the frame's byte layout puts one there.
			// A plain 'A'*N test cannot see it (no autowrap, so the cursor clamps
			// before the boundary does any damage); a CUP-addressed frame can.
			rest := s.carry_len
			if rest > 0 {
				for k := 0; k < rest; k += 1 { local[k] = s.carry[k] }
				s.carry_len = 0
			}
			li = rest
			if li >= local_cap { break } // unreachable: a stash is <=3 bytes
		}
		local[li] = data[i]
		li += 1
	}
	if li > 0 {
		screen_decode_into(s, local[:li])
	}
}

// screen_decode_into decodes as many COMPLETE runes from `b` as possible and
// stashes any incomplete tail in the Screen's carry buffer.
//
// Incomplete vs invalid is decided from the LEAD BYTE, not from the decoder's
// failure: `utf8.decode_rune` returns RUNE_ERROR for both, and conflating them
// would turn a mid-sequence feed boundary into a spurious U+FFFD — exactly the
// corruption this buffer exists to prevent.
screen_decode_into :: proc(s: ^Screen, b: []u8) {
	i := 0
	for i < len(b) {
		want := utf8_seq_len(b[i])
		if want == 0 {
			// Not a valid lead byte at all. errors="replace" semantics: one
			// U+FFFD per bad byte, advance one.
			screen_consume_rune(s, utf8.RUNE_ERROR)
			i += 1
			continue
		}
		if len(b) - i < want {
			// Incomplete sequence at the end of this chunk. Stash and stop;
			// the rest arrives in the next feed.
			for k := 0; k < len(b) - i; k += 1 {
				s.carry[s.carry_len] = b[i + k]
				s.carry_len += 1
			}
			return
		}
		r, n := utf8.decode_rune(b[i:])
		if n == 0 {
			screen_consume_rune(s, utf8.RUNE_ERROR)
			i += 1
			continue
		}
		// Decode exactly `want` bytes and no more, then advance by that.
		// Using `n` from the decoder is what we want, but assert it agrees
		// with the lead-byte length so a decoder change cannot silently
		// re-frame the stream.
		if n != want {
			screen_consume_rune(s, utf8.RUNE_ERROR)
			i += 1
			continue
		}
		screen_consume_rune(s, r)
		i += n
	}
}

// utf8_seq_len returns the length implied by a lead byte, or 0 if the byte
// cannot start a sequence. Continuation bytes (0x80..0xBF) as a lead are
// invalid, which is what we want: they can only reach here out of context.
utf8_seq_len :: proc(b: u8) -> int {
	if b < 0x80 { return 1 }
	if b < 0xC0 { return 0 }
	if b < 0xE0 { return 2 }
	if b < 0xF0 { return 3 }
	if b < 0xF8 { return 4 }
	return 0
}

// ─────────────────────────────────────────────────────────────────────────────
// screen_consume_rune — the state machine python's regex loop was
// ─────────────────────────────────────────────────────────────────────────────
screen_consume_rune :: proc(s: ^Screen, c: rune) {
	switch s.state {
	case .NORMAL:
		if c == '\x1b' {
			s.state = .ESC
			return
		}
		screen_control_or_text(s, c)
	case .ESC:
		if c == '[' {
			s.state = .CSI_PARAMS
			s.csi_len = 0
			return
		}
		if c == ']' {
			s.state = .OSC
			return
		}
		if c == '(' || c == ')' || c == '#' {
			// ESC ( X / ESC ) X / ESC # 8. ONE more byte and it is done.
			// THIS is the family whose omission smeared "(B" into the python
			// harness's grid and turned "delete_session" into "delete_sess(Bn".
			s.state = .CHARSET
			return
		}
		// ESC = / ESC > / ESC 7 / ESC 8 / ESC c … generic 2-byte fallback.
		// Broad on purpose: an unrecognised escape must consume its own byte
		// rather than paint it.
		s.state = .NORMAL
	case .CHARSET:
		// The designator byte. Consumed, never painted.
		s.state = .NORMAL
	case .CSI_PARAMS:
		if c == '\x07' {
			// A BEL inside a CSI is not a terminator; abandon the sequence
			// rather than paint it.
			s.state = .NORMAL
			s.csi_len = 0
			return
		}
		if is_csi_final(c) {
			params := runes_to_string(s.csi_buf[:s.csi_len])
			s.csi_len = 0
			s.state = .NORMAL
			screen_csi(s, params, c)
			return
		}
		if s.csi_len < len(s.csi_buf) {
			s.csi_buf[s.csi_len] = c
			s.csi_len += 1
		} else {
			// Overflow: drop the sequence rather than mis-parse a truncated
			// parameter list.
			s.state = .NORMAL
			s.csi_len = 0
			s.dropped += 1
		}
	case .OSC:
		// OSC … BEL, or OSC … ST (ESC \). Neither contributes content.
		if c == '\x07' {
			s.state = .NORMAL
			return
		}
		if c == '\x1b' {
			// Could be the ST's ESC. Go back to ESC and let `\` finish it;
			// anything else re-enters the normal escape path.
			s.state = .ESC
			return
		}
	}
}

is_csi_final :: proc(c: rune) -> bool {
	return ('@' <= c && c <= 'Z') || ('a' <= c && c <= 'z') || c == '`'
}

screen_control_or_text :: proc(s: ^Screen, c: rune) {
	if c == '\r' {
		s.cx = 0
		return
	}
	if c == '\n' {
		s.cy += 1
		return
	}
	if c == '\b' {
		s.cx = max(0, s.cx - 1)
		return
	}
	if c == '\t' {
		// +8 columns, clamped — python's `min(self.cols, self.cx + 8)`. No
		// tab stops: the TUI's layout model has none, so neither has the
		// emulator, and a real tab-stop implementation here would make the
		// emulator disagree with the renderer it is modelling.
		s.cx = min(s.cols, s.cx + 8)
		return
	}
	screen_put_cursor(s, c)
}

// ─────────────────────────────────────────────────────────────────────────────
// screen_csi — the verbs. Ported one-for-one from python's `csi`.
// ─────────────────────────────────────────────────────────────────────────────
screen_csi :: proc(s: ^Screen, params: string, final: rune) {
	private := len(params) > 0 && params[0] == '?'
	start := 0
	if private { start = 1 }

	// Parse the semicolon-separated integers. Empty fields are skipped, which
	// is what python's `if x.isdigit()` does — so "1;;3" yields [1, 3].
	nums : [16]int
	count : int = 0
	cur : int = 0
	have : bool = false
	i := start
	for i < len(params) {
		ch := params[i]
		if ch == ';' {
			if have {
				if count < len(nums) { nums[count] = cur; count += 1 }
			}
			cur = 0
			have = false
		} else if '0' <= ch && ch <= '9' {
			cur = cur * 10 + int(ch - '0')
			have = true
		}
		i += 1
	}
	if have && count < len(nums) {
		nums[count] = cur
		count += 1
	}

	// DECSET/DECREST and SGR change modes and colours, never content. Ignored
	// for the same reason python ignores them: this emulator models position
	// and glyph only, and pretending to track colours would be a lie that no
	// assertion asks for.
	if private || final == 'm' { return }

	// `n` defaults to 1 when no parameter is present, matching
	// `nums[0] if nums else 1`.
	n := 1
	if count >= 1 { n = nums[0] }

	if final == 'H' || final == 'f' {
		// Cursor position. These are THE SAME VERB (CUP); `f` is the
		// alternative final byte and must behave identically or a renderer
		// that prefers one would read as broken.
		s.cy = 0
		s.cx = 0
		if count >= 1 { s.cy = nums[0] - 1 }
		if count >= 2 { s.cx = nums[1] - 1 }
		return
	}
	if final == 'A' { s.cy -= n; return }
	if final == 'B' { s.cy += n; return }
	if final == 'C' { s.cx += n; return }
	if final == 'D' { s.cx -= n; return }
	if final == 'd' { s.cy = n - 1; return }
	if final == '`' { s.cx = n - 1; return }
	if final == 'J' {
		if n == 2 {
			// Erase entire screen.
			for y := 0; y < s.rows; y += 1 {
				screen_clear_row(s, y, 0, s.cols)
			}
		} else if n == 0 {
			// Erase cursor-to-end-of-screen.
			screen_clear_row(s, s.cy, s.cx, s.cols)
			for y := s.cy + 1; y < s.rows; y += 1 {
				screen_clear_row(s, y, 0, s.cols)
			}
		}
		return
	}
	if final == 'K' {
		if n == 0 {
			screen_clear_row(s, s.cy, s.cx, s.cols)
		} else if n == 1 {
			screen_clear_row(s, s.cy, 0, s.cx + 1)
		} else {
			screen_clear_row(s, s.cy, 0, s.cols)
		}
		return
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Accessors used by assertions
// ─────────────────────────────────────────────────────────────────────────────

// screen_row_text returns row r with trailing blanks stripped, python's
// `"".join(r).rstrip()`. Trailing-only: leading blanks are CONTENT (they are
// how a column-aligned label starts) and must survive.
screen_row_text :: proc(s: ^Screen, r: int, buf: ^[dynamic]u8) -> bool {
	delete_all(buf)
	if !screen_in_bounds(s, r, 0) { return false }
	end := s.cols
	for end > 0 {
		if s.grid[screen_idx(s, r, end - 1)] != ' ' { break }
		end -= 1
	}
	for c := 0; c < end; c += 1 {
		encode_rune_into(buf, s.grid[screen_idx(s, r, c)])
	}
	return true
}

// screen_text renders the whole screen.
screen_text :: proc(s: ^Screen, buf: ^[dynamic]u8) {
	delete_all(buf)
	for r := 0; r < s.rows; r += 1 {
		if r > 0 { append(buf, '\n') }
		end := s.cols
		for end > 0 {
			if s.grid[screen_idx(s, r, end - 1)] != ' ' { break }
			end -= 1
		}
		for c := 0; c < end; c += 1 {
			encode_rune_into(buf, s.grid[screen_idx(s, r, c)])
		}
	}
}

// screen_contains is THE assertion primitive: does the rendered screen, as a
// user would read it, contain this substring? Note this is over the GRID, not
// over the byte stream — which is the entire point of the file.
screen_contains :: proc(s: ^Screen, needle: string) -> bool {
	buf : [dynamic]u8
	screen_text(s, &buf)
	defer delete(buf)
	return contains_bytes(string(buf[:]), needle)
}

encode_rune_into :: proc(out: ^[dynamic]u8, r: rune) {
	b, n := utf8.encode_rune(r)
	for i := 0; i < n; i += 1 {
		append(out, b[i])
	}
}

runes_to_string :: proc(rs: []rune) -> string {
	buf : [dynamic]u8
	defer delete(buf)
	for r in rs {
		encode_rune_into(&buf, r)
	}
	return copy_string(buf)
}

copy_string :: proc(b: [dynamic]u8) -> string {
	if len(b) == 0 { return "" }
	out := make([]u8, len(b))
	for i := 0; i < len(b); i += 1 { out[i] = b[i] }
	return string(out)
}

delete_all :: proc(b: ^[dynamic]u8) {
	clear(&b^)
}

// screen_debug_row is a diagnostic rendering used in failure detail strings.
// It shows the cell boundaries explicitly, because "the grid is wrong" is
// undebuggable without them.
screen_debug_row :: proc(s: ^Screen, r: int) -> string {
	if r < 0 || r >= s.rows { return "<out of range>" }
	buf : [dynamic]u8
	defer delete(buf)
	for c := 0; c < s.cols; c += 1 {
		ch := s.grid[screen_idx(s, r, c)]
		if ch == ' ' {
			append(&buf, '.')
			append(&buf, ' ')
		} else {
			encode_rune_into(&buf, ch)
			append(&buf, ' ')
		}
	}
	return copy_string(buf)
}
