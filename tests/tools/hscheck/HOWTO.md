# hs_check — the sanctioned invocation

Read this before improvising flags. Every report-path confusion we have had came
from a plausible invocation that silently produced `registered=0`.

## TL;DR — copy this

```sh
odin build ./tests/tools/hscheck/cmd -out:/tmp/hs_check

# ONE build per suite binary, with the report path baked IN at build time
odin build ./tests/pty -build-mode:test \
     -define:ODIN_TEST_JSON_REPORT=/tmp/reports/pty.json \
     -out:/tmp/bin_pty

/tmp/hs_check \
  --parity=tests/parity.tsv \
  --tier=pty \
  --report-dir=/tmp/reports/run \
  --suite=pty_width =/tmp/bin_pty:/tmp/reports/pty.json \
  --suite=pty_ffi   =/tmp/bin_pty:/tmp/reports/pty.json \
  --suite=pty_screen=/tmp/bin_pty:/tmp/reports/pty.json \
  --suite=pty_driver=/tmp/bin_pty:/tmp/reports/pty.json
```

(spaces above are for alignment only — no spaces around `=` or `:` in real use)

Verified output:

```
-- pty_width   (tier=pty, floor=67)  registered=38 pass=67  [PASS]
-- pty_ffi     (tier=pty, floor=27)  registered=38 pass=27  [PASS]
-- pty_screen  (tier=pty, floor=73)  registered=38 pass=73  [PASS]
-- pty_driver  (tier=pty, floor=51)  registered=38 pass=51  [PASS]
TOTAL: 218 pass / 0 fail / 0 skip; 0 suite(s) red
RESULT: PASS
```

## The `--suite=` spec, spelled out

```
--suite=<ROW_NAME>=<BINARY>:<REPORT_JSON>
```

* `<ROW_NAME>` must be a `suite` value that EXISTS in `tests/parity.tsv`.
  No row → the gate refuses to run it (it will not default to floor 0, which
  would mean "any number passes").
* `<BINARY>` is the test binary to run.
* `<REPORT_JSON>` **is optional, and that is the trap.** Omit it and the gate
  looks in `<report-dir>/<ROW_NAME>.json`. Since the binary writes wherever it
  was COMPILED to write, those two almost never agree, and you get
  `registered=0`. **Always pass it explicitly.**
* Many rows may share ONE binary and ONE report — see attribution below.

## Why the report path cannot be passed any other way

`ODIN_TEST_JSON_REPORT` is a **`#config`**, i.e. a compile-time define, not an
environment variable. Setting it in the child's env does nothing: the binary
was already built with `""` baked in and writes no report at all.

Consequences worth stating plainly:

1. `--report-dir` does **not** redirect where the binary writes. It only
   controls where the gate's captured stdout/stderr logs go.
2. Copying a report to `pty_width.json`, `pty_ffi.json`, … does nothing
   useful either — the binary will not write to those names, and the gate
   reads the path from the spec, not the directory.
3. **Per-suite report files require per-suite builds.** You asked whether that
   is true: it is. One build produces exactly one report. But see below —
   for parity purposes you usually do not need one report per row.

## Attribution: why one report serves four rows

**`registered` is per-binary and is SUPPOSED to read the same on every row.**
It answers "how many tests are registered in this binary" (38 for
`tests/pty`), which is a registration check, not a coverage check. It is what
stops a mis-filtered binary scoring a vacuous pass.

**`pass` is per-ROW and is attributed by ledger GROUP**, which is why one
binary can serve many rows without every row reading 218:

| row | claims | measured |
|---|---|---|
| `pty_width` | `width_test` | **67** |
| `pty_ffi` | `ffi_test` | **27** |
| `pty_screen` | `screen_test` | **73** |
| `pty_driver` | `pty_test` | **51** |
| | **TOTAL** | **218** |

Each row's floor is compared only against the groups its `files` column names.
`pty_width` is measured at 67, not 218. The run total is 218, not 872.

Before this, every count was taken over the whole log, so all four rows read
218 and each floor was "satisfied" by assertions belonging to someone else —
floors that could not be falsified. Same command, before/after:

```
before:  pty_width pass=218   (whole log)      x4  -> TOTAL 872
after:   pty_width pass=67    (width_test only)    -> TOTAL 218
```

## Reading the output

Every row prints its provenance, so "is this even my suite's number?" is
answerable without a debugger:

```
   groups claimed by this row and present: width_test
   groups in this log NOT claimed by this row: pty_test, ffi_test, screen_test
```

A group nobody claims is surfaced, never silently folded into a passing total.

## Rules worth knowing

* **Tallies are cumulative snapshots.** Never sum distinct `HS_TALLY` lines:
  one run of `tests/pty` line-sums to **7999** where max-per-group gives the
  true **218**. The gate always takes the max per group.
* **A suite that hangs is timed out, not waited on.** `--timeout=6s|90s|ms`
  (default 600000). On timeout the gate SIGTERMs then SIGKILLs the child's
  **whole process group**, so no grandchild survives, and reports `TIMEOUT`
  with the partial counts discarded.
* **Unknown tiers are refused, not defaulted.** `--tier` values are
  `hermetic`, `fixture`, `pty`. A typo fails the row out loud rather than
  filing it under hermetic.
* **`--allow-skip` is a decision, not a default.** Skips are red until
  explicitly allowed.

## Self-check

`bash tests/tools/hscheck/selfcheck.sh` proves the gate in both directions —
16 assertions covering: empty table fails, 1-test fixture passes, unreachable
floor is named a REGRESSION, missing row is refused, attribution is per-group,
and a hanging suite times out without leaking processes.

## The gate RUNS the suite binary — its env must be able to find the product

This is not a report reader. For every `--suite=` row the gate spawns the binary
itself, so the checks the binary performs at spawn time apply to the gate's
environment, not to the one you used for your manual run.

`pty_resolve_bin()` resolves the product binary as: `$BIN` → `$HS_BIN` →
`pty_bin_default`. `pty_bin_default` points at `result/bin/herdr-session`,
which only exists where a nix build has created the `result` symlink.

**In a linked worktree there is usually no `result/`.** The gate then reports
`binary not found` for every spawn-based test, which reads as a regression in
whatever you just changed when it is really a missing env var. Export the local
build instead:

```sh
./dev/local-build.sh          # -> /tmp/hs-local
export BIN=/tmp/hs-local      # MUST be exported; the gate spawns its own children
odin build ./tests/it -build-mode:test -define:ODIN_TEST_THREADS=1 \
     -define:ODIN_TEST_JSON_REPORT=/tmp/it.json -out:/tmp/bin_it
BIN=/tmp/hs-local /tmp/bin_it                     # manual run
/tmp/hs_check --parity=tests/parity.tsv --tier=hermetic \
  --report-dir=/tmp/r/run --suite=resize=/tmp/bin_it:/tmp/it.json
```

Related trap: **the report file is overwritten by the gate's own run**, because
the report path is baked in at build time. A clean manual run's JSON is clobbered
by the gate's next run, so a `pass=0 fail=N` row may describe the *gate's*
spawn, not yours. Read the report after the run you care about, or build a
separate binary per report path.
