package ui

import "core:fmt"

// ─────────────────────────────────────────────────────────────────────────────
// text.odin — the footer's text-shaping helpers.
//
// Re-homed out of `package main` (was src/main.odin:960-975) in Task 2 so the
// truncation contract it implements can be unit-tested. While it lived in `main`
// it was unreachable from `tests/`, which meant the only honest option for a
// migrated test suite was to delete its seven assertions — the exact silent loss
// this migration exists to make impossible.
//
// Moved VERBATIM, and the name is kept on purpose: the value here is the
// location, not a rename. The live caller (main.odin `tui_host_line`) keeps
// working unchanged apart from the `ui.` prefix.
// ─────────────────────────────────────────────────────────────────────────────

// diag_head takes the first line of a multi-line diagnostic and caps it at
// `max` BYTES cut on a rune boundary, so a truncated accented character cannot
// leak a replacement glyph into the footer.
diag_head :: proc(s: string, max: int) -> string {
	end := len(s)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' || s[i] == '\r' { end = i; break }
	}
	head := s[:end]
	if len(head) <= max { return head }
	cut := max
	// 0x80..0xBF are UTF-8 continuation bytes: never cut just after one, and never
	// leave one at the end of the string.
	for cut > 0 && head[cut-1] & 0xc0 == 0x80 { cut -= 1 }
	for cut > 0 && cut < len(head) && head[cut] & 0xc0 == 0x80 { cut -= 1 }
	return fmt.tprintf("{}{}", head[:cut], "…")
}
