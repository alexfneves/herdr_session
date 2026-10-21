package hscheck

import "core:fmt"
import "core:strings"

import support "../../support"

// table.odin — CLI parsing, the parity-table reader, and the ledger self-check.
//
//   hs_check --parity=tests/parity.tsv --suite=NAME=/path/to/test-bin [...]
//            [--tier=hermetic|fixture|all] [--report-dir=DIR] [--allow-skip]
//
// The FLOORS come from tests/parity.tsv (the human-reviewed record of what each
// suite asserted before the move). The BINARY PATHS come from the command line,
// because the gate must be able to point at any artifact — a locally built one,
// a nix-store one, or a fixture. Separating the two is what lets the same gate
// prove "empty table FAILS" and "1-test fixture PASSES" without recompiling.
//
// Exit status: 0 only if every rule holds for every suite in the table. Anything
// else — including an empty table — is non-zero.

MAIN_USAGE :: `usage: hs_check --parity=PATH [--suite=NAME=BINARY]... [--tier=hermetic|fixture|all]
               [--report-dir=DIR] [--allow-skip] [--help]`

Cmd_Args :: struct {
	parity     : string,
	suite_args : [dynamic]string,
	tier       : string,
	report_dir : string,
	allow_skip : bool,
	help       : bool,
	unknown    : [dynamic]string,
	// Per-suite wall-clock limit. A gate with no bound on its child is a gate
	// that can hang CI indefinitely; the timeout is not a convenience, it is
	// what makes "stuck" distinguishable from "working".
	timeout_ms : i64,
}

// DEFAULT_TIMEOUT_MS is deliberately generous (10 min) rather than tight. The
// point is not to police fast suites, it is to guarantee termination. A limit
// tight enough to catch a slow suite is a limit that fails a suite under load
// for reasons unrelated to correctness -- and the dead-host tests already run
// close to 6.5 s each. Generous but BOUNDED beats exact but sometimes wrong.
DEFAULT_TIMEOUT_MS :: 600_000

parse_args :: proc(args: []string) -> Cmd_Args {
	a : Cmd_Args = {}
	a.parity = "tests/parity.tsv"
	a.tier = "all"
	a.report_dir = "hs-reports"
	a.timeout_ms = DEFAULT_TIMEOUT_MS
	for x in args {
		if x == "--help" || x == "-h" { a.help = true
		} else if starts_with(x, "--parity=") { a.parity = x[len("--parity="):]
		} else if starts_with(x, "--suite=") { append(&a.suite_args, x[len("--suite="):])
		} else if starts_with(x, "--tier=") { a.tier = x[len("--tier="):]
		} else if starts_with(x, "--report-dir=") { a.report_dir = x[len("--report-dir="):]
		} else if x == "--allow-skip" { a.allow_skip = true
		} else if starts_with(x, "--timeout=") { a.timeout_ms = parse_ms(x[len("--timeout="):])
		} else { append(&a.unknown, x) }
	}
	return a
}

// Parity_Row :: one row of tests/parity.tsv.
//
// The file is the reviewed record, and its column order is the plan's:
//
//   suite  tier  floor_before  pass_after  fail_after  skipped  files  task  notes
//
// `files` is the list of ledger GROUP names (test-file basenames) the suite
// claims. A group that no row claims is reported UNACCOUNTED rather than being
// folded into some other suite's total — that is how a new test file becomes
// visible to the gate instead of invisible inside a passing number.
Parity_Row :: struct {
	suite      : string,
	tier       : string,
	floor      : int,
	pass_after : int,
	fail_after : int,
	skipped    : int,
	files      : string,
	task       : string,
	notes      : string,
}

load_parity :: proc(path: string) -> (rows: [dynamic]Parity_Row, ok: bool, why: string) {
	data, err := os_read_file(path)
	if err != nil {
		return rows, false, fmt.tprintf("cannot read the parity table at {}: {}", path, err)
	}
	defer delete(data)
	text := string(data)
	for line in split_lines(text) {
		defer delete(line)
		t := str_lstrip(line)
		if len(t) == 0 { continue }
		if t[0] == '#' { continue }
		cols := split_tab(t)
		if len(cols) < 3 {
			append(&rows, Parity_Row{suite = t, notes = "MALFORMED ROW (fewer than 3 tab-separated columns)"})
			continue
		}
		r : Parity_Row = {}
		r.suite = cols[0]
		r.tier = cols[1]
		r.floor = to_int(cols[2])
		if len(cols) > 3 { r.pass_after = to_int(cols[3]) }
		if len(cols) > 4 { r.fail_after = to_int(cols[4]) }
		if len(cols) > 5 { r.skipped = to_int(cols[5]) }
		if len(cols) > 6 { r.files = cols[6] }
		if len(cols) > 7 { r.task = cols[7] }
		if len(cols) > 8 { r.notes = cols[8] }
		append(&rows, r)
	}
	return rows, true, ""
}

// resolve_suites pairs the command line's binary paths with the parity table's
// floors. A suite named on the command line with NO parity row is a problem we
// report rather than silently running with floor 0 — floor 0 means "anything
// passes", which is the gate turning itself off.
resolve_suites :: proc(
	suite_args: []string,
	rows: []Parity_Row,
	tier: string,
	allow_skip: bool,
) -> (suites: [dynamic]Suite, problems: [dynamic]string) {
	for sa in suite_args[:] {
		eq := index_of_char(sa, '=')
		if eq <= 0 {
			append(&problems, fmt.tprintf(
				"--suite={} is not NAME=BINARY — refusing to guess which binary it means", sa))
			continue
		}
		name := sa[:eq]
		rest := sa[eq+1:]
		// NAME=BINARY or NAME=BINARY:REPORT_JSON. The report path is optional
		// because the suite may have been built without the compile-time define
		// — in which case there is nothing to read and Rule 2 says so.
		bin := rest
		report := ""
		c := index_of_char(rest, ':')
		if c > 0 {
			bin = rest[:c]
			report = rest[c+1:]
		}

		row : ^Parity_Row = nil
		for i in 0 ..< len(rows) {
			if rows[i].suite == name { row = &rows[i]; break }
		}
		if row == nil {
			append(&problems, fmt.tprintf(
				"suite '{}' has no row in the parity table — running it with floor 0 would mean "+
				"'any number of assertions passes', which is the gate disabled. Add the row with a "+
				"measured floor_before", name))
			continue
		}

		tier_of_suite := row.tier
		if tier != "all" && tier_of_suite != tier { continue }

		// An unrecognised tier used to fall through to `.hermetic` silently.
		// With tiering now load-bearing for T15 that is not a harmless default:
		// a typo, or a genuinely new tier the gate has not been taught, would
		// file real pty/fixture tests under "hermetic" and they would then run
		// in a sandbox that cannot support them -- or be silently excluded from
		// the tier that should have run them. Either way the tier column stops
		// being trustworthy and nobody is told. Refuse the row instead.
		tier_val, tier_ok := tier_parse(tier_of_suite)
		if !tier_ok {
			append(&problems, fmt.tprintf(
				"suite '{}' has tier '{}' which this gate does not know (known: hermetic, " +
				"fixture, pty). Refusing to guess: defaulting an unknown tier to hermetic " +
				"would file tests under a tier they do not belong to, silently, which is " +
				"worse than an error", name, tier_of_suite))
			continue
		}

		append(&suites, Suite{
			name = name,
			binary = bin,
			tier = tier_val,
			floor = row.floor,
			allow_skip = allow_skip,
			notes = row.notes,
			report_json = report,
			claims = row.files,
		})
	}
	return suites, problems
}

tier_from_name :: proc(s: string) -> Tier {
	t, ok := tier_parse(s)
	if !ok { return .hermetic }
	return t
}

str_lstrip :: proc(s: string) -> string {
	i := 0
	for i < len(s) {
		if s[i] != ' ' && s[i] != '\t' { break }
		i += 1
	}
	return s[i:]
}

index_of_char :: proc(s: string, ch: u8) -> int {
	for i := 0; i < len(s); i += 1 {
		if s[i] == ch { return i }
	}
	return -1
}

split_tab :: proc(s: string) -> [dynamic]string {
	out : [dynamic]string = {}
	start : int = 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\t' {
			append(&out, strings.clone(s[start:i], context.allocator))
			start = i + 1
		}
	}
	append(&out, strings.clone(s[start:], context.allocator))
	return out
}

to_int :: proc(s: string) -> int {
	t := strings.trim_space(s)
	if len(t) == 0 { return 0 }
	neg := false
	i := 0
	if t[0] == '-' { neg = true; i = 1 }
	n := 0
	digits := 0
	for ; i < len(t); i += 1 {
		d := u8(t[i]) - u8('0')
		if d > 9 { break }
		n = n * 10 + int(d)
		digits += 1
	}
	if digits == 0 { return 0 }
	if neg { return -n }
	return n
}

// Ledger_Selfcheck :: the gate's check on the support ledger itself.
ledger_selfcheck :: proc() -> [dynamic]string {
	out : [dynamic]string = {}
	a := support.totals()
	b := support.sum_groups()
	if a.pass != b.pass || a.fail != b.fail || a.skip != b.skip {
		append(&out, fmt.tprintf(
			"the ledger disagrees with itself: totals()={{pass={},fail={},skip={}}} but "+
			"sum_groups()={{pass={},fail={},skip={}}}. One of the two is wrong and neither "+
			"can be trusted for parity", a.pass, a.fail, a.skip, b.pass, b.fail, b.skip))
	}
	return out
}

// parse_ms accepts "90s", "1500ms", or a bare number of milliseconds.
// A non-positive or unparseable value falls back to the default rather than to
// zero: a typo in a timeout must not turn into "kill everything instantly",
// which would look like a suite that fails for a reason it does not have.
parse_ms :: proc(s: string) -> i64 {
	if len(s) == 0 { return DEFAULT_TIMEOUT_MS }
	mult : i64 = 1
	body := s
	if len(s) > 2 && s[len(s)-2:] == "ms" { mult = 1; body = s[:len(s)-2]
	} else if len(s) > 1 && s[len(s)-1] == 's' { mult = 1000; body = s[:len(s)-1] }
	n : i64 = 0
	digits := 0
	for i := 0; i < len(body); i += 1 {
		if body[i] < '0' || body[i] > '9' { return DEFAULT_TIMEOUT_MS }
		n = n * 10 + i64(body[i] - '0')
		digits += 1
	}
	if digits == 0 { return DEFAULT_TIMEOUT_MS }
	return n * mult
}
