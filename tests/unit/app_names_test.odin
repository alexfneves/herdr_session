package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_names_test.odin — T10 port of `unit_names` (src/app_cases.odin:154).
//
// The charset rule, the `default` / `.` / `..` refusals (D12), and the
// NAME_MAX_LEN boundary. 15 assertions: 13 table rows + 2 length edges.
//
// WHY THE TABLE CARRIES A `why` COLUMN THAT IS NEVER ASSERTED
//
// It is evidence, not a check. The assertion is `got.ok == want`; the `why`
// says, on the passing line, WHICH property that row was exercising. When a
// row flips, the reader learns whether we started accepting a colon or
// stopped accepting a cycle name — a bare `expected false got true` cannot
// tell those apart and sends you back to the source for each of 13 rows.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

AU_Name_Case :: struct {
	name: string,
	want : bool,
	why  : string,
}

AU_NAME_CASES : []AU_Name_Case = {
	{"2026-10-18-20-30-45-123", true,  "a bare herdr-cycle name"},
	{"api-2026-10-18-20-30-45-123", true, "a named new session"},
	{"mydb", true, "plain name"},
	{"a_b.c-d9", true, "all legal punctuation"},
	{"", false, "empty is refused"},
	{"default", false, "D12: never default"},
	{".", false, "path component"},
	{"..", false, "path component"},
	{"bad name", false, "space"},
	{"bad:name", false, "colon — NOT in the charset"},
	{"bad/name", false, "slash"},
	{"bad$name", false, "dollar"},
	{"bad\u00e9name", false, "non-ASCII"},
}

@(test)
app_names_charset_table :: proc(t: ^testing.T) {
	c := au_live(t)
	for cs in AU_NAME_CASES {
		name, want, why := cs.name, cs.want, cs.why
		got := app.validate_name(name)
		want_reason := ""
		if !want { want_reason = got.reason }
		au_check(&c, fmt.tprintf("name '{}' -> ok={}", name, got.ok), got.ok == want,
			fmt.tprintf("{} ({}); reason={}", want, why, want_reason))
	}
}

@(test)
app_names_length_boundary :: proc(t: ^testing.T) {
	c := au_live(t)
	edge_ok, _ := strings.repeat("a", app.NAME_MAX_LEN)
	edge_big, _ := strings.repeat("a", app.NAME_MAX_LEN + 1)
	au_check(&c, "name of exactly NAME_MAX_LEN is accepted", app.name_is_ok(edge_ok),
		fmt.tprintf("len={}", len(edge_ok)))
	au_check(&c, "name of NAME_MAX_LEN+1 is refused", !app.name_is_ok(edge_big),
		fmt.tprintf("len={}", len(edge_big)))
}
