package support

// ─────────────────────────────────────────────────────────────────────────────
// fmtguard.odin — the `%!` scanner.
//
// This catches a bug class that bit the pre-migration harness TWICE: a mistyped
// printf verb produces a line that READS correctly but whose NUMBERS are wrong or
// absent. `[PASS] repaint in %!d(seconds)` still looks like a pass to a human
// skimming for FAIL, and it is the worst possible failure mode for a timing
// claim — the assertion passes, the evidence beside it is garbage.
//
// The rule is that NOTHING may go green while a `%!` sits in its log. The guard
// is deliberately independent of the ledger: it scans finished log files, so it
// still catches fallout written by a subprocess, a vendored library, or a stray
// fmt call that never went through support.check.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:os"
import "core:testing"

// MARKER is the fallout prefix. Built at run time from its bytes so this source
// file cannot match the scanner when someone greps a log for it, and so the
// constant is impossible to typo into a different string.
MARKER : []u8 = {'%', '!'}

// found_in reports the number of `%!` occurrences in s.
found_in :: proc(s: string) -> int {
	n := 0
	if len(s) < 2 { return 0 }
	for i := 0; i <= len(s) - 2; i += 1 {
		if s[i] == MARKER[0] {
			if s[i+1] == MARKER[1] { n += 1 }
		}
	}
	return n
}

// has_fallout is the yes/no form used by callers that only need to branch.
has_fallout :: proc(s: string) -> bool {
	return found_in(s) > 0
}

// FirstBad holds one offending line, so a failure can be shown rather than only
// counted. "3 malformed expansions" with nothing to look like is not debuggable.
FirstBad :: struct {
	line_no  : int,
	line     : string,
	occurs   : int,
}

// scan_lines returns every line of `s` that contains fallout, with the count of
// occurrences on that line. `line_no` is 1-based to match how editors and
// `grep -n` report the file.
scan_lines :: proc(s: string) -> [dynamic]FirstBad {
	out : [dynamic]FirstBad = {}
	n : int = 1
	start : int = 0
	for i := 0; i < len(s); i += 1 {
		if s[i] != '\n' { continue }
		line := s[start:i]
		c := found_in(line)
		if c > 0 { append(&out, FirstBad{line_no = n, line = line, occurs = c}) }
		n += 1
		start = i + 1
	}
	if start < len(s) {
		line := s[start:]
		c := found_in(line)
		if c > 0 { append(&out, FirstBad{line_no = n, line = line, occurs = c}) }
	}
	return out
}

// check_clean is the counted assertion: `label`'s text must contain no fallout.
// It goes through support.check, so retiring this guard would drop an assertion
// below its floor and the parity gate would go red. The guard cannot quietly
// disappear.
check_clean :: proc(t: ^testing.T, label: string, text: string) {
	bad := scan_lines(text)
	if len(bad) == 0 {
		check(t, fmt.tprintf("{} — no printf fallout", label), true, "0 matches")
		return
	}
	// Show the first offender rather than a bare count. Cap the excerpt so a
	// 10 KiB line cannot swallow the transcript.
	first := bad[0]
 excerpt := first.line
	if len(excerpt) > 120 { excerpt = excerpt[:120] }
	check(t, fmt.tprintf("{} — no printf fallout", label), false,
		fmt.tprintf("{} match(es) across {} line(s); first at line {}: {}",
			total_of(bad[:]), len(bad), first.line_no, excerpt))
}

total_of :: proc(bad: []FirstBad) -> int {
	n := 0
	for b in bad { n += b.occurs }
	return n
}

// ScanFile :: the result of scanning a finished log file.
ScanFile :: struct {
	path    : string,
	ok      : bool,
	total   : int,
	bad     : [dynamic]FirstBad,
	read_ok : bool,
}

// scan_file reads a log written by a suite (or a subprocess) and reports its
// fallout. Separated from check_clean so the GATE can scan many files without
// owning an allocator-per-file inside the ledger, and so a file that cannot be
// read is reported as such instead of as "clean".
scan_file :: proc(path: string) -> ScanFile {
	out : ScanFile = {}
	out.path = path
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		out.read_ok = false
		out.ok = false
		return out
	}
	out.read_ok = true
	text := string(data)
	out.bad = scan_lines(text)
	out.total = total_of(out.bad[:])
	out.ok = out.total == 0
	return out
}
