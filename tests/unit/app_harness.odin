package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_harness.odin — the T10 port of src/app_cases.odin's driver plumbing.
//
// The old driver was `case_app_unit` (src/app_cases.odin:69): sixteen `unit_*`
// procs called in sequence inside ONE binary case, sharing a package-level
// `any_failed` flag. Here each section becomes its own `@(test)` proc and its own
// ledger GROUP, so a shortfall is nameable per section instead of being a
// single number that went down for unknown reasons.
//
// THE CONTEXT IS BOTH LIVE AND RENDERING (the shape T6 established)
//
// `au_live` asserts into the ledger; `au_render` only writes text. The SAME
// section body runs in both modes, which is what makes the printf guard real:
// the guard scans the exact lines the suite generates rather than a summary of
// them. dev/app-smoke.sh ran `assert_formatted` over `$BIN app-unit`'s whole
// log; that is three counted assertions in the old total (app-unit, app-live,
// fetch-unit), and those three have to be ported too or the floor is short by
// three for a reason nobody can see.
//
// WHY `au_check` DOES NOT FORMAT THE VERDICT INTO THE ASSERTION
//
// support.check takes `cond` as a bool and `detail` as an OPAQUE string. The
// detail is never the format string (that is how `%!` reaches a passing line).
// Every section call site here therefore passes `fmt.tprintf(...)` results as
// values, exactly as the old driver did.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import "base:runtime"

import app "../../src/app"
import support "../support"

// AU_Ctx is the section's view of "who am I asserting for, and am I rendering".
AU_Ctx :: struct {
	t   : ^testing.T,               // nil in render mode — nothing reaches the ledger
	tr  : ^strings.Builder,         // the transcript sink (nil in live mode)
	loc : runtime.Source_Code_Location,
}

// au_live asserts into the ledger. MUST be called from inside the @(test) proc:
// `loc` becomes that file, which is what makes the tally land on the test file
// rather than on this harness.
au_live :: proc(t: ^testing.T, loc := #caller_location) -> AU_Ctx {
	return AU_Ctx{t = t, tr = nil, loc = loc}
}

// au_render renders only: no ledger, no tally. Used by the printf guard to get
// the text a battery actually produced.
au_render :: proc(tr: ^strings.Builder, loc := #caller_location) -> AU_Ctx {
	return AU_Ctx{t = nil, tr = tr, loc = loc}
}

// au_say is the old `say()`.
au_say :: proc(c: ^AU_Ctx, msg: string) {
	if c.t != nil {
		support.note(c.t, msg, loc = c.loc)
	}
	if c.tr != nil {
		strings.write_string(c.tr, msg)
		strings.write_byte(c.tr, '\n')
	}
}

// au_raw is the old `say_raw()`: the bytes of a capture, quoted and counted.
au_raw :: proc(c: ^AU_Ctx, label: string, data: []byte) {
	au_say(c, fmt.tprintf("  %s: %q ({} bytes)", label, string(data), len(data)))
}

// au_check is the old `check()`: one counted assertion, and the same line in
// the transcript so the printf guard sees the text the rule actually produced.
au_check :: proc(c: ^AU_Ctx, name: string, cond: bool, detail: string) {
	if c.t != nil {
		support.check(c.t, name, cond, detail, loc = c.loc)
	}
	if c.tr != nil {
		verdict := "FAIL"
		if cond { verdict = "PASS" }
		if len(detail) == 0 {
			strings.write_string(c.tr, fmt.tprintf("[{}] {}", verdict, name))
		} else {
			strings.write_string(c.tr, fmt.tprintf("[{}] {} — {}", verdict, name, detail))
		}
		strings.write_byte(c.tr, '\n')
	}
}

// The old local helpers (src/app_cases.odin:45-59), ported unchanged apart
// from taking the context. The exact quoting is kept because a one-character
// difference — a stray dash in a timestamp — is invisible otherwise.
au_eq :: proc(c: ^AU_Ctx, name: string, got, want: string) {
	au_check(c, name, got == want, fmt.tprintf("got %q want %q", got, want))
}

au_eq_i :: proc(c: ^AU_Ctx, name: string, got, want: i64) {
	au_check(c, name, got == want, fmt.tprintf("got {} want {}", got, want))
}

au_eq_int :: proc(c: ^AU_Ctx, name: string, got, want: int) {
	au_check(c, name, got == want, fmt.tprintf("got {} want {}", got, want))
}

au_ne_i :: proc(c: ^AU_Ctx, name: string, got, not_want: i64) {
	au_check(c, name, got != not_want, fmt.tprintf("got {} (must differ from {})", got, not_want))
}

// au_guard is the port of dev/app-smoke.sh's `assert_formatted`, but COUNTED.
//
// The old runner called assert_formatted once per driver log and added one to
// PASS_TOTAL for each. Three of those (app-unit, app-live, fetch-unit) are part
// of the 444 hermetic total. Running the battery in render mode produces the
// same text the old log held, so the guard scans the real thing.
//
// The gate ALSO sweeps `%!` from this suite's own lines (rule 7); this is what
// makes the guard an ASSERTION rather than only a filter, and it covers the
// evidence lines a section writes without asserting, which rule 7 never sees.
au_guard :: proc(t: ^testing.T, label: string,
                run: proc(c: ^AU_Ctx), loc := #caller_location) {
	b := strings.builder_make_len(0, context.temp_allocator)
	c := au_render(&b, loc)
	run(&c)
	text := strings.to_string(b)
	support.check(t, fmt.tprintf("{} transcript — no printf fallout", label),
		!support.has_fallout(text),
		fmt.tprintf("scanned {} bytes of rendered output", len(text)))
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared fixtures — the shape the product's own parser produces.
//
// ISC-A-3: no loopback/fixture host literal appears in src/, so the example
// devices here are inert `*.example` names and RFC 5737 documentation space.
// Mixed case is deliberate on one of them: any accidental normalisation of a
// device string shows up as a failed equality rather than passing quietly.
// ─────────────────────────────────────────────────────────────────────────────

AU_TS_A  :: "2026-10-17-20-30-45-123"
AU_TS_B  :: "2026-10-18-20-30-45-123"

// au_mk builds a Session the way `parse_session_list` does — ts derived from
// the NAME, never hand-set — so a test cannot accidentally assert on a row
// shape the product never produces.
au_mk :: proc(device: string, name: string, running: bool) -> app.Session {
	return app.Session{
		device  = device,
		label   = device,
		name    = name,
		running = running,
		ts      = app.ts_from_name(name),
	}
}

au_ts_text :: proc(name: string) -> string {
	return app.ts_display(app.ts_from_name(name))
}

au_names_of :: proc(sessions: []app.Session) -> string {
	out := make([dynamic]string, 0, len(sessions))
	for s in sessions { append(&out, s.name) }
	joined, _ := strings.join(out[:], ",")
	return joined
}

au_argv_text :: proc(argv: []string) -> string {
	joined, _ := strings.join(argv, " ")
	return joined
}

au_devices_of :: proc(rs: []app.Remote) -> string {
	parts := make([dynamic]string, 0, len(rs))
	for r in rs { append(&parts, r.device) }
	body, _ := strings.join(parts[:], " ")
	return body
}

au_contains_device :: proc(rs: []app.Remote, device: string) -> bool {
	for r in rs { if r.device == device { return true } }
	return false
}

au_to_bytes :: proc(s: string) -> []byte {
	return transmute([]byte)(s)
}

au_policy_text :: proc(p: app.Cleanup_Policy) -> string {
	#partial switch p {
	case .never:        return "never"
	case .only_created: return "only_created"
	case .always:       return "always"
	}
	return "?"
}

au_sort_strings :: proc(s: []string) {
	less :: proc(a, b: string) -> int {
		if a < b { return -1 }
		if a > b { return 1 }
		return 0
	}
	// core:sort is not imported by the ledger and this is the only place the
	// app suite needs it; keep the insertion sort so the helper set stays small
	// and the ordering is total over strings.
	for i := 1; i < len(s); i += 1 {
		j := i
		for j > 0 && less(s[j-1], s[j]) > 0 {
			tmp := s[j-1]; s[j-1] = s[j]; s[j] = tmp
			j -= 1
		}
	}
}

// au_parse_int is the old `parse_int` — digits only, no error path needed
// because the only caller has already matched the `ConnectTimeout=<digits>`
// prefix.
au_parse_int :: proc(s: string) -> i32 {
	n := 0
	for c in s { n = n * 10 + int(c - '0') }
	return i32(n)
}

// au_utf8_valid decodes a string rune by rune and reports whether every
// sequence is well formed. core:unicode/utf8 counts runes without complaining
// about broken ones, which is fine for layout and useless for THIS — the whole
// point is to notice a dangling lead byte left behind by a truncation.
//
// This is the old `utf8_valid` (src/app_cases.odin:1111) verbatim. The old
// one checked `r == utf8.RUNE_ERROR || n <= 0`; decode_rune_in_string returns
// (RUNE_ERROR, 1) for a malformed sequence, so both halves are kept rather
// than one of them being "simplified" away.
au_utf8_valid :: proc(s: string) -> bool {
	i := 0
	for i < len(s) {
		r, n := utf8.decode_rune_in_string(s[i:])
		if r == utf8.RUNE_ERROR || n <= 0 { return false }
		i += n
	}
	return true
}
