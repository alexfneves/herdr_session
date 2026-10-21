package hscheck

import "core:fmt"
import "core:strings"

import support "../../support"

// envhelper.odin — the environment each suite binary is spawned with.
//
// The gate never hands a suite the raw developer environment. Two reasons, both
// load-bearing:
//
//   * HERDR_* must not reach a child. `support.base_env` strips the whole
//     namespace, not an enumerated list, so a HERDR_* variable added later is
//     covered without anyone remembering to update this file.
//   * TERM is forced when unset, because a suite rendering differently under a
//     dumb terminal than the product does in a real one is testing nothing.
//
// On top of that the gate hands each suite its OWN JSON report path and its own
// suite name, so the ledger's HS_TALLY lines and the registered-count guard are
// attributed correctly no matter how many suites run.

harness_scenario :: proc(report_json: string, suite_name: string) -> []support.KV {
	out : [dynamic]support.KV = {}
	append(&out, support.KV{key = "ODIN_TEST_JSON_REPORT", val = report_json})
	append(&out, support.KV{key = "HS_SUITE", val = suite_name})
	return out[:]
}

harness_base_env :: proc(scenario: []support.KV) -> [dynamic]string {
	return support.base_env(scenario)
}
