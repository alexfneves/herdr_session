package hscheck

import "core:encoding/json"

// report.odin — reads core:testing's JSON report.
//
// The report is the ONLY place the registered-test count is visible, and
// registered count > 0 is the guard that stops `odin test`'s "no tests, exit 0"
// from looking like coverage. It reports TESTS, never assertions — which is
// precisely why HS_TALLY has to exist alongside it.
//
// Shape (Odin dev-2026-10, -define:ODIN_TEST_JSON_REPORT=<path>):
//
//   { "total": n, "success": n, "duration": "...",
//     "packages": { "<pkg>": [ {"name": "...", "success": true}, ... ] } }

Json_Report :: struct {
	total    : int,
	success  : int,
	duration : f64,
	packages : map[string][]Json_Test,
}

Json_Test :: struct {
	name    : string,
	success : bool,
}

// read_report returns the registered count and whether the report was readable
// and parseable. `have` false means "we do not know", which the gate treats as
// its own failure rather than defaulting to a number.
read_report :: proc(path: string) -> (total: int, success: int, have: bool) {
	data, err := os_read_file(path)
	if err != nil { return 0, 0, false }
	defer delete(data)

	rep := Json_Report{}
	if uerr := json.unmarshal(data, &rep); uerr != nil {
		return 0, 0, false
	}
	return rep.total, rep.success, true
}
