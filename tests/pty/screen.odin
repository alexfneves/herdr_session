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
screen_resize :: proc(s: ^Screen, rows, cols: int) {
	screen_init(s, rows, cols)
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
	local_cap :: 4096
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
			li = 0
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
