package hscheck

// gate.odin — the parity gate's decision logic, kept PURE.
//
// The whole point of separating this from the runner is that every rule below is
// unit-testable without a test binary to point at. Each rule corresponds to one
// way a suite can look green while asserting nothing.
//
// THE RULES, and the failure each one closes:
//
//   1. The suite table must be NON-EMPTY.
//      A gate with nothing to check passes vacuously. This is the same defect
//      that makes `odin test` on a package with no `@(test)` exit 0, one level
//      up: `nix flake check` today passes because there are no checks.
//
//   2. Registered test count > 0.
//      core:testing scores 0 tests as a pass. The JSON report is the only place
//      this is visible.
//
//   3. A HS_TALLY line must exist for the suite.
//      Absence means the ledger never ran — a suite that finished "successfully"
//      without asserting anything.
//
//   4. pass >= floor.
//      THE GOVERNING RULE. Fewer assertions than the floor is a regression,
//      said out loud.
//
//   5. fail == 0.
//   6. skip == 0 unless the suite declared itself optional.
//   7. no `%!` printf fallout anywhere in the suite's logs.
//   8. totals() == sum_groups() — the ledger must agree with itself.

import "core:fmt"
import "core:strings"

import support "../../support"

Tier :: enum {
	hermetic, // no network, no ssh, no remote fixture: runs in the nix sandbox
	fixture,  // needs the armed remote fixture
}

tier_parse :: proc(s: string) -> (Tier, bool) {
	if s == "hermetic" { return .hermetic, true }
	if s == "fixture" { return .fixture, true }
	return .hermetic, false
}

tier_label :: proc(t: Tier) -> string {
	if t == .fixture { return "fixture" }
	return "hermetic"
}

// Suite :: one row of the gate's run-time table.
Suite :: struct {
	name       : string,
	binary     : string,
	tier       : Tier,
	floor      : int,
	allow_skip : bool,
	notes      : string,
	// report_json is where this suite's core:testing JSON report lives.
	//
	// TRAP FOUND IN T1: ODIN_TEST_JSON_REPORT is a `#config` (runner.odin:66),
	// i.e. a COMPILE-TIME define, NOT a runtime env var. Setting it in the
	// child's environment does nothing: the binary was already built with `"`
	// baked in and writes no report at all. So the report path is a property of
	// the BUILD, not the run: each suite is built with
	//   -define:ODIN_TEST_JSON_REPORT=<path>
	// (T15 bakes it in per suite) and the gate is TOLD where to look. A suite
	// built without it simply has no report, and Rule 2 says so rather than
	// inventing a registered count.
	report_json : string,
}

// Verdict :: the result of checking one suite. `problems` collects EVERY rule
// the suite broke rather than the first one, because a suite that fails three
// ways is a different diagnosis than one that fails one.
Verdict :: struct {
	suite    : string,
	pass     : int,
	fail     : int,
	skip     : int,
	registered : int,
	problems : [dynamic]string,
	ran      : bool,
	exit     : int,
}

verdict_ok :: proc(v: ^Verdict) -> bool {
	return len(v.problems) == 0
}

add_problem :: proc(v: ^Verdict, msg: string) {
	append(&v.problems, msg)
}

// ─────────────────────────────────────────────────────────────────────────────
// Rule 1 — the table itself
// ─────────────────────────────────────────────────────────────────────────────

// check_table_is_non_empty is the gate asserting ITS OWN usefulness. Returning a
// problem rather than exiting means the caller prints it in the same report
// format as every other failure, so it cannot be mistaken for a pass and cannot
// be skipped by a wrapper that ignores exit codes.
check_table_is_non_empty :: proc(suites: []Suite) -> (bool, string) {
	if len(suites) > 0 { return true, "" }
	return false,
		"THE GATE HAS AN EMPTY SUITE TABLE — there is nothing to check, so " +
		"'green' here would mean nothing. Every suite is either unported or was " +
		"filtered out by --tier/--parity. A vacuous pass is worse than no gate: " +
		"it is a pass nobody can tell apart from coverage."
}

// ─────────────────────────────────────────────────────────────────────────────
// Tally parsing
// ─────────────────────────────────────────────────────────────────────────────

TallyRow :: struct {
	group : string,
	pass  : int,
	fail  : int,
	skip  : int,
}

// parse_tallies pulls every HS_TALLY line out of a log.
//
// The line carries the group's CUMULATIVE counters, so callers take the MAXIMUM
// per field rather than the last row. Under `-define:ODIN_TEST_THREADS=n` the
// cleanup windows of two tests overlap, and "last line wins" would then read a
// mid-run snapshot as a final total. Max of a monotonic counter cannot be wrong.
parse_tallies :: proc(text: string) -> [dynamic]TallyRow {
	out : [dynamic]TallyRow = {}
	ok : bool = false
	r : TallyRow = {}
	for line in split_lines(text) {
		if starts_with(line, "HS_TALLY ") {
			r, ok = parse_tally_line(line)
			if ok { append(&out, r) }
		}
		// Deleted at the END of the body, not via `defer`. Odin runs deferred
		// calls at procedure EXIT, and these rows outlive this procedure: with a
		// defer every TallyRow.group was a slice of freed memory by the time
		// max_by_group read it. The gate then folded 8 garbage groups at 44
		// each into the total (8*44 + 54 = 406) while still exiting "green" —
		// a silent corruption of exactly the kind this whole gate exists to
		// prevent, inside the gate itself.
		delete(line)
	}
	return out
}

// max_by_group folds the rows down to the maximum counters seen per group.
max_by_group :: proc(rows: []TallyRow) -> [dynamic]TallyRow {
	out : [dynamic]TallyRow = {}
	for r in rows {
		found := false
		for i in 0 ..< len(out) {
			m := &out[i]
			if m.group == r.group {
				if r.pass > m.pass { m.pass = r.pass }
				if r.fail > m.fail { m.fail = r.fail }
				if r.skip > m.skip { m.skip = r.skip }
				found = true
				break
			}
		}
		if !found { append(&out, r) }
	}
	return out
}

fold_total :: proc(rows: []TallyRow) -> (int, int, int) {
	p := 0
	f := 0
	s := 0
	for r in rows {
		p += r.pass
		f += r.fail
		s += r.skip
	}
	return p, f, s
}

// ─────────────────────────────────────────────────────────────────────────────
// The per-suite decision
// ─────────────────────────────────────────────────────────────────────────────

// SuiteEvidence :: everything the gate learned about one suite from its run.
SuiteEvidence :: struct {
	log_text     : string,
	registered : int,
	have_reg   : bool,
	run_ok     : bool,
	exit       : int,
}

evaluate_suite :: proc(s: Suite, ev: SuiteEvidence) -> Verdict {
	v : Verdict = {}
	v.suite = s.name
	v.exit = ev.exit
	v.registered = ev.registered
	v.ran = ev.run_ok

	// Rule 2 — registered count.
	if !ev.have_reg {
		add_problem(&v, "no JSON test report was produced, so the REGISTERED test " +
			"count is unknown; core:testing scores 0 tests as a pass and this gate " +
			"refuses to guess")
	} else if ev.registered == 0 {
		add_problem(&v, "0 tests REGISTERED — the binary built, but nothing was " +
			"registered with core:testing. core:testing exits 0 for this. This is " +
			"the exact hazard the plan names: a mis-filtered suite is indistinguishable " +
			"from a passing one unless this is guarded")
	}

	// Rule 3 — a tally must exist.
	rows := parse_tallies(ev.log_text)
	tallies := max_by_group(rows[:])
	p, f, sn := fold_total(tallies[:])
	v.pass = p
	v.fail = f
	v.skip = sn

	if len(tallies) == 0 {
		add_problem(&v, "NO HS_TALLY LINE in the log — the ledger never recorded an " +
			"assertion. A suite that ran to completion without emitting one asserted " +
			"nothing; absence is treated as failure, not as pass")
		return v
	}

	// Rule 5 — no failures.
	if f > 0 {
		add_problem(&v, fmt.tprintf("{} assertion(s) FAILED", f))
	}

	// Rule 6 — skips are red unless declared optional.
	if sn > 0 && !s.allow_skip {
		add_problem(&v, fmt.tprintf(
			"{} skipped assertion(s) and the suite is NOT declared optional. " +
			"Skipping is not passing: --allow-skip is the only way to declare them away, " +
			"and it must be a decision, not a default", sn))
	}

	// Rule 4 — THE GOVERNING RULE.
	if p < s.floor {
		add_problem(&v, fmt.tprintf(
			"REGRESSION: {} assertions passed, floor is {} — {} assertion(s) short of " +
			"parity. Fewer assertions after the move is a regression, never a green suite",
			p, s.floor, s.floor - p))
	}

	// Rule 7 — printf fallout.
	if support.has_fallout(ev.log_text) {
		add_problem(&v, fmt.tprintf(
			"{} printf format-fallout marker(s) in the log — a mistyped verb produces a " +
			"plausible line whose NUMBERS are wrong, which is the worst possible failure " +
			"mode for a timing claim", support.found_in(ev.log_text)))
	}

	return v
}

// ─────────────────────────────────────────────────────────────────────────────
// Small string helpers (kept local so the gate has no allocator surprises)
// ─────────────────────────────────────────────────────────────────────────────

starts_with :: proc(s, pre: string) -> bool {
	if len(s) < len(pre) { return false }
	for i := 0; i < len(pre); i += 1 {
		if s[i] != pre[i] { return false }
	}
	return true
}

split_lines :: proc(text: string) -> [dynamic]string {
	out : [dynamic]string = {}
	start : int = 0
	for i := 0; i < len(text); i += 1 {
		if text[i] == '\n' {
			append(&out, strings.clone(text[start:i], context.allocator))
			start = i + 1
		}
	}
	if start < len(text) {
		append(&out, strings.clone(text[start:], context.allocator))
	}
	return out
}

// parse_tally_line parses
//     HS_TALLY <group> pass=N fail=N skip=N
// and refuses anything that does not have all four fields. A half-parsed tally
// defaulting to 0 would silently under-report, so `ok` is false rather than a
// best guess.
parse_tally_line :: proc(line: string) -> (TallyRow, bool) {
	rest := line[len("HS_TALLY "):]
	sp := index_of_char(rest, ' ')
	if sp <= 0 { return TallyRow{}, false }
	r : TallyRow = {}
	// CLONE, not a slice: see parse_tallies on why the row must own its bytes.
	r.group = strings.clone(rest[:sp], context.allocator)
	fields := split_space(rest[sp+1:])
	got_p := false
	got_f := false
	got_s := false
	for f in fields {
		if starts_with(f, "pass=") { r.pass = to_int(f[len("pass="):]); got_p = true
		} else if starts_with(f, "fail=") { r.fail = to_int(f[len("fail="):]); got_f = true
		} else if starts_with(f, "skip=") { r.skip = to_int(f[len("skip="):]); got_s = true }
	}
	if !got_p || !got_f || !got_s { return TallyRow{}, false }
	return r, true
}

split_space :: proc(s: string) -> [dynamic]string {
	out : [dynamic]string = {}
	i := 0
	for i < len(s) {
		if s[i] == ' ' { i += 1; continue }
		j := i
		for j < len(s) { if s[j] == ' ' { break }; j += 1 }
		append(&out, strings.clone(s[i:j], context.allocator))
		i = j
	}
	return out
}
