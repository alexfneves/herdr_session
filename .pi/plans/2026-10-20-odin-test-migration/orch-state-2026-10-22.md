# ORCHESTRATOR STATE — read this before touching anything

**Date:** 2026-10-22 · **Tag:** `odin-test-migration` · **Repo:** `/home/alexfneves/gits/herdr_session`
**You are a LANE. Read this file, then your own task section, then go.**

Plan: `plan.md` · Todos: `todos.md` · Decisions: `DECISIONS.md` · Parity record: `../../../tests/parity.tsv`

---

## 1. WHAT IS ACTUALLY DONE (measured, not reported)

Re-measured by the orchestrator through `hs_check` on HEAD `254d5eb`, **not** taken from lane self-reports.

| Task | Suite | Floor | Delivered | Status |
|---|---|---|---|---|
| T0 | baseline freeze | 1544 armed | measured | **DONE** |
| T1 | support + gate | — | `tests/support/*`, `tests/tools/hscheck/*` | **DONE** |
| T2 | product re-homes | diag 10 / keyhints 54 | 10 / 54 | **DONE** |
| T3 | pty FFI + width | 67 + 27 | 67 / 27 | **DONE** |
| T4 | screen emulator | 73 | 73 | **DONE** |
| T5 | pty driver | 51 | 51 | **DONE** |
| T6 | state | 259 | **270** | **DONE** (green, see §2) |
| T9 | theme in-proc | 171 | 142 | **PARTIAL** — 36 deferred to T14 (`pty` tier). Gap is recorded and intentional. |

**Delivered so far: 694** (unit 476 + pty 218). Parity total floors: **1862** (1478 hermetic + 254 pty + 130 fixture).

## 2. NOT YET STARTED — this is the remaining migration

`T7 render(69)` · `T8 ui(168)` · `T10 app(444)` · `T11 handoff(35)+probes` · `T12 tui(145)` ·
`T13 resize(123)` · `T14 fixture(130 + 36 theme-pty)` · `T15 nix wiring` · `T16 delete dispatch` ·
`T17 delete .sh/.py` · `T18 report`

Zero test files exist for render/ui/app/handoff/tui/resize. `tests/it/` **does not exist yet** (T11 creates it).
`nix/tests.nix` **does not exist**. `flake.nix` has **no `checks` output**. `main.odin` still has
`switch name` (line 1496) and 7 `case_*` procs. All `dev/*-smoke.sh`, `dev/lib.sh` and `dev/*.py` are still present.

---

## 3. ⚠️ THREE THINGS THAT WILL BITE YOU IF YOU DON'T READ THEM

### 3a. You MUST BUILD with `-define:ODIN_TEST_THREADS=1` (build time — the env var is not enough)

The orchestrator measured this on the *same source*:

| Build flags | Runtime env | `[HS] FAIL` count |
|---|---|---|
| `-define:ODIN_TEST_THREADS=1` | any | **0** |
| no define | `ODIN_TEST_THREADS=1` set at runtime | **1** |
| no define | unset | **3** |

`ODIN_TEST_THREADS` is a `#config` — **compile-time only**. Setting it in the child's environment does
nothing. Every unit-binary build in this migration MUST carry
`-define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_JSON_REPORT=<abs path>`.

### 3b. The `state` row's "PROVISIONAL / 2 failing" flag is RESOLVED — it was threading

`tests/parity.tsv`'s `state` row opens with "**PROVISIONAL — DO NOT TREAT 270 AS SETTLED** … 268 pass
fail=2 … `inside the window: 4 distinct variable(s), want exactly 3`", and claims it is
"NOT fixture-dependent (identical armed and unarmed)".

That claim is **wrong in its diagnosis**. It is not fixture-dependence, it is §3a: the env-mutation
tests race the ledger when the binary is multi-threaded. Built correctly the `state` group is
**270 pass / 0 fail**. **Treat T6 as DONE.** The underlying structural fix is still owed as
`SUPPORT-ENV-MU` (§5) — do not let a red `state` number scare you into "fixing" a non-bug.

### 3c. The gate's red for `theme` is CORRECT — do not "fix" it

`theme` reports `142 vs floor 171 → REGRESSION, 29 short`. That is the **recorded intentional gap**:
135 required + 7 additive delivered, 36 pty-tier assertions deferred to T14.
**Do not lower the floor. Do not mark it green.** Its red is the point.

---

## 4. YOUR WORKTREE (isolation is mandatory — do not work in the main checkout)

Lanes run **concurrently into the same Odin package `tests/unit`**. Unsynchronized work in one tree
corrupts everyone's build. Each lane has its **own git worktree and its own branch**:

```
/tmp/lane-render    branch lane/render      → T7
/tmp/lane-ui        branch lane/ui        → T8
/tmp/lane-app       branch lane/app       → T10
/tmp/lane-handoff   branch lane/handoff   → T11
/tmp/lane-resize    branch lane/resize    → T13
/tmp/lane-theme     branch lane/theme     → T9 gap + seam
/tmp/lane-scaffold  branch lane/scaffold  → T15 + env mutex
```

**cd into YOUR worktree and never leave it.** Staged build deps (`clay-odin/`, `vendor/termbox2-odin/lib/`)
are already copied in — they are gitignored, so a fresh worktree would not build without them.

**Never touch `tests/parity.tsv`.** Merging 7 concurrent edits to one TSV guarantees lost rows. The
scaffold/integration agent owns it. **Report your numbers; do not write the file.**
*(Exception: you are the scaffold lane.)*

## 5. TOOLCHAIN + THE EXACT COMMANDS

```sh
export PATH=/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/bin:$PATH   # prints dev-2026-10
cd /tmp/lane-<you>
BIN=/home/alexfneves/gits/herdr_session/result/bin/herdr-session

# build your suite
odin build tests/unit -build-mode:test \
     -define:ODIN_TEST_THREADS=1 \
     -define:ODIN_TEST_JSON_REPORT=/tmp/lane-<you>.json \
     -out:/tmp/lane-<you>_unit

# run it
env BIN=$BIN /tmp/lane-<you>_unit

# gate it (build the gate yourself too, or reuse /tmp/ov/hs_check)
odin build ./tests/tools/hscheck/cmd -out:/tmp/lane-<you>_gate
/tmp/lane-<you>_gate --parity=/home/alexfneves/gits/herdr_session/tests/parity.tsv \
  --tier=hermetic --report-dir=/tmp/lane-<you>-run \
  --suite=<row>=/tmp/lane-<you>_unit:/tmp/lane-<you>.json
```

Read `tests/tools/hscheck/HOWTO.md` — the `--suite=ROW=BIN:REPORT` path is baked at **build** time;
`--report-dir` does **not** redirect where the binary writes.

**Gate rules enforced on you:** registered > 0 · no FAIL · no SKIP without a sentence-reason ·
`pass >= floor` · no `%!` in your log.

**SUPPORT-ENV-MU (open request, T15's lane):** there is no support-wide mutex for environment
mutation. Each file takes its own local lock; they cannot see each other. §3a is the workaround.
If you hit it, file it in your report, do not hand-roll a second mutex.

## 6. UNCHANGED GROUND RULES (from todos.md — these still bind you)

1. **Assertion parity is the governing rule.** Fewer assertions = REGRESSION, said out loud.
2. **`git add` before you build. Stage only your own paths. NEVER `git add -A`.**
3. **Delete nothing.** `.sh`/`.py` deletion is T17, last, one owner.
4. **Never widen a timing threshold.** Frozen list is in `tests/parity.tsv`'s header.
5. **No screen-scrape → byte-grep substitutions.** The `Screen` emulator exists; use it.
6. **Fixture discipline.** `hs-t-*` scratch only; the two live user sessions
   `2026-10-20-19-16-08-614` / `2026-10-20-21-07-27-640` are **untouchable**; real
   `~/.config/herdr_session.json` md5 (`0cce060b885d2796d87ef1f4fd8d98b5` as of this morning —
   re-verify with `md5sum` at lane start) unchanged before/after. Arming recipe: `baseline-measurement.md` §"Fixture arming".
7. **Never concatenate suite logs.**
8. **>3 throwaway probes on one syntax question → STOP and record the finding.**

## 7. REPORT BACK — put it at the top of your final message

```
LANE: <name>   WORKTREE: /tmp/lane-<name>   BRANCH: lane/<name>   COMMIT: <hash>
SUITE: <name>  FLOOR: <n>  DELIVERED: <n>  FAIL: <n>  SKIP: <n>  REGISTERED: <n>
FLOOR MET: YES/NO   (if NO → say what is missing, per case, not summarised)
GATE OUTPUT: <paste the --tier=... line>
PARITY ROW I OWN: <suite>\t<tier>\t<floor>\t<pass>\t<fail>\t<skip>\t<groups>\t<task>
UNPROVEN: <what your suite still does NOT prove>
REQUESTS TO OTHER LANES: <none | list>
```

**A green suite that asserts less than its floor is a failure. Say it in the report.**
