package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_diag_trunc_test.odin — T10 port of `unit_diag_head` (:1046).
//
// P3-12: the footer's per-host diagnostic truncation. A `why` string is
// often a whole ssh trace and the footer has ONE row. The cut must take the
// first line, cap the width, and never slice a UTF-8 sequence in half — a
// dangling lead byte paints a replacement glyph exactly where the reason was.
//
// THIS OVERLAPS diag_test.odin ON PURPOSE.
//
// T2 re-homed `ui.diag_head` and asserted its contract from the new home.
// The parity note is explicit that the app-suite copy is NOT subtracted:
// "the new diag_test asserts the same PROPERTIES from the new home, ON TOP."
// Both are live; when app_cases is finally deleted in T17, the diag_test copy
// is what remains and the 444 stands either way.
//
// The 43-byte case is the interesting one: `é` is 2 bytes, so a 44-byte cap
// lands INSIDE it (…|c3|a9). A naive slice leaves half a character.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"

import ui "../../src/ui"
import support "../support"

AU_ELL :: "…"

au_diag :: proc(s: string, max: int) -> string {
	return ui.diag_head(s, max)
}

app_diag_trunc_battery_app_diag_trunc_first_line_only :: proc(c: ^AU_Ctx) {
	au_eq(c, "single short line passes through", au_diag("connection refused", 44),
		"connection refused")
	au_eq(c, "only the first line of a multi-line trace is used",
		au_diag("banner: ssh refused\nsecond line\nthird", 44), "banner: ssh refused")
	au_eq(c, "CRLF is handled the same as LF", au_diag("refused\r\nnoise", 44),
		"refused")
}
@(test)
app_diag_trunc_first_line_only :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_diag_trunc_battery_app_diag_trunc_first_line_only(&__c)
}

app_diag_trunc_battery_app_diag_trunc_cap_is_marked_not_silent :: proc(c: ^AU_Ctx) {
	long, _ := strings.repeat("x", 90)
	big := au_diag(long, 44)
	// The contract: at most `max` bytes of the REASON, then the mark. `…` is
	// 3 bytes in UTF-8, so a 44-byte cap yields 47 bytes of string — the cap
	// is on the CONTENT, and the mark is what tells you it was applied.
	au_check(c, "a 90-char reason is capped to max content bytes",
		len(big) == 44 + len(AU_ELL), fmt.tprintf("len={}", len(big)))
	au_check(c, "…and the cap is marked, not silent", strings.has_suffix(big, AU_ELL),
		fmt.tprintf("tail={}", big[44:]))
}
@(test)
app_diag_trunc_cap_is_marked_not_silent :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_diag_trunc_battery_app_diag_trunc_cap_is_marked_not_silent(&__c)
}

app_diag_trunc_battery_app_diag_trunc_never_splits_a_rune :: proc(c: ^AU_Ctx) {
	prefix44, _ := strings.repeat("a", 43)
	tail20, _ := strings.repeat("b", 20)
	accented := fmt.tprintf("{}{}{}", prefix44, "é", tail20)
	cut := au_diag(accented, 44)
	body := cut[:len(cut)-len(AU_ELL)]  // everything before the truncation mark
	au_check(c, "the 44-byte cap backed off the middle of a 2-byte rune",
		len(body) == 43, fmt.tprintf("body len={} (44 would split é)", len(body)))
	au_check(c, "…and the truncated part is valid UTF-8 on its own",
		au_utf8_valid(body), fmt.tprintf("body={}", body))
	au_check(c, "…and the cut is still marked as truncated",
		strings.has_suffix(cut, AU_ELL), fmt.tprintf("cut='{}'", cut))
}
@(test)
app_diag_trunc_never_splits_a_rune :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_diag_trunc_battery_app_diag_trunc_never_splits_a_rune(&__c)
}

app_diag_trunc_battery_app_diag_trunc_no_width_breaks_utf8 :: proc(c: ^AU_Ctx) {
	// A general sweep: for every cap across a mixed-ASCII/multi-byte reason,
	// the result must never be broken UTF-8. One bad width on a host's error
	// message is enough to corrupt the row.
	e30, _ := strings.repeat("é", 30)
	mixed := fmt.tprintf("ssh: could not read {} from the tunnel", e30)
	broke := 0
	for cap_w in 1 ..= 60 {
		r := au_diag(mixed, cap_w)
		rb := r[:len(r)-len(AU_ELL)]
		if !au_utf8_valid(rb) { broke += 1 }
	}
	au_check(c, "no width in 1..60 produces broken UTF-8", broke == 0,
		fmt.tprintf("{} widths broke across 60", broke))
}
@(test)
app_diag_trunc_no_width_breaks_utf8 :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_diag_trunc_battery_app_diag_trunc_no_width_breaks_utf8(&__c)
}

app_diag_trunc_battery_app_diag_trunc_empty_stays_empty :: proc(c: ^AU_Ctx) {
	// The caller checks for "" before calling; this pins that empty stays
	// empty rather than becoming a bare ellipsis in the footer.
	au_eq(c, "empty detail stays empty", au_diag("", 44), "")
}
@(test)
app_diag_trunc_empty_stays_empty :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_diag_trunc_battery_app_diag_trunc_empty_stays_empty(&__c)
}

