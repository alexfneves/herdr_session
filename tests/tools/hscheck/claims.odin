package hscheck

// claims.odin — which ledger GROUP belongs to which suite.
//
// WHY THIS FILE EXISTS
//
// The parity table has always carried a `files` column naming the groups a
// suite owns, but nothing ever READ it. Every count was taken over the whole
// log. That was invisible while each suite was its own binary, and became a
// correctness hole the moment one test binary containing diag_test,
// keyhints_test and every theme_* group got pointed at the single `state`
// row: the "state" number then contained other suites' assertions, so
// per-suite parity was fiction, and one suite's printf fallout failed
// another suite's gate run (brief item: rule 7 cross-suite false positive).
//
// A number that is not attributed to the thing it names cannot be compared
// to that thing's floor. Fixing attribution is not a refinement of the gate;
// it is the precondition for the floor meaning anything.
//
// GROUP NAMES COME FROM THE LEDGER, NOT FROM HERE. support derives a group
// from the basename of the file that made the assertion, so this only has to
// match what the ledger already says.

import "core:fmt"
import "core:mem"

// Ledger line shapes this understands:
//   [HS] PASS <group>.<assertion> — detail
//   [HS] FAIL <group>.<assertion> — detail
//   [HS] SKIP <group>.<assertion> — detail
//   HS_TALLY <group> pass=N fail=N skip=N
HS_PREFIX    :: "[HS] "
HS_TALLY_PFX :: "HS_TALLY "

// split_claims turns the `files` column into a list of patterns.
// Empty/whitespace entries are dropped so `a,,b` does not create a pattern
// that matches the empty group name.
split_claims :: proc(spec: string, alloc: mem.Allocator) -> [dynamic]string {
	out : [dynamic]string = {}
	start := 0
	for i := 0; i <= len(spec); i += 1 {
		if i == len(spec) || spec[i] == ',' {
			part := spec[start:i]
			part = trim_ws(part)
			if len(part) > 0 { append(&out, part) }
			start = i + 1
		}
	}
	return out
}

trim_ws :: proc(s: string) -> string {
	a := 0
	for a < len(s) && (s[a] == ' ' || s[a] == '\t') { a += 1 }
	b := len(s)
	for b > a && (s[b-1] == ' ' || s[b-1] == '\t') { b -= 1 }
	return s[a:b]
}

// group_claimed reports whether `group` matches any pattern in `claims`.
//
// A pattern is either an EXACT group name, or a prefix ending in `*`
// (`state_*` claims state_machine_test, state_offline_test, ...).
//
// The `*` is a TRAILING wildcard only. It is not a glob: `*foo` and `a*b*c`
// are deliberately unsupported, because a middle wildcard is how a claim
// starts matching groups nobody intended, and the whole point of this file
// is that a group belongs to exactly one accountable row.
group_claimed :: proc(claims: []string, group: string) -> bool {
	for c in claims {
		if len(c) == 0 { continue }
		if c[len(c)-1] == '*' {
			pre := c[:len(c)-1]
			if starts_with(group, pre) { return true }
		} else if c == group {
			return true
		}
	}
	return false
}

// group_of_line extracts the ledger group a log line belongs to, or "" when
// the line carries no group at all (raw child noise, a panic trace, an
// unrelated printf).
//
// Returning "" rather than guessing is deliberate. An unattributable line is
// reported as UNATTRIBUTED so a human sees it; silently folding it into the
// suite being evaluated is exactly how one suite's mess becomes another
// suite's number.
group_of_line :: proc(line: string) -> string {
	if starts_with(line, HS_TALLY_PFX) {
		rest := line[len(HS_TALLY_PFX):]
		// HS_TALLY <group> pass=...
		i := 0
		for i < len(rest) && rest[i] != ' ' && rest[i] != '\t' { i += 1 }
		return rest[:i]
	}
	if !starts_with(line, HS_PREFIX) { return "" }
	rest := line[len(HS_PREFIX):]
	// [HS] PASS <group>.<name> ...  ->  skip the verdict word, then read to '.'
	i := 0
	for i < len(rest) && rest[i] != ' ' { i += 1 } // PASS/FAIL/SKIP
	for i < len(rest) && rest[i] == ' ' { i += 1 }
	rest = rest[i:]
	dot := index_of_byte(rest, '.')
	if dot < 0 { return "" }
	return rest[:dot]
}

index_of_byte :: proc(s: string, b: u8) -> int {
	for i := 0; i < len(s); i += 1 { if s[i] == b { return i } }
	return -1
}

// ClaimSummary is what a suite's evaluation needs beyond the totals.
ClaimSummary :: struct {
	claimed_groups   : [dynamic]string, // groups folded into this suite
	unclaimed_groups : [dynamic]string, // seen in the log, owned by no row here
	claimed_lines    : int,            // [HS]/HS_TALLY lines attributed here
	unattributed     : int,            // lines with no group at all
}

// summarize_groups partitions the groups seen in a log against this row's
// claims. `all_groups` comes from the tallies AND from the [HS] lines, so a
// group that printed assertions but no tally still shows up.
summarize_groups :: proc(groups: [][]string, spec: string) -> ClaimSummary {
	claims := split_claims(spec, context.temp_allocator)
	s := ClaimSummary{}
	for gs in groups {
		for g in gs {
			if len(g) == 0 { continue }
			if group_claimed(claims[:], g) {
				append_if_absent(&s.claimed_groups, g)
			} else {
				append_if_absent(&s.unclaimed_groups, g)
			}
		}
	}
	return s
}

append_if_absent :: proc(v: ^[dynamic]string, x: string) {
	for e in v^ { if e == x { return } }
	append(v, x)
}

join_groups :: proc(v: []string) -> string {
	if len(v) == 0 { return "(none)" }
	out := ""
	for i := 0; i < len(v); i += 1 {
		if i > 0 { out = fmt.tprintf("{}, {}", out, v[i]) } else { out = v[i] }
	}
	return out
}
