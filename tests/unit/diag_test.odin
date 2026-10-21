package unit

// diag_test.odin — the truncation contract of `ui.diag_head`, now that the
// symbol has a home a test can reach.
//
// T2 re-homed this out of `package main` (src/main.odin:960). While it lived
// there it was invisible to `tests/`, which left deleting these proofs as the
// only option — the exact silent loss (ISC-A-1) this migration exists to make
// impossible.
//
// These are ADDITIVE. The original battery in src/app_cases.odin keeps running
// against main's thin forwarder until T10 retires it, so during the overlap
// the behaviour is asserted twice rather than moved. The parity rows say so.
//
// WHY THE WIDTH RULE MATTERS AT ALL: `diag_head` feeds the footer's per-host
// diagnostic, and those `why` strings are often whole ssh traces. Truncate on
// a byte and the footer paints a replacement glyph where the reason was — the
// user sees a corrupted row exactly when the host has already failed.

import "core:fmt"
import "core:strings"
import "core:testing"

import ui "../../src/ui"
import support "../support"

ELL :: "…"

@(test)
diag_head_short_line_passes_through :: proc(t: ^testing.T) {
	support.eq(t, "single short line passes through",
		ui.diag_head("connection refused", 44), "connection refused")
}

@(test)
diag_head_takes_only_the_first_line :: proc(t: ^testing.T) {
	support.eq(t, "only the first line of a multi-line trace is used",
		ui.diag_head("banner: ssh refused\nsecond line\nthird", 44),
		"banner: ssh refused")
}

@(test)
diag_head_treats_crlf_like_lf :: proc(t: ^testing.T) {
	// A CRLF-terminated trace must not leave a trailing CR in the footer.
	support.eq(t, "CRLF is handled the same as LF",
		ui.diag_head("refused\r\nnoise", 44), "refused")
}

@(test)
diag_head_caps_content_and_marks_it :: proc(t: ^testing.T) {
	long, _ := strings.repeat("x", 90)
	big := ui.diag_head(long, 44)

	// The contract: at most `max` bytes of the REASON, then the mark. `…` is 3
	// bytes in UTF-8, so a 44-byte cap yields 47 bytes of string. The cap is on
	// the CONTENT; the mark is what tells you it was applied. Asserting the
	// total is what pins that reading — asserting only "len <= 44" would pass
	// against an implementation that silently dropped the mark.
	support.eq_i(t, "a 90-char reason is capped to max content bytes",
		len(big), 44 + len(ELL))
	check_has_suffix(t, "…and the cap is marked, not silent", big, ELL)
}

@(test)
diag_head_never_splits_a_two_byte_rune :: proc(t: ^testing.T) {
	prefix44, _ := strings.repeat("a", 43)
	tail20, _ := strings.repeat("b", 20)
	accented := fmt.tprintf("{}{}{}", prefix44, "é", tail20)
	cut := ui.diag_head(accented, 44)
	body := cut[:len(cut)-len(ELL)]

	// `é` is 2 bytes; a 43-byte prefix means the 44-byte cap lands INSIDE it
	// (…|c3|a9), so a naive slice would leave a dangling lead byte.
	support.eq_i(t, "the 44-byte cap backed off the middle of a 2-byte rune",
		len(body), 43)
	support.check(t, "…and the truncated part is valid UTF-8 on its own",
		utf8_valid_local(body), fmt.tprintf("body={}", body))
	check_has_suffix(t, "…and the cut is still marked as truncated", cut, ELL)
}

@(test)
diag_head_no_width_produces_broken_utf8 :: proc(t: ^testing.T) {
	// The property sweep. One bad width on one host's error message is enough
	// to corrupt the row, so "mostly fine" is not the standard.
	e30, _ := strings.repeat("é", 30)
	mixed := fmt.tprintf("ssh: could not read {} from the tunnel", e30)
	broke := 0
	first_bad := ""
	for w in 1 ..= 60 {
		r := ui.diag_head(mixed, w)
		rb := r[:len(r)-len(ELL)]
		if !utf8_valid_local(rb) {
			broke += 1
			if first_bad == "" { first_bad = fmt.tprintf("width {}", w) }
		}
	}
	support.check(t, "no width in 1..60 produces broken UTF-8", broke == 0,
		fmt.tprintf("{} of 60 widths broke{} — first at {}",
			broke, if_one(first_bad), first_bad))
}

@(test)
diag_head_empty_stays_empty :: proc(t: ^testing.T) {
	// The caller checks for "" before calling, and this pins that empty stays
	// empty rather than becoming a bare ellipsis in the footer.
	support.eq(t, "empty detail stays empty", ui.diag_head("", 44), "")
}

//-----------------------------------------------------------------------------
// local helpers
//-----------------------------------------------------------------------------

check_has_suffix :: proc(t: ^testing.T, name: string, hay: string, needle: string) {
	support.check(t, name, strings.has_suffix(hay, needle),
		fmt.tprintf("tail={}", hay))
}

if_one :: proc(s: string) -> string {
	if s == "" { return "" }
	return fmt.tprintf(" ({})", s)
}

// utf8_valid_local decodes rune by rune and reports whether every sequence is
// well formed.
//
// core:unicode/utf8 counts runes without complaining about broken ones, which
// is fine for layout and USELESS HERE — the whole point is to notice a dangling
// lead byte left behind by a truncation. A validator that tolerates the thing
// you are testing for validates nothing.
utf8_valid_local :: proc(s: string) -> bool {
	i := 0
	for i < len(s) {
		b := s[i]
		nb : int
		if b < 0x80 { nb = 1
		} else if b&0xE0 == 0xC0 { nb = 2
		} else if b&0xF0 == 0xE0 { nb = 3
		} else if b&0xF8 == 0xF0 { nb = 4
		} else { return false } // a bare continuation byte as a lead byte

		if i + nb > len(s) { return false }
		for k := 1; k < nb; k += 1 {
			if s[i+k] & 0xC0 != 0x80 { return false }
		}
		// Reject overlong encodings and surrogates: both decode to something the
		// standard forbids and both can be produced by a bad cut.
		if nb == 2 && (b & 0x1E) == 0 { return false }
		if nb == 3 {
			cp := (u32(b & 0x0F) << 12) | (u32(s[i+1] & 0x3F) << 6) | u32(s[i+2] & 0x3F)
			if cp < 0x800 { return false }
			if cp >= 0xD800 && cp <= 0xDFFF { return false }
		}
		if nb == 4 {
			cp := (u32(b & 0x07) << 18) | (u32(s[i+1] & 0x3F) << 12) |
				(u32(s[i+2] & 0x3F) << 6) | u32(s[i+3] & 0x3F)
			if cp < 0x10000 || cp > 0x10FFFF { return false }
		}
		i += nb
	}
	return true
}
