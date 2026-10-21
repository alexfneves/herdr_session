package main

import "core:fmt"
import "core:os"

import hc ".."

// hs_check — the parity gate's entry point.
//
//   hs_check --parity=tests/parity.tsv --suite=NAME=/path/to/test-bin [...]
//            [--tier=hermetic|fixture|all] [--report-dir=DIR] [--allow-skip]
//
// Exits 0 ONLY when every rule holds for every suite in the table. An empty
// table is a failure, not a pass — that is the point.

main :: proc() {
	args := os.args[1:]
	a := hc.parse_args(args)

	if a.help {
		fmt.println(hc.MAIN_USAGE)
		os.exit(2)
	}

	fmt.println("── hs_check: assertion-count parity gate ──")
	fmt.printfln("parity table : {}", a.parity)
	fmt.printfln("tier filter  : {}", a.tier)
	fmt.printfln("allow-skip   : {}", a.allow_skip)

	if len(a.unknown) > 0 {
		for u in a.unknown {
			fmt.printfln("  ignoring unrecognised argument: {}", u)
		}
	}

	rows, pok, why := hc.load_parity(a.parity)
	if !pok {
		fmt.printfln("FAIL — {}", why)
		os.exit(1)
	}
	fmt.printfln("parity rows loaded: {}", len(rows))

	suites, rprobs := hc.resolve_suites(a.suite_args[:], rows[:], a.tier, a.allow_skip)
	for p in rprobs {
		fmt.printfln("  [FAIL] {}", p)
	}

	// ── RULE 1: the gate must have something to check ─────────────────────
	ok_table, why_empty := hc.check_table_is_non_empty(suites[:])
	if !ok_table {
		fmt.printfln("\nFAIL — {}", why_empty)
		os.exit(1)
	}

	// Report dir: each suite gets its OWN files. No concatenation, ever.
	// EEXIST is fine - build_fixture and the gate may both create it. Anything
	// else (EACCES, ENOSPC) is a real failure and must stop the run rather than
	// leaving the gate writing reports into a directory it does not own.
	mk_err := os.make_directory_all(a.report_dir)
	if mk_err != nil { if mk_err != os.General_Error.Exist {
		fmt.printfln("FAIL — cannot create the report directory {}: {}", a.report_dir, mk_err)
		os.exit(1)
	} }

	fmt.printfln("\n== suites in the run: {} ==\n", len(suites))

	total_pass := 0
	total_fail := 0
	total_skip := 0
	red := 0

	for s in suites {
		out_log := fmt.tprintf("{}/{}.out.log", a.report_dir, s.name)
		err_log := fmt.tprintf("{}/{}.err.log", a.report_dir, s.name)
		report_json := fmt.tprintf("{}/{}.json", a.report_dir, s.name)

		env := build_suite_env(&a, s, report_json)
		exit := hc.spawn_and_capture(s.binary, out_log, err_log, env)

		out_text := read_text(out_log)
		err_text := read_text(err_log)
		combined := fmt.tprintf("{}{}", out_text, err_text)

		total, succ, have := hc.read_report(report_json)

		ev := hc.SuiteEvidence{
			log_text = combined,
			registered = total,
			have_reg = have,
			run_ok = exit >= 0,
			exit = int(exit),
		}
		v := hc.evaluate_suite(s, ev)
		if exit != 0 && hc.verdict_ok(&v) {
			// A non-zero exit with no rule tripped is its own problem: the suite
			// died somewhere the ledger did not record.
			hc.add_problem(&v, fmt.tprintf("suite binary exited {} — a non-zero exit with no "+
				"counted failure means the harness broke, not that an assertion failed", exit))
		}
		_ = succ

		fmt.printfln("-- {} (tier={}, floor={})", s.name, s.tier, s.floor)
		fmt.printfln("   registered={} pass={} fail={} skip={} exit={}",
			v.registered, v.pass, v.fail, v.skip, v.exit)

		if len(v.problems) == 0 {
			fmt.printfln("   [PASS] {} — {} assertions against a floor of {}", s.name, v.pass, s.floor)
		} else {
			for p in v.problems {
				fmt.printfln("   [FAIL] {} — {}", s.name, p)
			}
			red += 1
		}

		total_pass += v.pass
		total_fail += v.fail
		total_skip += v.skip
	}

	// The ledger's own consistency, asserted at the end of every gate run.
	for p in hc.ledger_selfcheck() {
		fmt.printfln("   [FAIL] ledger self-check — {}", p)
		red += 1
	}

	fmt.println("\n── summary ──")
	fmt.printfln("TOTAL: {} pass / {} fail / {} skip; {} suite(s) red",
		total_pass, total_fail, total_skip, red)

	if red > 0 {
		fmt.println("RESULT: FAIL")
		os.exit(1)
	}
	fmt.println("RESULT: PASS")
	os.exit(0)
}

read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil { return "" }
	return string(data)
}

build_suite_env :: proc(a: ^hc.Cmd_Args, s: hc.Suite, report_json: string) -> []string {
	// The scenario starts from the harness base env (HERDR_* stripped, TERM
	// forced) and adds the report path + the suite name so the ledger's tally
	// lines carry it.
	scenario := hc.harness_scenario(report_json, s.name)
	env := hc.harness_base_env(scenario)
	out : [dynamic]string = {}
	for e in env { append(&out, e) }
	return out[:]
}
