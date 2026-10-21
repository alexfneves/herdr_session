# Odin Test Migration — tests leave the product

**Date:** 2026-10-20
**Status:** Draft → approved for execution
**Directory:** `/home/alexfneves/gits/herdr_session`
**Tag:** `odin-test-migration`
**Governs:** RCH-5, RCH-6, RCH-7 (as pinned in `../2026-10-18-herdr-session-tui/50-requirement-changes.md`)
**Read first:** `scout-context.md` (same dir) — the pre-migration audit this plan is built on.

---

## Intent

Move **all** test code out of the shipped `herdr-session` binary into a `tests/` tree written in Odin on
`core:testing`, replace every test-related `.sh`/`.py` (including the pty drivers and the probe scripts
hidden as heredocs inside `handoff-smoke.sh`), and make `nix flake check` actually run them — **without
losing a single assertion.**

## Why it matters (the one sentence)

Today `main()` dispatches ~31 named test entrypoints from a binary we ship, the test harness is 8
inconsistent bash scripts and 5 Python drivers, and `nix flake check` runs nothing. The entire risk of
fixing this is **silent loss**: a port that goes green while asserting less. Every decision below serves
making that impossibility *mechanical*, not a matter of good intentions.

## THE GOVERNING RULE

> **Assertion-count parity, per suite, counted before and after each port.**
> Fewer assertions after the move is a **REGRESSION** — said out loud, never reported as a green suite.
> Plus: `core:testing` scores **0 tests as a pass**. Registered-count > 0 is a hard guard.

**Authoritative baseline (fixture-armed, orchestrator-measured 2026-10-20 ~21:50):**

```
state 259 · app+disc 532 · tui 172 · theme 171 · resize 138 · ui 90 (6/6) · render 69 · handoff 35
TOTAL: 1461 PASS / 0 FAIL
```

Use **1461** and those **per-suite** figures. RCH-5/6's "~1,354" prose and the scout's §1
reconstruction (1,275) are **superseded** — do not cite them.

### ⚠️ CORRECTION — the `ui` figure in that baseline is stale (measured 2026-10-20)

An un-armed run of all eight suites (`baseline-measurement.md`, same dir) shows the recorded total is an
**understatement**. Per-suite vs the last recorded breakdown:

| Suite | Recorded | Measured | Δ |
|---|---|---|---|
| `state` | 259 | **259** | 0 — 100 % hermetic |
| `theme` | 171 | **171** | 0 — 100 % hermetic |
| `render` | 69 | **69** | 0 — 100 % hermetic |
| `handoff` | 35 | **35** | 0 — 100 % hermetic |
| `app+disc` | 532 | 444 | −88 fixture-gated |
| `tui` | 172 | 145 | −27 fixture-gated (2 scenarios skipped) |
| `resize` | 138 | 123 | −15 fixture-gated (3 runs skipped) |
| `ui` | 90 | **168** | **+78** ⚠️ |

The entire `ui` delta is in **`ui-frame` (14 → 92)**; the other five cases match the historical record
*exactly* (16/12/20/17/11). The cause is visible in the log: `ui-frame` now carries the **RCH-1
no-outer-border geometry proofs** and the `KEYS_MODE` footer-overflow checks. They are real assertions —
the harness's own count and an independent `grep -c` over the same log section **both give 92**.

**Consequences:**
- **`ui`'s floor is ~168, not 90.** Porting `ui` against a floor of 90 would have allowed **78 assertions
to be dropped while still reporting "parity"** — the single largest silent-loss risk found so far.
- Expected armed total is **≈1544** (1414 hermetic + 88 + 27 + 15), leaving a ≈5 residual to explain.
- **`ui 1461` must not be treated as final.** T0's armed re-run sets the corrected floors; until then
  `ui`'s floor is provisional at 168.
- This vindicates risk **R-17** and the rule that only a real run may establish a baseline.
- **534 assertions are proven 100 % hermetic** (`state`+`theme`+`render`+`handoff`) — the strongest
core for the in-sandbox `nix flake check` tier.

---

## Scope

### In scope
1. Test code leaves the product: the `argv[1]` case dispatch (31 entrypoints, `src/main.odin:1562-1598`) is deleted.
2. `tests/` folder, **Odin only**, `core:testing`. Port the 8,267 lines in `src/*_cases.odin` / `*_live.odin`.
3. Every test `.sh`/`.py` replaced by Odin. **No thin bash runner survives as a fallback** (explicitly withdrawn).
4. `nix flake check` runs them — via a **separate test derivation**, not the product's filter.
5. Two **product** symbol re-homes (`diag_head`, `KEYS_*`) — product changes with their own tests.
6. Uniform gate tightening: the four weak suites get the strong rule set (approved 2026-10-20).

### Out of scope (RCH-7 pin — do not widen)
- Renaming `vendor/` → `bindings/`; creating `libs/`/`assets/`; reshaping `src/`.
- **Changing the product derivation's filter semantics** (`nix/package.nix:26-33` stays as-is).
- Any refactor motivated by folder layout. Existing layout stays.
- Re-implementing or re-litigating RCH-3 / RCH-4. **They are DONE and verified.** Only keep parity.

> **Critical distinction to preserve:** "don't change the *product* derivation's filter" ≠ "the *test*
> derivation can't have its own wider source view." The test derivation gets `tests/` + `src/` +
> `vendor/` + staged archives. The product keeps `src/` + `vendor/` only. Conflating these would block
> gate #4; the pin does not.

---

## Facts verified during planning (not assumed — this toolchain surprises you)

| Claim | How verified | Result |
|---|---|---|
| `odin test` on an empty/misfiltered package exits 0 | `odin test .` on a package with no `@(test)` | ✅ Confirmed: `"No tests to run."` **exit 0**. The hazard is real. |
| A **separately-built** test binary exists | `odin build <pkg> -build-mode:test -out:<bin>` | ✅ Works. Lets nix **build once, run many** and lets the gate inspect a real artifact. |
| Machine-readable test report | `-define:ODIN_TEST_JSON_REPORT=<path>` | ✅ Emits `{total, success, duration, packages:{<pkg>:[{success,name}]}}`. **This is the outer guard's input.** |
| Cross-dir relative imports from `tests/` | `import app "../src/app"` from a sibling dir | ✅ Works. One package instance of `clay`/`termbox2`/`app`. **No `odin.json` needed.** |
| `openpty` / `ioctl` absent from `core:sys/posix` | grep SDK | ✅ Confirmed absent. But `foreign import odin_c "system:c"` **works**: `openpty rc=0`, `TIOCSWINSZ rc=0`. |
| Renaming a C symbol in a foreign block | `@(link_name="ioctl")` on `ioctl_ws` | ✅ Required. The `--- "name"` form is a **syntax error** in this Odin. |
| Termios readable after the child dies (the whole SIGTERM proof) | held slave fd + `posix.tcgetattr` after `waitpid` | ✅ `same_lflag=true`. The proof survives the port. |
| `WIFEXITED`/`WEXITSTATUS` exist | `posix/sys_wait.odin:92-108` | ✅ |
| Atomic counter wrapper over `expectf` | `sync.atomic_add` + `-define:ODIN_TEST_THREADS=2` | ✅ 3 assertions across 2 tests counted correctly **under threading**. |
| `core:regex` exists | grep SDK | ❌ **Absent.** `core:strings` + column-offset predicates only. |
| `@init`/`@fini` are usable | compile probe | ⚠️ Must be `proc "contextless"` — **cannot allocate or `fmt` inside them.** Avoid; use explicit setup procs. |
| nix sandbox has a pty | `pty.openpty()` inside a sandboxed derivation | ✅ `PTY_OK 3 4`, `/dev/ptmx -> /dev/pts/ptmx`. **Pty tests CAN run in-sandbox.** |
| nix sandbox has network | TCP connect inside a derivation | ❌ **No.** Fixture/remote tests **cannot** run under `nix flake check`. |
| `nix flake check` today | ran it | Passes **vacuously** (no `checks` output). Under pure eval it **fails on devenv** (`devenv was not able to determine the current directory`) — pre-existing, non-test. |
| Toolchain pin | `dev/local-build.sh:3` | Store path **says** `dev-2026-09`, `odin version` from it **prints** `dev-2026-10`. Pin by **store path**, never by name. |

---

## Architecture

```
tests/
  parity.tsv              THE ARTIFACT. Frozen per-suite before/after table. Machine-readable.
  support/                (Agent S — the only agent allowed here)
    ledger.odin           check(), skip(), atomic counters, HS_TALLY line, the `%!` scan
    scratch.odin          hs-t-* lifecycle + herdr-session-list snapshot/restore (defer discipline)
    env.odin              base_env: HERDR_* scrub, XDG aim, TERM force, fixture read
    fmtguard.odin         assert_formatted equivalent (`%!` fallout) — a bug class caught twice
  pty/                    (Agent P — the only agent allowed here)
    ffi.odin              openpty / forkpty / ioctl(TIOCSWINSZ,TIOCSCTTY) via system:c + @(link_name)
    screen.odin           THE TERMINAL MODEL. Ported, not avoided. See "The Screen model" below.
    pty.odin              Pty: spawn/poll/read/wait_screen/watch_screen/resize/resize_latency/
                          kill/alive/exit_info/termios_now/cpu_ticks
    width_test.odin       tb_wcwidth vs a frozen width table (must land BEFORE any rune assertion)
  unit/                   hermetic, in-process, thread-safe. NO subprocess, NO pty, NO fixture.
  it/                     integration: spawns subprocesses / ptys. Single-threaded runner.
  tools/hscheck/          package main — THE SINGLE ENTRYPOINT. Parity gate + tiering + report.
```

### The single entrypoint (RCH-6 gate 5)

`hs_check` (Odin, `tests/tools/hscheck/`) is the one thing anyone runs. It:
1. Asserts **its own** suite table is non-empty (a broken gate that checks nothing must fail loudly).
2. Runs each suite binary (`-build-mode:test`) with a clean env + scratch, capturing logs separately
   (never concatenated — a later suite must not inherit an earlier suite's PASSes).
3. Reads each suite's `ODIN_TEST_JSON_REPORT` → **fails if `total == 0`** (kills the "0 tests = pass" hazard).
4. Reads each suite's `HS_TALLY <suite> <pass> <fail> <skip>` line from the log → **fails on any FAIL,
   on any SKIP unless explicitly declared, and if `pass < floor`.**
5. Also runs the `%!` format-fallout scan over every log.
6. Prints the **before/after table** and writes it into `tests/parity.tsv`.

This puts the tally/verdict rules **outside** the runner, exactly where `dev/lib.sh`'s `tally` /
`classify_log` / `smoke_verdict` live today — so no earlier `PASS_TOTAL=0` reset can erase a verdict.

### Tiers — the honest answer to "what can `nix flake check` actually run"

Verified: the nix sandbox **has** a pty but **has no network**. The fixture requires ssh to a real
remote, so fixture-gated tests are physically unable to run in `nix flake check`. Pretending otherwise
produces the exact failure class this migration exists to remove — a green check that ran nothing.

| Tier | Contents | Runs under `nix flake check`? |
|---|---|---|
| **hermetic** | Everything in `tests/unit/`, the pty local cases (`boot-local`, `state-*`, `del-key`, `mode-filter-immutable`, `sigterm`, `no-orphan`, `resize-*`, `handoff-*`, `render`, `ui`, `guard-*`) | ✅ Yes — and **zero skips permitted** |
| **fixture** | `app-live`, `fetch-live`, `boot-remote`, `roundtrip`, `delete-notice`(needs `herdr`+ssh), `discriminator`, `selection-shrink` | ❌ Not in-sandbox. Run by `hs_check --tier=full` locally / in privileged CI, which enforces the **full 1461**. |

Wired as **two** check attributes: `checks.<sys>.odinTests` (in-sandbox, hermetic) and
`checks.<sys>.odinTestsFull` (`__noChroot = true`, needs the fixture env passed through). Neither is a
lie about what ran. The plan's parity table records the hermetic floor separately from the 1461 full
total — **measuring that split is Task 1, not an afterthought.**

### Uniform gate (approved tightening)

Today (§2.9 of the scout) `render`, `ui`, `theme`, `state` have **no zero-assertion rule and no
freshness gate**; `ui-smoke` accepts `RESULT: PASS` with zero `[PASS]` lines; `theme-smoke`'s `record()`
treats 0/0 as not-failed; `render-smoke`'s `tally` has no zero rule. **These holes are not portable.**
Every migrated suite runs under the strongest rule set:

> registered tests > 0 · no `[FAIL]` · no `[SKIP]` unless declared with a sentence-reason ·
> `pass >= suite floor` · no `%!` in any log · binary under test is fresh.

**Freshness:** under nix the derivation *is* the freshness guarantee (mtimes are epoch-sentinel and the
rule is intentionally a no-op — say so out loud). Keep `require_fresh_bin` as a **local-only** check in
`hs_check` (binary mtime vs newest `.odin`), retired in the nix path **explicitly**, not silently.

### The Screen model — ported, not avoided

`dev/tui_drive.py:55-76` documents the central truth: termbox emits a **cell diff**, so grepping the
raw stream for `delete_session` **fails on a correct render** (`delte_sss`). Any port that byte-greps
instead of modelling the screen converts ~94 real assertions into noise. **Not portable. Hard rule.**

`tests/pty/screen.odin` ports, verbatim in behaviour:
- Incremental UTF-8 with a carry buffer (`core:unicode/utf8`) — a rune split across reads cannot corrupt the grid.
- Escape families: `CSI`, `OSC … BEL`, `ESC ( X`, `ESC ) X`, `ESC # 8`, generic 2-byte fallback.
  (The missing `ESC ( B` is a recorded real bug: it smeared `"(B"` and turned `delete_session` into `delete_sess(Bn`.)
- CSI verbs: `H`/`f`, `A/B/C/D`, `d`, `` ` ``, `J`(0/2), `K`(0/1/2). SGR and DEC-`?` modes ignored for content.
- Control chars: `\r`, `\n`, `\b`, `\t`(+8).
- **Wide-char placement**: a width-2 glyph blanks the following cell.
- Width authority = **`termbox2.tb_wcwidth`** — the same table the product uses (`src/render/measure.odin:127`),
  not `unicodedata`. **This is not an exact match on some combining marks.** Therefore:

> **Task: a width-parity test before any rune assertion.** Freeze the exact runes the Python drivers use
> (`世`, `😀`, and every combining mark reachable in `del_key` / `ui-edit` / `a世b😀c`) into a table and
> assert `tb_wcwidth` agrees with the Python result for each. If any differ, **record it and resolve
> before porting `del_key`** — a width change silently changes what whole-rune-deletion evidence means.

### Timing evidence shape is load-bearing

Sequential `wait_screen` calls "timestamp the look, not the arrival" (`tui_drive.py:285-288`). The port
must keep the **pending-set** shape:
- `watch_screen(labels, timeout)` — concurrent first-seen times for N labels.
- `resize_latency(rows, cols)` — time to the **first byte** of the repaint, not time to look.
- `written` — bytes *we* sent, as proof that no key was pressed (ISC-13).

**No live threshold may be widened during this migration.** The in-tree thresholds (paint ≤ 4/5/6 s,
idle ≤ 2 clock ticks over 5 s, resize first repaint < 500 ms, `working:` < 1 s after Enter, dead-host
≤ 6.5 s, `delete_notice` gap ≥ 2.0 s and < 12 s) are **frozen**. The runner is forced single-threaded
for pty tests **before** any of them is touched, so a flake is a real bug and not an excuse to loosen.

---

## Resolving each blocker

### B1 — `diag_head` (`src/main.odin:963`) — HARD BLOCKER, product code trapped in `main`
7 truncation assertions (`app_cases.odin:1046-1099`) depend on it; `tests/` cannot import `main`.
- **Move to:** `src/ui/text.odin` as `ui.diag_head`. Same signature, same behaviour, **same name** —
  minimal churn; the value is the location, not a rename.
- **Treat it as a product change, not test plumbing.** It has a live caller (`tui_host_line`, `main.odin:949`)
  that must keep working.
- **Its own test:** the 7 assertions land in `tests/unit/diag_test.odin`, asserting rune-boundary safety
  on a multi-byte head, a `\n`-terminated head, a cut that would split a continuation byte, and the `…` suffix.
- **Parity note (said out loud):** these 7 move **from the `app` suite to `ui`/`diag`**. Record it as a
  transfer line in `parity.tsv`: `app 532 → 525`, `diag 0 → 7`. Total unchanged.

### B2 — `KEYS_MODE` + siblings (`src/main.odin:1162-1212`) — HARD BLOCKER, product data trapped in `main`
The footer-overflow suite (`ui_cases.odin:505-532`, hints at 80/100 cols) depends on it.
- **Move to:** `src/ui/keyhints.odin` as `ui.key_hints_for(state) -> []Key_Hint`, owning all seven
  tables (`KEYS_MODE/ATTACH/DELETE/NAME/PICK/THEME/ERROR`).
- `main`'s `tui_key_hints` becomes a one-line delegate.
- **Its own test:** `tests/unit/keyhints_test.odin` — every state returns a non-empty table, no
  duplicate label, and the 80/100-col overflow behaviour is preserved exactly.
- **Parity note:** the footer-overflow assertions transfer from `ui`-via-`app` to `keyhints`. Same total, recorded.

### B3 — `any_failed` has no `core:testing` analogue (~30 uses, incl. save/restore at `state_cases.odin:1349-1358`)

**Redesign, do not wrap.** The save/restore pattern only exists because `case_state_offline` runs a
nested battery under a stripped env and needs one merged verdict. Under `core:testing` each sub-battery
becomes its own `@(test)` proc, so the merge is unnecessary — `error_count` is per-test.

| Need | Replacement |
|---|---|
| "did this test fail?" | `testing.failed(t)` (derived from `t.error_count`) |
| "did **this inner block** fail, and let me continue?" | `before := t.error_count; …block…; block_failed := t.error_count != before` |
| "one verdict across a whole run" | Provided by the **outer gate**, not by a global. This is strictly stronger: the gate's verdict cannot be erased by an earlier reset. |

`expect_noop` / compound-block isolation map the same way. **No new global is introduced.**

### B4 — `tui_fixture_remotes` (`main.odin:443`) — DECIDED: keep, as a declared dev seam

**Decision: KEEP `tui_fixture_remotes`, `HS_TUI_TRACE`, and `HS_PIDFILE` in the product binary, and
document them as supported developer seams.** Do not pretend they are gone.

**Why** — the alternative is empirically worse. RCH-5 says "no test code in the product"; the honest
answer is that these are **not test code, they are injection points the product legitimately owns**, and
removing them destroys the fixture path:
- The documented alternative (temp `XDG_CONFIG_HOME` + a real config file) **moves herdr's own state
  dir**, which makes `herdr session list` return empty (`60-handoff-notes.md`, added in `5e84fae`).
  That surfaces as `added=0` / `names=` / "host session missing" — a relocated filesystem, not a bug.
  **The seam exists precisely so the fixture can inject remotes *without* moving the state dir.**
- Removing the seams would silently delete 5 fixture scenarios' worth of verification.

**Conditions attached (all asserted, not documented-and-hoped):**
1. **Inert by default.** No env var set → no fixture remotes, no trace file written, no pidfile written.
   Asserted in `tests/unit/seam_test.odin`.
2. **Additive only.** The seam may add remotes; it may never alter the configured set or real hosts.
3. **Named and documented** in the README under "Developer seams", with the RCH-3 trap spelled out.
4. **Anti-criteria grep** keeps the seam from leaking into any other product path.

This is an **accepted trade-off, decided here**, so it cannot drift either way later.

### B5 — Repaint-hook wiring — the test binary must own its hook

`terminal.set_full_repaint` (`src/terminal/handoff.odin:54`) is a single slot. `main` registers
`tui_repaint_hook`, which branches on `TUI_ACTIVE`. A `tests/` binary:
- registers **its own** painter via `terminal.set_full_repaint(hs_repaint_hook)`;
- `hs_repaint_hook` increments a test-owned `FRAMES_PAINTED` counter and paints a test frame;
- **never** calls `tui_paint` and **never** sets `TUI_ACTIVE` — so it cannot piggyback `main`'s paint path.

This is what makes `main`'s smoke painter (`paint`/`draw_box`/`draw_text`/`force_repaint`, `main.odin:78-119`)
deletable along with the dispatch.

### B6 — `check` / `say` volume (~620 + ~180 calls, all 8 files)

Mechanical but large — plan for it as bulk work, and make the mapping uniform so it can be scripted and
reviewed mechanically:

| Current | Replacement |
|---|---|
| `check(name, cond, detail)` | `hs.check(t, name, cond, detail)` → wraps `testing.expectf(t, cond, "%s — %s", name, detail)` **and** bumps the atomic tally and emits `[HS] PASS/FAIL …` |
| `say(msg)` | `hs.note(t, msg)` → `log.info`. **Evidence lines must still reach the transcript** — watch `ODIN_TEST_LOG_LEVEL`. |
| `say_raw(label, data)` | `hs.note_raw(t, label, data)` — escaped bytes |
| `check_int` | `testing.expect_value(t, got, want)` |
| `expect_state` / `expect_cmd` | `expect_value` on enums + message |
| `expect_cell` (transition cell) | compound `expectf(t, m.state == want && cmd.kind == want_cmd, …)` |
| back-buffer cells (`cell_at`/`glyph_at`/`dump_rows`) | **No equivalent.** Hand-roll on `tb_get_cell(x,y,back=1,&ptr)`. **The `dump_rows` transcript band is load-bearing evidence and must be kept deliberately** — `core:testing` prints one failing line and no grid. |
| `expect_wire` (byte pattern in pty stream) | `expectf(t, contains(raw, pat), …)` over the driver's accumulated buffer |

`[PASS]` text disappears from the report itself — nothing parses it except the tally, which is going
away. The `[HS] PASS` line exists **only** to give the outer gate something to count.

### B7 — Python-only stdlib, ported

| Python | Odin |
|---|---|
| `unicodedata` width | `termbox2.tb_wcwidth` + the frozen width-parity test above |
| `codecs` incremental UTF-8 | `core:unicode/utf8` + carry buffer |
| `select` | `posix.poll` |
| `openpty`/`forkpty`/`ioctl` | `foreign import odin_c "system:c"`, **`@(link_name="ioctl")`** (precedent `src/ui_cases.odin:346-354`) |
| `WIF*` macros | `posix/sys_wait.odin:92-108` — already present |
| `/proc/<pid>/stat` CPU ticks | read directly; **index from the END of the field list** (`comm` may contain spaces) |

### B8 — The hidden Python: `sig_probe.py` / `env_probe.sh`

These are **heredocs written at runtime by `handoff-smoke.sh:37-81`**. Deleting `dev/*.py` does **not**
remove them. The SIGINT-to-process-group, `SigBlk` mask, `HERDR_*` scrub, pgroup and cwd proofs must be
re-expressed as an **Odin probe binary under `tests/it/probes/`**, or three handoff checks vanish
silently. **This is the single easiest thing to miss in the whole migration.**

### B9 — `device_discriminator`'s exit-code bug must not be inherited

`dev/device_discriminator.py:163` is `bad = [r for r in results if not r[1]]` — `r[1]` is the *label*,
so `bad` is always empty and **the driver always exits 0**. Today the failure signal comes only from
bash's tally over its log. The Odin port must derive its verdict from the **boolean**, and the outer
gate must count its assertions independently.

### B10 — Anti-criteria greps with no regex

`core:regex` is absent. `^(local|[0-9a-fA-F:.]+)\s`, `\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(\.\d{3})?\s…`
and friends become:
- `core:strings` `contains`/`has_prefix` for the literal ones (`localhost`, `core:thread`, `toml`, `kitty`);
- **column-offset predicates** for the structural ones — the `DEVICE_W = 12` approach the discriminator already uses;
- **`os.Walker` for traversal**, with `//` comments stripped first (state-smoke does this; theme-smoke's TOML grep does) or the prose about a rule becomes a rule violation.

---

## Migration order — one commit per suite, per-suite parity gate

**Rule:** a suite is *ported* only when its floor is met and `parity.tsv` is updated. A suite is
*deleted* only after its replacement is green — **never before, never in the same commit as the port.**

| # | Step | Owner | Depends on | Gate |
|---|---|---|---|---|
| 0 | **Re-measure and freeze the baseline.** One full fixture-armed run of the *current* 8 suites. Record per-suite totals **and** the hermetic/fixture split into `tests/parity.tsv` before any code moves. | S | — | 1461 reproduced or the discrepancy explained **before** proceeding |
| 1 | **Support + gate skeleton.** `tests/support/*`, `tests/tools/hscheck`, `parity.tsv` schema. Include `HS_TALLY` emission, JSON-report reading, `%!` scan, the "gate asserts its own table non-empty" self-check. | S | 0 | `hs_check` fails on an empty suite table, passes on a 1-test fixture |
| 2 | **Product re-homes.** `ui.diag_head`, `ui.key_hints_for()`. Product change + `nix build` green + the two new unit tests. | S | 1 | B1/B2 moved with their 7+overflow assertions; transfers recorded in `parity.tsv` |
| 3 | **Pty FFI + width parity.** `tests/pty/ffi.odin`, `width_test.odin`. | P | 1 | `openpty`/`TIOCSWINSZ`/`TIOCSCTTY` proven; frozen rune table agrees |
| 4 | **Screen model.** `tests/pty/screen.odin` + unit tests for the emulator itself (escape families, split-UTF-8 read, wide-char blanking). | P | 3 | Emulator tests green **before** any pty assertion is written |
| 5 | **Pty driver.** `tests/pty/pty.odin` incl. `watch_screen`, `resize_latency`, `termios_now`, `cpu_ticks`, single-thread enforcement. | P | 4 | Spawn → resize → kill → termios-round-trip proven in a smoke test |
| 6 | **Suite: `state`** (259) — `tests/unit/state_*.odin` + source-surface greps | U1 | 2 | floor 259 (minus transferred, plus seam tests) |
| 7 | **Suite: `render`** (69) — incl. `expect_wire`, back-buffer grid, `dump_rows` bands | U2 | 2 | floor 69 |
| 8 | **Suite: `ui`** (90 / 6 cases) — `bring_up`, `shrink_pty`, overflow | U3 | 2 | floor 90 |
| 9 | **Suite: `theme`** (171) — in-proc cases + hygiene block (real-config md5 before==after, XDG non-leak) | U4 | 2 | floor 171 |
| 10 | **Suite: `app`** (532 − transferred) — `app_cases` + anti-criteria greps | U1 | 2,6 | floor recorded with the transfer line |
| 11 | **Suite: `handoff`** (35) + **Odin probe binaries** replacing `sig_probe.py`/`env_probe.sh` | U5 | 5 | floor 35 with the probes proven |
| 12 | **Suite: `tui`** (172) — boot-local, `state-*`, `del-key`, `mode-filter-immutable`, `sigterm`, `no-orphan`, `refresh-key`, guards | U3 | 5,7 | floor 172 |
| 13 | **Suite: `resize`** (138) — 5 scenarios × 3 reps, trace parsing against `terminal/resize.odin`'s frozen format string | U5 | 5 | floor 138 |
| 14 | **Fixture suites** — `app-live`, `fetch-live`, `boot-remote`, `roundtrip`, `delete-notice` (+ `SLOW_HERDR` shim ported intact), `discriminator`, `selection-shrink` | U4 | 11,12,13 | full 1461 reachable via `hs_check --tier=full` |
| 15 | **`nix` wiring.** Separate test derivation (wider source view), archive staging repeated verbatim, `checks.odinTests` + `checks.odinTestsFull`. **Product filter untouched.** | P | 1..14 | `nix flake check` runs the hermetic tier and is **provably not vacuous** |
| 16 | **Delete `argv` dispatch.** The `switch`, `usage()`'s case list, all `case_*` procs, `guard_probe_rows`, `home_dir`, the smoke painter (`paint`/`draw_box`/`draw_text`/`force_repaint`/`FRAMES_PAINTED`) — **only now**, with the test binary registering its own painter. `TUI_ACTIVE`/`tui_repaint_hook` STAY (product wiring). | S | 6..15 | `grep` proves no test entrypoint remains; product `nix build` + full check green |
| 17 | **Delete every `.sh`/`/py`.** `dev/*-smoke.sh`, `dev/lib.sh`, all 5 `dev/*.py`, and the two heredoc probes (gone with the `.sh`). `dev/local-build.sh` stays (build helper, not a test). | S | 14,15,16 | RCH-6 grep gates 1-4 green |
| 18 | **Final report.** Honest total vs 1461, per suite, with every transfer and every accepted gap listed. | S | 17 | — |

**Hard ordering constraints:**
- Nothing touches `src/*_cases.odin` until **Task 0** has frozen the baseline.
- Step 16 **cannot** precede 6-15: the dispatch is the old harness's entrypoint. Deleting it early strands suites.
- Step 17 **cannot** precede 16: deleting the `.sh` files first removes the fallback before the product is clean.
- Steps 6-10 and 11-13 are **parallelizable** (see splits).

---

## Parallel work — disjoint file sets

**Rule: exactly one agent owns each directory below. No two agents write to the same file. Ever.**

| Agent | Owns (write) | Reads (read-only) | Tasks |
|---|---|---|---|
| **S — Support/gate** | `tests/support/**`, `tests/tools/**`, `tests/parity.tsv`, `src/ui/text.odin`, `src/ui/keyhints.odin`, `nix/**`, `flake.nix`, `src/main.odin` | everything | 0,1,2,15,16,17,18 |
| **P — Pty core** | `tests/pty/**` | `src/terminal/**`, `src/render/measure.odin`, `dev/tui_drive.py` | 3,4,5 |
| **U1 — state+app** | `tests/unit/state_*.odin`, `tests/unit/app_*.odin`, `tests/unit/fetch_unit*.odin` | `src/app/**`, `src/input/**` | 6,10 |
| **U2 — render** | `tests/unit/render_*.odin`, `tests/unit/wire_*.odin` | `src/render/**`, `src/terminal/**` | 7 |
| **U3 — ui+tui** | `tests/unit/ui_*.odin`, `tests/it/tui_*.odin` | `src/ui/**`, `src/input/**` | 8,12 |
| **U4 — theme+fixture** | `tests/unit/theme_*.odin`, `tests/it/live_*.odin`, `tests/it/disc_*` | `src/app/theme.odin`, `src/app/config.odin` | 9,14 |
| **U5 — handoff+resize** | `tests/it/handoff_*.odin`, `tests/it/resize_*.odin`, `tests/it/probes/**` | `src/terminal/**` | 11,13 |

**Must stay serial (cannot be parallelised):**
1. **Task 0 (baseline)** — nothing may start until it is frozen.
2. **Task 1 (support + gate)** — every suite imports `tests/support/`.
3. **Task 2 (product re-homes)** — touches `src/main.odin` and creates the packages U-agents import.
4. **Tasks 3→4→5 (pty core)** — strictly serial within Agent P (screen depends on ffi, driver on screen).
5. **Task 15 → 16 → 17** — wiring before dispatch removal before deletion. Serial, one owner (S).

**Coordination rules:**
- A U-agent that needs a change in `tests/support/` or `tests/pty/` **files a request**; it does not edit.
  Uncoordinated edits to shared modules are how suites quietly stop asserting the same thing.
- No agent runs `git add -A`. Stage only your own paths. `git add` **before** `nix build` (repo rule).
- Suites never concatenate logs.

---

## Invariants that must survive (anti-criteria, grep-asserted)

Every one of these is a live assertion today and must be present after the port:

- **O11 guards + `ECHILD` proofs** — `waitpid(-1,WNOHANG) == -1 && errno == 10` after guard refusal. The
  boolean only proves what a function said about itself; `ECHILD` proves it spawned nothing.
- **O12 shape-based version tolerance**, **O13 additive registry merge** (hand-added keys survive a save).
- **`--` before the ssh device** (P2-7).
- **`resizefd` in the poll set** — drop it and resize events stop.
- **0.000 % idle CPU** (the idle-tick proof), **no `core:thread`** in product dirs.
- **RCH-1: no outer border.**
- **ISC-11: no Escape timeout exists** — no `core:time`/`sleep`/`peek_event` in `state.odin`.
- **O10: tagged struct, not a union** — no `union {` in `state.odin`.
- **No Kitty escapes** (`kitty`/`[>1u`) in product dirs.
- **No `2>&1`** in product dirs (stderr never merged into stdout).
- **`attach_target_argv`** — the device-argv proof stays at argv level. A footer-string check would pass
  with a completely device-blind implementation; **do not "add coverage" by weakening it.**
- **XDG discipline:** the real `~/.config/herdr_session.json` md5 is unchanged before/after (RCH-18);
  no `XDG_CONFIG_HOME` leak into the caller.
- **Scratch discipline:** `hs-t-*` only; **live user sessions untouchable** —
  `2026-10-20-19-16-08-614` and `2026-10-20-21-07-27-640` must appear unchanged in every pre/post
  session-list diff. Teardown as `defer`, not as a trap.
- **The herdr-state-dir trap** — the fixture must never move `XDG_CONFIG_HOME` in a way that empties
  `herdr session list`.

---

## Effort & Quality

- **Level:** **Production** — this is a parity-critical refactor of the harness that guards every other invariant.
- **Tests:** **comprehensive** — parity is the test. Plus the new emulator's own unit tests and the width-parity table.
- **Docs:** **inline + README** — a "Developer seams" section and a "Running the tests" section replacing the old smoke-script docs.

## Ideal State Criteria

### Core Functionality
- [ ] ISC-1: `grep -n "switch name" src/main.odin` returns no test dispatch (product binary has no test entrypoints)
- [ ] ISC-2: `find . -name '*.py' -not -path './vendor/*'` returns nothing
- [ ] ISC-3: No `dev/*-smoke.sh` and no `dev/lib.sh` in the repo
- [ ] ISC-4: All tests live under `tests/` in Odin on `core:testing`
- [ ] ISC-5: `hs_check` is a single Odin entrypoint that runs every suite
- [ ] ISC-6: `nix flake check` runs the hermetic tier and is provably non-vacuous
- [ ] ISC-7: Per-suite assertion counts recorded in `tests/parity.tsv` before and after
- [ ] ISC-8: Full-tier total equals 1461 with the per-suite figures matched, or every delta is explained as a transfer
- [ ] ISC-9: `ui.diag_head` exists in `src/ui/text.odin` with its 7 truncation assertions ported
- [ ] ISC-10: `ui.key_hints_for()` exists in `src/ui/keyhints.odin` with the footer-overflow behaviour ported

### Edge Cases
- [ ] ISC-11: Registered test count == 0 for any suite causes a **hard failure** (not a pass)
- [ ] ISC-12: Every suite enforces "no SKIP unless declared with a reason"
- [ ] ISC-13: `%!` format fallout in any log fails that suite
- [ ] ISC-14: Screen emulator handles a UTF-8 rune split across two reads without corrupting the grid
- [ ] ISC-15: `SIGINT`-to-process-group / `SigBlk` / `HERDR_*` scrub proofs exist as Odin probes (not heredocs)
- [ ] ISC-16: Width table confirms `tb_wcwidth` agrees with the old `unicodedata` behaviour on every rune the tests reach
- [ ] ISC-17: `delete_notice` runs against the ported `SLOW_HERDR` shim (fabricated row + 2 s stalls), never real herdr
- [ ] ISC-18: Product seam tests prove fixture seams are inert with no env set

### Anti-Criteria
- [ ] ISC-A-1: No suite's assertion count silently decreased
- [ ] ISC-A-2: No live timing threshold was widened (list frozen before/after — must be identical)
- [ ] ISC-A-3: No screen-scraping assertion was replaced by a byte grep
- [ ] ISC-A-4: The **product** derivation's filter was **not** changed
- [ ] ISC-A-5: No folder reorg (`vendor`→`bindings`, `libs/`, `assets/`, `src/` reshape) happened
- [ ] ISC-A-6: RCH-3/RCH-4 were not re-implemented or reverted
- [ ] ISC-A-7: No `.sh` or `.py` test runner was left as a "just in case" fallback
- [ ] ISC-A-8: A live user session was not touched by any test run
- [ ] ISC-A-9: `device_discriminator`'s always-exit-0 bug was not inherited

---

## Risks & Open Questions (premortem)

| # | Risk | Likelihood | Impact | Mitigation | Status |
|---|---|---|---|---|---|
| R1 | A suite ports green with fewer assertions and nobody notices | High | Fatal — defeats the whole effort | `HS_TALLY` + JSON report + per-suite floor in `parity.tsv`, enforced by the gate, not by review | **Mitigated mechanically** |
| R2 | Screen emulator ported subtly wrong → assertions pass on a model no real terminal produces | Medium | Fatal (false green) | Port with the emulator's **own** unit tests first (Task 4 before Task 12); cross-check emulator output against recorded Python transcripts | Mitigated |
| R3 | `tb_wcwidth` ≠ `unicodedata` on a rune the tests reach → `del_key` means something different | Medium | High | Width-parity table (Task 3) **before** any rune assertion | Mitigated |
| R4 | Timing flakes → the tempting fix is widening a threshold | High | High | Single-threaded pty runner enforced **first**; thresholds frozen as ISC-A-2; loosening requires an explicit recorded exception | Mitigated |
| R5 | Fixture tests can't run in-sandbox → the check looks green but ran the small half | High | High | Explicit tiering; `parity.tsv` records hermetic floor separately; `odinTestsFull` exists and is documented as the real gate | **Accepted & made visible** |
| R6 | `nix flake check` fails for the pre-existing devenv pure-eval reason, not the tests | Medium | Medium | The `checks` outputs are wired so they can be targeted directly (`nix build .#checks.x86_64-linux.odinTests`); the devenv eval bug is recorded as pre-existing and out of scope | Accepted, with a workaround |
| R7 | The gate itself is broken and asserts nothing | Low | Fatal | Gate asserts **its own** suite table is non-empty and that every entry produced a tally line | Mitigated |
| R8 | The heredoc probes (`sig_probe.py`/`env_probe.sh`) are missed → 3 handoff checks vanish silently | **High** | High | Explicitly scheduled as B8/Task 11; ISC-15 names them; grep-gate for "no python at all, including generated" | Mitigated |
| R9 | The seams get removed later "to satisfy RCH-5's letter", destroying the fixture path | Medium | High | B4 records the decision **with reasons and assertions**, so removal requires re-litigating a documented trade-off | Mitigated |
| R10 | Shared-module drift — a U-agent edits `tests/support` to make its suite pass | Medium | High | Directory ownership rule; change requests instead of edits | Mitigated by process |
| R11 | Odin surface traps burn hours (cf. the ~12h Phase 5b incident) | Medium | Medium | Verified-facts table above; **>3 probes on one syntax question → stop and record it** | Mitigated |
| R12 | `dev/local-build.sh` pins the SDK by store path that *lies* about its version | Low | Medium | Every task pins by **store path**; no task may cite "the SDK" unqualified | Accepted |

**Open questions parked (non-blocking):**
- Should `odin.json` collections be introduced later for `herdr_session/...` import paths? Explicitly
  deferred — it changes the *product* build invocation, which is out of scope here.
- Should `dev/local-build.sh` remain the local build helper, or gain a sibling `local-test.sh`? A
  `local-test.sh` is a build helper (not a test runner), so it is permitted — decision left to Task 1.

**Decision:** proceed as-is. R5 (tiering) and R6 (devenv) are accepted-and-visible rather than solved;
everything else is mitigated mechanically.

---

## Definition of "done"

`parity.tsv` shows 1461 assertions accounted for across the tiers with zero unexplained loss, the product
binary contains no test entrypoint, the repo contains no test `.sh` or `.py` of ours, `nix flake check`
executes the hermetic tier and fails loudly if it runs nothing, and every delta between the before and
after columns is a recorded, explained transfer — never a quiet subtraction.
