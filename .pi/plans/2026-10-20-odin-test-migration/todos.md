# TODOS — Odin Test Migration

**Plan artifact:** `.pi/plans/2026-10-20-odin-test-migration/plan.md` ← **read this first, always**
**Audit:** `.pi/plans/2026-10-20-odin-test-migration/scout-context.md` (807 lines — the pre-migration audit)
**Tag:** `odin-test-migration`
**Repo:** `/home/alexfneves/gits/herdr_session`
**Baseline — MEASURED & CLOSED (fixture-armed, `ALLOW_SKIP=0`):**
```
state 259 · app+disc 532 · tui 172 · theme 171 · resize 138 · ui 168 · render 69 · handoff 35
TOTAL: 1544 PASS / 0 FAIL / 0 SKIP
```
Evidence + reproducible fixture-arming recipe: `baseline-measurement.md` in this dir.

> **The handed-down `1461` was wrong and must not be used.** Measured armed: **seven of eight suites match
> their recorded figures exactly.** Two defects found: (1) **`ui` is 168, not 90** — the whole +78 is
> `ui-frame` (14→92), which grew the RCH-1 no-outer-border proof set and the `KEYS_MODE` footer-overflow
> checks and was never re-totalled; (2) the stated total `1461` never matched its own components, which sum
> to `1466` — an arithmetic slip, not lost coverage.
> **Hermetic tier = 1414** (what `nix flake check` can run: the sandbox has a pty but no network).
> Five suites — `state theme ui render handoff` = **585** — are 100 % hermetic. Fixture delta 130 closes
> exactly: 1414 + 130 = 1544.

> Every todo is self-contained. Do not assume the worker read the plan prose — the decision-relevant
> facts are inlined.

## GROUND RULES FOR EVERY TASK IN THIS TAG

1. **THE GOVERNING RULE: assertion-count parity, per suite, counted before and after your port.**
   Fewer assertions after the move is a **REGRESSION** — say it out loud. Never report a green suite
   that asserts less than its floor. `core:testing` scores **0 tests as a pass**: registered count > 0
   is always guarded.
2. **SCOPE PIN (RCH-7): TESTS ONLY.** Do NOT rename `vendor/`→`bindings/`, create `libs/`/`assets/`,
   reshape `src/`, or change **the product derivation's filter** (`nix/package.nix:26-33`). The test
   derivation gets its own wider source view; the product keeps `src/` + `vendor/` only. These are
   different facts — do not conflate them.
3. **RCH-3 / RCH-4 are DONE and verified.** Do not re-implement, re-litigate, or "improve" them.
   Their assertions are a large share of the 1544 and must survive the port.
4. **Delete nothing before its replacement is green.** `.sh`/`.py` deletion is Task 17, last, always.
5. **Toolchain pin:** `/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/bin` — the path
   **says** `dev-2026-09`, `odin version` from it **prints** `dev-2026-10`. Pin by **store path**,
   never by name.
6. **Odin traps** (from `../2026-10-18-herdr-session-tui/60-handoff-notes.md`): `..` range removed →
   use `..<`/`..=`. `-out:` is the output flag; `-o:` is optimisation mode. `@init`/`@fini` **must be
   `proc "contextless"`** and cannot allocate or `fmt` inside — **avoid them**. Do not mix `{}` and `%`
   verbs in one format string. `core:regex` **does not exist**. Struct fields need the comma *before* a
   trailing line comment. Shadowing is a hard build error. Procedure literals capture nothing.
   **>3 throwaway probes on one syntax question → STOP and record the finding.**
7. **`git add` before `nix build`.** Fresh build + explicit `BIN=` before any suite run.
8. **Fixture discipline (unchanged):** `HERDR_SESSION_TEST_REMOTE`/`_ALIAS`/`_UNREACHABLE`;
   `hs-t-*` scratch only; teardown as `defer`; the real `~/.config/herdr_session.json` md5 unchanged
   before/after. **THE TRAP:** moving `XDG_CONFIG_HOME` moves **herdr's own state dir** and makes
   `herdr session list` return empty — that is a relocated filesystem, not a bug. **Live user sessions
   `2026-10-20-19-16-08-614` and `2026-10-20-21-07-27-640` are untouchable.**
9. **No log concatenation.** Each suite/case writes its own log file. A later case must never inherit an
   earlier case's `[PASS]` lines.
10. **Never widen a live timing threshold.** They are frozen; a flake is a bug, not a licence to loosen.

## VERIFIED FACTS you may rely on (probed during planning — do not re-derive)

| Fact | Result |
|---|---|
| `odin test` on a package with no `@(test)` | prints `"No tests to run."` and **exits 0**. Hazard confirmed. |
| `odin build <pkg> -build-mode:test -out:<bin>` | **works** — a separately-built test binary. Use this, not `odin test`, in nix. |
| `-define:ODIN_TEST_JSON_REPORT=<path>` | emits `{total, success, duration, packages:{<pkg>:[{success,name}]}}` |
| `import app "../src/app"` from a sibling dir | **works.** One package instance of `clay`/`termbox2`/`app`. No `odin.json` needed. |
| `core:sys/posix` has `openpty`/`forkpty`/`ioctl` | **NO.** Must `foreign import`. |
| `foreign import odin_c "system:c"` + `openpty` | **works**: `openpty rc=0 master=3 slave=4`, `TIOCSWINSZ rc=0` |
| Renaming a C symbol | `@(link_name="ioctl")` is **required**. `--- "ioctl"` is a **syntax error**. |
| `posix.tcgetattr` on held slave after child death | **works** — `same_lflag=true`. The SIGTERM-restores-tty proof survives. |
| `posix.WIFEXITED/WEXITSTATUS/WIFSIGNALED/WTERMSIG` | exist, `sys_wait.odin:92-108` |
| `sync.atomic_add(&n, 1)` over `expectf` under `ODIN_TEST_THREADS=2` | **counts correctly** |
| `core:sync/atomic` | **does not exist** — it is `core:sync` (`atomic_add`, `atomic_load`) |
| nix sandbox: pty | **available** (`/dev/ptmx -> /dev/pts/ptmx`, `openpty` works) |
| nix sandbox: network | **NOT available.** Fixture/remote tests cannot run under `nix flake check`. |
| `nix flake check` today | passes **vacuously** (no `checks` output); under pure eval fails on devenv (pre-existing, out of scope) |

## EXACT `core:testing` SURFACE (Odin dev-2026-10) — that's all there is

`expect(t, ok, msg, expr)` · `expectf(t, ok, fmt, ..args)` · `expect_value(t, value, expected)`
(generic, comparable, nil-aware) · `fail(t)` · `fail_now(t, msg)` · `failed(t)` (from `error_count`) ·
`cleanup(t, proc, user_data)` (LIFO, runs after a fault, must itself never fault) · `expect_leaks` ·
`expect_assert_from/message` · `expect_signal(sig)`.
**Absent:** `expect_eq/ne/lt/le/gt/ge`, `expect_str_contains`, `expect_match`, **any skip mechanism**,
**any per-assertion count in output**. Signature is `proc(t: ^testing.T)`; attribute is `@(test)`.

## DIRECTORY OWNERSHIP — one writer per directory, no exceptions

| Agent | Writes | Never touches |
|---|---|---|
| **S** | `tests/support/**`, `tests/tools/**`, `tests/parity.tsv`, `src/ui/text.odin`, `src/ui/keyhints.odin`, `nix/**`, `flake.nix`, `src/main.odin` | `tests/pty/**`, `tests/unit/**`, `tests/it/**` |
| **P** | `tests/pty/**` | everything else writable |
| **U1** | `tests/unit/state_*.odin`, `tests/unit/app_*.odin`, `tests/unit/fetch_unit*.odin` | other agents' dirs |
| **U2** | `tests/unit/render_*.odin`, `tests/unit/wire_*.odin` | ″ |
| **U3** | `tests/unit/ui_*.odin`, `tests/it/tui_*.odin` | ″ |
| **U4** | `tests/unit/theme_*.odin`, `tests/unit/seam_*.odin`, `tests/it/live_*.odin`, `tests/it/disc_*` | ″ |
| **U5** | `tests/it/handoff_*.odin`, `tests/it/resize_*.odin`, `tests/it/probes/**` | ″ |

**If you need a change in a directory you do not own, file a request. Do not edit.** Uncoordinated edits
to `tests/support/` or `tests/pty/` are how suites quietly stop asserting the same thing.
**Never `git add -A`** — stage only your own paths.

---
---

# LANE S — Support, gate, product re-homes, wiring (SERIAL spine)

---

### T0 — Freeze the baseline. Nothing moves until this is done.

**Owner:** S · **Depends on:** nothing · **Blocks:** EVERYTHING

**✅ STATUS: CLOSED — fully measured, fixture-armed, `ALLOW_SKIP=0`. Nothing owed. Suite ports may start.**

All eight suites were run armed (`localhost` + `127.0.0.1` loopback ssh, `192.0.2.201` unreachable) with
**zero skips**, and the real config md5 + live session set were verified untouched across the whole run.
**Corrected authoritative total: 1544 PASS / 0 FAIL / 0 SKIP.** See `baseline-measurement.md`.
Do **not** use the inherited `1461` — it understated `ui` by 78 and was internally inconsistent by 5.

**Create:** `tests/parity.tsv` — the single source of truth for before/after counts.

1. `git status` must be clean. Build fresh: `dev/local-build.sh` (or `nix build`), export `BIN=`.
2. Arm the fixture and run **all eight** existing suites once, collecting per-suite `[PASS]` totals:
   `state · app+disc · tui · theme · resize · ui · render · handoff`.
3. **Reconcile against the corrected measured baseline (1544)** — `state 259 · app+disc 532 · tui 172 ·
   theme 171 · resize 138 · ui 168 · render 69 · handoff 35`. If a figure differs from these, **stop and
   explain before proceeding.**
   **DONE:** armed run complete. Seven of eight suites matched their recorded figures exactly; `ui` was
   corrected 90 → **168**, and the recorded total's 5-off arithmetic slip was explained (components sum
   to 1466, not 1461). No coverage was ever lost — the numbers were just mis-added and stale.
4. For each suite, also record the **tier split** — how many assertions are *hermetic* (no network, no
   ssh, no remote fixture) vs *fixture-required*. This split determines what `nix flake check` can
   honestly run (nix sandbox has a pty but **no network** — verified).
5. Record the **frozen timing thresholds** verbatim from `dev/*.py` so a later widening is visible:
   paint ≤ 4/5/6 s · idle ≤ 2 clock ticks over 5 s · resize first repaint < 500 ms · `working:` < 1 s
   after Enter · dead-host verdict ≤ 6.5 s · `delete_notice` gap ≥ 2.0 s and < 12 s ·
   `resize_latency` timeout 2 s.

**Schema for `tests/parity.tsv`:**
```
suite	tier	floor_before	pass_after	fail_after	skipped	notes
state	hermetic	259			T6	100% hermetic
render	hermetic	69			T7	100% hermetic
ui	hermetic	168			T8	100% hermetic (NOT the stale 90)
theme	hermetic	171			T9	100% hermetic
handoff	hermetic	35			T11	100% hermetic
app	hermetic	444			T10	532 armed - 88 fixture - 7 diag_head transferred
app	fixture	88			T14	app-live + fetch-live + discriminator
diag	hermetic	7			T2	transfer from app (ISC-9)
tui	hermetic	145			T12	boot-local/state-*/del-key/guards
tui	fixture	27			T14	boot-remote + roundtrip
resize	hermetic	123			T13	4 scenarios x 3 reps
resize	fixture	15			T14	selection-shrink x 3 reps
# hermetic sum = 1414 ; fixture sum = 130 ; armed total = 1544
```

**Acceptance:** `parity.tsv` exists with all 8 suites + tier split + frozen thresholds, and the before
column sums to 1544 (or the difference is explained in a note). *ISC-7*

**Anti-patterns:** trusting a `grep -c` of static `check()` callsites as a baseline (**loops multiply at
runtime** — `state_cases.odin` is 139 static callsites → 198 runtime lines). Trust only a real run.

---

### T1 — Support layer: ledger, tally, fixture, scratch, format guard

**Owner:** S · **Depends on:** T0

**Create:** `tests/support/ledger.odin`, `tests/support/scratch.odin`, `tests/support/env.odin`,
`tests/support/fmtguard.odin` — all `package support`.

The ledger is what makes assertion count **observable**. `core:testing` reports tests, not assertions;
without this, parity is unfalsifiable — the exact condition under which drops go unnoticed.

```odin
package support

import "core:testing"
import "core:fmt"
import "core:sync"

pass_n : int = 0
fail_n : int = 0
skip_n : int = 0

// check is the one assertion primitive. It wraps testing.expectf so core:testing owns the
// pass/fail verdict, AND emits a machine-countable line so the outer gate can count ASSERTIONS.
check :: proc(t: ^testing.T, name: string, cond: bool, detail: string) {
	if cond {
		sync.atomic_add(&pass_n, 1)
		fmt.println("[HS] PASS {s} {s}", name, detail)
	} else {
		sync.atomic_add(&fail_n, 1)
		fmt.println("[HS] FAIL {s} {s}", name, detail)
	}
	testing.expectf(t, cond, "{s} — {s}", name, detail)
}

// skip records a check that did NOT run. Skipping is not passing: the gate fails on a
// non-zero skip count unless it was explicitly declared optional.
skip :: proc(t: ^testing.T, name: string, reason: string) {
	sync.atomic_add(&skip_n, 1)
	fmt.println("[HS] SKIP {s} — {s}", name, reason)   // reason must be a sentence
}

// tally_line is the last thing a suite binary prints. The gate parses it; absence == failure.
tally_line :: proc(suite: string) {
	fmt.println("HS_TALLY {s} pass={d} fail={d} skip={d}",
		suite, sync.atomic_load(&pass_n), sync.atomic_load(&fail_n), sync.atomic_load(&skip_n))
}
```

**Rules:**
- Every assertion in every migrated test goes through `support.check` (or a helper built on it).
  Never call `testing.expect` bare for something that must be counted.
- `note()` replaces `say()` → `log.info`. **Evidence lines must still reach the transcript**; verify
  against `ODIN_TEST_LOG_LEVEL`.
- `scratch.odin` owns the `hs-t-*` lifecycle. **Teardown as `defer`, never as a trap.** It must also
  snapshot the herdr session list before and assert it restored after — that round-trip is itself a
  counted assertion in today's suites.
- `env.odin`: `base_env()` strips every `HERDR_*` from a child env, merges the scenario's extras,
  forces `TERM=xterm-256color` when unset. (Mirror of `dev/tui_drive.py:416-427`.)
- `fmtguard.odin`: a `%!` scanner. This catches a bug class caught **twice** before — a mistyped format
  verb producing a plausible line whose NUMBERS are wrong. Do not retire it silently.

**Existing references:** `src/main.odin:50` (`say`), `:58` (`check`), `dev/lib.sh:47` (`tally`),
`:87` (`classify_log`), `:105` (`skip`), `:116` (`assert_formatted`), `dev/app_cases.odin:61` (`say_raw`).

**Acceptance:** a trivial 2-test package that uses `check` twice + `skip` once produces
`HS_TALLY <suite> pass=2 fail=0 skip=1`. *ISC-11, ISC-12, ISC-13*

---

### T2 — Product re-homes: `diag_head` and the footer hint tables (PRODUCT CHANGE)

**Owner:** S · **Depends on:** T1 · **Blocks:** U1, U3 (their suites import these)

These are the **two HARD blockers** — product symbols trapped in `package main`, unreachable from
`tests/`. Leaving them means silently deleting their proofs. **Treat this as a product change with its
own tests, not as test plumbing.**

**Create:** `src/ui/text.odin` (package `ui`) and `src/ui/keyhints.odin` (package `ui`)
**Modify:** `src/main.odin` (`diag_head` deleted, `KEYS_*` deleted, `tui_key_hints` delegates)

```odin
// src/ui/text.odin — package ui
// Moved verbatim from src/main.odin:963-975. KEEP THE NAME — the value is the location, not a rename.
// Live caller: main.odin:949 (tui_host_line). It must keep working unchanged.
diag_head :: proc(s: string, max: int) -> string
```

```odin
// src/ui/keyhints.odin — package ui
// All seven tables from src/main.odin:1162-1212. Key_Hint is already ui's type (frame.odin:198).
key_hints_for :: proc(state: app.State) -> []Key_Hint
```

⚠️ **Import cycle watch:** `src/ui/*` currently imports `app` (`import app "../app"`) and `app` imports
`input`/`terminal` — **`app` does not import `ui`.** So `key_hints_for(state: app.State)` in `ui` is
fine. Verify before committing. If the signature in `main.odin:1145-1160` keys off something other than
`app.State`, match it — read the actual dispatcher first.

**Also required:** `enter_terminal`/`leave_terminal` (`main.odin:125,137` — `tb_init` +
`OUTPUT_TRUECOLOR` + `tb_hide_cursor`) are needed by `render_cases` (×4 pairs) and `ui_cases`
(`bring_up` :181). Move them to a shared support location (`tests/support/terminal.odin`) — **not** to
`ui` (they are test scaffolding, not product).

**Own tests (new, in your lane):**
- `tests/unit/diag_*.odin` — port the 7 truncation assertions from `src/app_cases.odin:1046-1099`
  (`unit_diag_head`): short line passes through · only the first line of a multi-line trace · CRLF
  handled like LF · the 44-byte-cap-yields-47-bytes contract (`…` is 3 bytes) · never cut after a UTF-8
  continuation byte (`head[cut-1] & 0xc0 == 0x80`) · never leave a continuation byte at the end.
- `tests/unit/keyhints_*.odin` — every state returns a non-empty table · no duplicate key label ·
  the 80/100-col overflow behaviour from `src/ui_cases.odin:505-532` preserved (theme and quit are the
  LAST hints to go, guarded by `ui.text_cols("t theme") + 2 + ui.text_cols("esc quit")`).

**Parity, said out loud:** 7 assertions **transfer from `app` hermetic (444→437) to `diag` (0→7)**. Record both
rows in `parity.tsv`. Total unchanged. *ISC-9, ISC-10*

**Anti-patterns:** deleting the tests because the symbol is hard to move (**ISC-A-1**). Renaming for
taste. Turning `enter_terminal` into product code.

---

### T15 — nix wiring: a separate test derivation + `checks` outputs

**Owner:** S · **Depends on:** T1..T14 (land incrementally; wire early, verify at the end)

**Modify:** `nix/package.nix` (**product filter UNCHANGED** — `nix/package.nix:26-33`), add
`nix/tests.nix`. **Modify:** `flake.nix` to add a `checks` output for `linuxSystems`.

**There is no check phase today.** `nix flake check` currently passes vacuously. This is net-new wiring.

Three facts that must stay distinct or you will block yourself:
- The **product** derivation ships `src/` + `vendor/` only. **Do not change that filter's semantics.**
- The **test** derivation needs a **wider** source view — `tests/` + `src/` + `vendor/`. That is its
  own `src = lib.cleanSourceWith { ... }`, a different derivation. RCH-7's pin does **not** forbid it.
- The nix sandbox has **a pty but no network** (verified). Fixture/remote tests physically cannot run
  in-sandbox. Two attributes, not one honest-looking lie:

```nix
# nix/tests.nix — sketch. NOT copy-paste; adapt.
# odinTests      : hermetic tier, runs in the sandbox, gate enforces zero skips
# odinTestsFull  : __noChroot = true, needs the fixture env passed through — the real 1544 gate
checks = { odinTests = odinTestsDrv { }; odinTestsFull = odinTestsFullDrv { }; };
```

**You MUST repeat the archive staging verbatim** (`nix/package.nix:38-51`). Clay's Odin binding hard-codes
`foreign import Clay "linux/clay.a"` resolved **relative to `clay.odin` itself**:
```bash
mkdir -p clay-odin/linux
cp ${clay-src}/bindings/odin/clay-odin/clay.odin clay-odin/clay.odin
cp ${clay}/lib/libclay.a clay-odin/linux/clay.a
mkdir -p vendor/termbox2-odin/lib
cp ${termbox2}/lib/libtermbox2.a vendor/termbox2-odin/lib/libtermbox2.a
```
Build with **`-build-mode:test`** (verified working), not `odin test` — you need a real artifact to run
per-suite with its own `ODIN_TEST_JSON_REPORT`:
```bash
odin build tests/unit -build-mode:test -out:hs-unit -o:speed -vet \
     -define:ODIN_TEST_THREADS=1 \
     -define:ODIN_TEST_JSON_REPORT=$NIX_BUILD_TOP/report-unit.json \
     -extra-linker-flags=-Wl,--library-path,/
```
`--library-path,/` is mandatory, not cosmetic (the nix cc-wrapper drops a bare `-L/`; verified
`-Wl,-L/` fails, `-Wl,--library-path,/` links).

**Freshness:** under nix the derivation *is* the freshness guarantee — mtimes are epoch-sentinel
(`REPRODUCIBLE_MTIME_MAX = 1262304000`, `dev/lib.sh:188`) and `require_fresh_bin` is intentionally a
no-op. **State this explicitly in the derivation comment and in the README.** Keep `require_fresh_bin`
as a **local-only** check in `hs_check`.

**Known non-test blocker:** pure-eval `nix flake check` fails on devenv (`devenv was not able to
determine the current directory`) — pre-existing, out of scope. Workaround: target the attribute
directly (`nix build .#checks.x86_64-linux.odinTests`). Record it; do not try to fix devenv.

**Acceptance:** `checks.<sys>.odinTests` builds and runs the hermetic tier; make it fail once by
temporarily emptying a package, proving it is **not vacuous**. *ISC-6, ISC-A-4*

---

### T16 — Delete the `argv[1]` test dispatch from `main`

**Owner:** S · **Depends on:** T6..T15 **all green.** Strictly cannot go earlier — the dispatch is the
old harness's entrypoint.

**Modify:** `src/main.odin`

**Delete (audit each with `grep -rn` first — nothing may still reference it):**
- The `switch name` block at `main.odin:1562-1598` and the `name := "tui"` default branch scaffolding.
- `usage()`'s case list (`main.odin:1450`) — the whole smoke-driver usage text.
- Every `case_*` proc: `case_probe` (164), `case_double` (184), `case_handoff` (211), `case_child`
  (258), `case_sig_term` (280), `case_guard_attach` (1504), `case_guard_delete` (1521), plus the
  `measure/app-unit/app-live/fetch-unit/fetch-live/render/theme-set/theme-resolve/config-parse/
  config-save/config-live/colour-wire/clip/clay-error/layout-dump/ui-*/state-*` handlers, and
  `guard_probe_rows` (1497), `home_dir` (299).
- The Phase-1 smoke painter: `paint`/`draw_box`/`draw_text` (`main.odin:78-119`), `force_repaint` (118),
  `FRAMES_PAINTED` (78).
  ⚠️ **Only if** the test binary registers **its own** repaint hook (see `tests/support`'s
  `terminal.set_full_repaint(hs_repaint_hook)` and the test-owned `FRAMES_PAINTED` counter).
  A test that still leans on `main`'s paint path is a hidden dependency — find it first.

**MUST STAY — this is product wiring, not test scaffolding:**
`main()`, `tui_run`, `tui_loop`, `tui_paint`, `Tui` struct (330), `tui` global (384), event plumbing
(`tui_take_event`, `tui_lost_terminal`, `TUI_LOST_TERMINAL` 1301, poll counters 1305-1311),
`tui_state_text`/`tui_host_line`/`tui_list_age`/`tui_source_line`, `TUI_ACTIVE` + `tui_repaint_hook`
(1539-1546), `tui_discover` (460), `write_pidfile` (141),
`install_terminal_restore_handlers()` (1551), `tui_dump_trace` (1252), boot timers (1410-1414),
and the **declared dev seams** — `tui_fixture_remotes` (443), `HS_TUI_TRACE`, `HS_PIDFILE`.

**Decision on the seams (already made — do not re-litigate):** the fixture seams **stay** in the product
as **documented developer seams**. Reason: the alternative (temp `XDG_CONFIG_HOME` + a real config file)
**moves herdr's own state dir** and empties `herdr session list`, destroying the fixture path. They are
injection points the product legitimately owns, not test code. **Conditions:** inert by default
(asserted in `seam_test.odin`), additive only, documented in the README under "Developer seams" with
the RCH-3 trap spelled out, and covered by the anti-criteria grep so they cannot leak elsewhere.

**Acceptance:** `grep -n "switch name" src/main.odin` → nothing; a bare `nix run .` still launches the
TUI; the full hermetic suite passes against the rebuilt product. *ISC-1*

---

### T17 — Delete every test `.sh` and `.py` (LAST. Never before T16.)

**Owner:** S · **Depends on:** T14, T15, T16 all green

**Delete:** `dev/app-smoke.sh` `dev/state-smoke.sh` `dev/render-smoke.sh` `dev/handoff-smoke.sh`
`dev/ui-smoke.sh` `dev/theme-smoke.sh` `dev/tui-smoke.sh` `dev/resize-smoke.sh` `dev/lib.sh`
`dev/tui_drive.py` `dev/resize_drive.py` `dev/theme_drive.py` `dev/device_discriminator.py`
`dev/stream_order.py` · plus `dev/__pycache__/`.

**`dev/local-build.sh` STAYS** — it is a build helper, not a test (RCH-6 explicitly out of scope).
`dev/*.md` stay (docs/transcripts). `nix/*`, `flake.*`, `vendor/**` stay.

⚠️ **THE EASIEST THING TO MISS:** `sig_probe.py` and `env_probe.sh` are **heredocs written at runtime**
by `dev/handoff-smoke.sh:37-81`. Deleting `dev/*.py` does **not** remove them. They are retired only
when **T11** has ported them to Odin probe binaries. Verify the port landed first.

**grep-verifiable gates (run all four, record the output):**
```
find . -name '*.py' -not -path './vendor/*'          → nothing
git ls-files 'dev/*.py'                             → nothing
ls dev/*-smoke.sh dev/lib.sh 2>/dev/null           → nothing
grep -rn "sig_probe\|env_probe" dev/                → nothing (the heredocs are gone)
```
*ISC-2, ISC-3, ISC-A-7*

---

### T18 — Final honest report

**Owner:** S · **Depends on:** T17

Fill `tests/parity.tsv`'s after columns and produce the before/after table in the plan directory.
Report the honest new total vs **1544**, per suite, with **every** delta explained as a recorded
transfer or flagged as a regression. **A drop is a regression, said out loud — not a green suite.**

---
---

# LANE P — The pty core (SERIAL within the lane: T3 → T4 → T5)

---

### T3 — Pty FFI + the width-parity table

**Owner:** P · **Depends on:** T1 · **Blocks:** T4, and **every rune/character assertion anywhere**

**Create:** `tests/pty/ffi.odin`, `tests/pty/width_test.odin` — `package pty`

`core:sys/posix` has **no** `openpty`, `forkpty`, or `ioctl` (verified). Declare them by hand.
**Precedent to follow:** `src/ui_cases.odin:340-354` (`Win_Size`, `TIOCSWINSZ = 0x5414`,
`foreign import odin_c "system:c"`).

```odin
package pty

import "core:c"
import "core:sys/posix"

Win_Size :: struct { rows, cols, xpixel, ypixel : u16 }   // mirrors struct winsize

TIOCSWINSZ : c.ulong = 0x5414
TIOCSCTTY  : c.ulong = 0x540E     // NOT in core:sys/posix — declare it

foreign import odin_c "system:c"

@(default_calling_convention = "c")
foreign odin_c {
	openpty  :: proc(master: ^c.int, slave: ^c.int, name: ^c.char,
	                termp: ^posix.termios, winp: ^Win_Size) -> c.int ---
	// Renaming a C symbol REQUIRES @(link_name). The `--- "ioctl"` form is a SYNTAX ERROR.
	@(link_name="ioctl")
	ioctl_ws :: proc(fd: c.int, request: c.ulong, arg: ^Win_Size) -> c.int ---
}
```

**Verified working in this exact toolchain** (probe output): `openpty rc=0 master=3 slave=4`,
`ioctl TIOCSWINSZ rc=0`, `tcgetattr rc=0`, and after the child died
`slave termios still readable rc=0 same_lflag=true`. **That last line is the entire
SIGTERM-restores-the-tty proof mechanism — the parent keeps the slave open on purpose.**

**Everything else already exists in `core:sys/posix`:** `fork` (`unistd.odin:338`), `setsid` (819),
`dup2` (181), `execve` (290), `waitpid`, `kill`, `tcgetattr` (`termios.odin:69`), `tcsetattr` (92),
`poll` (`poll.odin:25`), `WIFEXITED`/`WEXITSTATUS`/`WIFSIGNALED`/`WTERMSIG` (`sys_wait.odin:92-108`).

**Width parity — do this BEFORE any character assertion exists.**
Python used `unicodedata` (combining / `Mn,Me,Cf` → 0; `east_asian_width` W,F → 2; else 1).
Odin uses **`termbox2.tb_wcwidth`** — the width authority the **product itself** uses
(`src/render/measure.odin:127`; `main.odin:166-176` asserts `tb_wcwidth('A')==1`, `U+4E00==2`).
Adopting it removes a Python-vs-app discrepancy, **but it is not an exact match on some combining
marks** and a width change silently changes what whole-rune-deletion evidence means.

```odin
// tests/pty/width_test.odin
// Freeze EVERY rune the old Python drivers could reach, then assert tb_wcwidth agrees with the
// recorded Python value. Start from the existing table at src/render_cases.odin:178-190
// (MEASURE_CASES) and ADD the del_key / ui-edit runes: 'a世b😀c', U+4E16 世, U+1F600 😀,
// U+0301 combining acute, U+0301 U+0301 stacking, U+00E9 precomposed, and every other
// combining mark reachable in the del-key scenarios.
Width_Case :: struct { r : rune, want_python : int, want_tb : i32, note : string }
```

**If any rune disagrees: STOP.** Record the exact runes and escalate to T12 (which ports `del_key`)
before that suite is written. Do not paper over it and do not change a product assertion to match.

**Acceptance:** FFI compiles and runs under `-build-mode:test`; the width table is complete and
green, or every mismatch is listed and escalated. *ISC-16*

**Anti-pattern:** inventing your own width function. Using `unicodedata`-shaped logic by hand.

---

### T4 — The Screen emulator, ported. With its own tests.

**Owner:** P · **Depends on:** T3 · **Blocks:** every pty assertion in T11, T12, T13, T14

**Create:** `tests/pty/screen.odin` + `tests/pty/screen_test.odin`

> **THE HARD RULE: the `Screen` emulator must be PORTED, not avoided. A byte-grep replacement of the
> screen-scraping assertions is a REGRESSION.** The scout's line, and it stands.

**Why (port this reasoning into the file header — `dev/tui_drive.py:55-76`):** termbox's renderer emits
a **CELL DIFF** — it cursor-addresses and writes only the characters whose cell actually changed.
Grepping the raw byte stream for `"delete_session"` therefore **FAILS on a correct render** (the `e` at
column 4 was already `e`, so nothing was sent — the word arrives as `delte_sss`). That failure mode is
worse than a red suite: it is a **green suite on code that never painted.** The harness keeps a
cursor + grid updated from the same bytes the terminal sees, and asserts on **what a user would read.**

**Port these, exactly:**
- **Incremental UTF-8 with a carry buffer** (`core:unicode/utf8`) — a rune split across two `read()`s
  must not corrupt the grid. *(Python used `codecs.getincrementaldecoder("utf-8")(errors="replace")`.)*
- **Escape families:** `CSI` · `OSC … BEL` · `ESC ( X` · `ESC ) X` · `ESC # 8` · a generic 2-byte
  fallback. The missing `ESC ( B` is a **real bug this code records**: it smeared `"(B"` into the grid
  and turned `delete_session` into `delete_sess(Bn`. Keep the fallback broad.
- **CSI verbs:** `H`/`f` (abs pos) · `A/B/C/D` (relative) · `d` · `` ` `` · `J`(0/2) · `K`(0/1/2).
  SGR (`m`) and all DEC-private (`?`) modes are **ignored for content**.
- **Control chars:** `\r`, `\n`, `\b`, `\t` (+8).
- **Wide-char placement:** a width-2 glyph **blanks the following cell** (mirror
  `dev/tui_drive.py:96-107 _put`, using `tb_wcwidth` from T3).
- `screen_contains(s)` / `cell(r,c)` / `row_text(r)` accessors for assertions.

**The emulator's OWN unit tests must land here, before any integration suite uses it** — feed byte
strings in, assert the grid out. Minimum cases:
1. A UTF-8 rune **split across two writes** at every possible byte boundary → correct single cell.
2. `ESC ( B` and `ESC ) 0` must not smear into the grid.
3. `OSC 0;title BEL` must not appear on the screen.
4. Wide glyph at column N blanks column N+1; the next write lands at N+2.
5. A diff-style stream (cursor-jump + one char) reconstructs the full row.
6. `J2` clears; `K0/K1/K2` behave per spec; `H` and `f` are the same verb.

**Acceptance:** all emulator tests green. **Do not proceed to integration pty work until this is
proven** — every downstream assertion inherits its correctness. *ISC-A-3*

**Anti-pattern:** writing the emulator and testing it only through the full app. Testing it only on
"ASCII renders fine".

---

### T5 — The Pty driver: spawn, observe, measure

**Owner:** P · **Depends on:** T4 · **Blocks:** T11, T12, T13, T14

**Create:** `tests/pty/driver.odin` — `package pty`

Port `dev/tui_drive.py:201-427` (`Pty` + `base_env` + `herdr_cli`). One spawn, one verdict per scenario.

**Spawn (`Pty.__init__`, `tui_drive.py:201-241`) — the parent MUST keep the slave open on purpose.**
It is the only way to `tcgetattr` the terminal's termios **after the child dies** — the entire
SIGTERM-restores-the-tty proof. Sequence:
1. `openpty()` → `(master, slave)`; keep both open in the parent.
2. `TIOCSWINSZ` on the **slave** before spawn to fix initial geometry.
3. `tcgetattr(slave)` snapshot **before** spawn = the round-trip reference.
4. `fork()` → child: `close(master)` → `setsid()` → `ioctl(slave, TIOCSCTTY, 0)` →
   `dup2(slave, 0/1/2)` → close slave if > 2 → optional `chdir` → `execve(BIN, [BIN]+args, env)`.
   On failure: write to stderr, `_exit(127)`.

**Observe / measure — these shapes are load-bearing, port them exactly:**

| Method | Source | Why the shape matters |
|---|---|---|
| `read(wait=0.2)` | `:245-268` | `posix.poll` on master, `read(65536)`, timestamps each burst `(t_rel, bytes)`, feeds the `Screen`, accumulates `raw` |
| `wait_screen(needle, timeout, pump)` | `:270-281` | Returns when the needle first appears **on the modelled screen**, not in the byte stream |
| `watch_screen(labels, timeout, pump)` | `:283-298` | **Concurrent** first-seen times for N labels. Sequential `wait_screen` calls "timestamp the look, not the arrival". **Keep the pending-set shape or timing evidence is meaningless.** |
| `resize_latency(rows, cols, timeout)` | `:305-318` | Time to the **first byte** of the repaint after `TIOCSWINSZ`. Measuring the window instead of the arrival reported our own timeout as app latency |
| `resize()` | `:320-325` | `TIOCSWINSZ` on the **master** → kernel SIGWINCH → termbox self-pipe |
| `written` counter | — | Bytes **we** sent. Proof that no key was pressed (ISC-13) |
| `alive()` / `exit_info()` / `kill()` | `:331-353` | `waitpid(WNOHANG)`; `exit_info` renders `128+N (killed by N)` |
| `cpu_ticks()` | `:355-366` | `/proc/<pid>/stat` utime+stime, **indexed from the END of the field list** — `comm` may contain spaces |
| `termios_now()` | `:368` | `tcgetattr(slave)` — must work after the child died |
| `herdr_cli()` / `session_names()` | `:379-414` | Scrubs `HERDR_ENV`/`HERDR_SESSION`/`HERDR_SOCKET_PATH`, shells `herdr session list --json`. **`app.run_capture(argv, timeout)` (`src/app/herdr.odin:298`) already implements this same parent-resolve-then-exec + capture contract and is importable.** Use it. `core:encoding/json` covers the parse |

**The driver binary must be single-threaded for timing tests.** Build the pty suite with
`-define:ODIN_TEST_THREADS=1`. `core:testing`'s default is core-count, which makes `boot ≤ 4 s`,
`idle ≤ 2 ticks`, `resize < 500 ms`, `< 1 s before the working frame` competitively flaky — and the
predictable response to flakiness is loosening the numbers, which is a silent loss.

**Also verify (R-8 risk):** `core:testing` installs its own SIGTERM/SIGINT/SIGSEGV/SIGTRAP handlers.
Our harness sends signals to the **child**, not the test — but confirm the runner's handler setup does
not interfere with `kill(-pgid)` before trusting a handoff/signal assertion.

**Acceptance:** a smoke test spawns `BIN tui` in a pty, resizes it, kills it with SIGTERM, and asserts
termios matches the pre-spawn snapshot — all from the parent, after the child is dead.
*ISC-5*

---
---

# LANES U1–U5 — Suite ports (PARALLEL across lanes; within a lane, follow the stated order)

Every suite port follows the same contract:

1. Read the existing suite's `.sh` **and** its `src/*_cases.odin` to learn the assertion inventory.
2. Port **one case at a time**; count assertions before and after each one.
3. Run **your** suite against a fresh build with explicit `BIN=`. Verify you meet the floor.
4. Update your rows in `parity.tsv` (via a request to S if you cannot write it).
5. Commit. **Do not delete the old files** — that is T17.
6. **Floor not met = regression = say it out loud in the commit message.**

**Uniform gate rules you must satisfy even though the old suite did not** (this is the approved
tightening — `render`/`ui`/`theme`/`state` today have no zero-assertion rule and no freshness gate;
those holes are NOT portable):
- registered tests > 0 (else hard failure)
- no `[FAIL]` · no `[SKIP]` unless declared with a sentence-reason
- `pass >= floor` · no `%!` in any log

---

### T6 — Suite: `state` (floor 259)

**Owner:** U1 · **Depends on:** T2 · **Source:** `dev/state-smoke.sh` + `src/state_cases.odin`

- `state-machine` → port `case_state_machine` (`state_cases.odin:240`): the full (state × key) grid
  printed to the transcript, each rule asserted.
- `state-offline` → port `case_state_offline` (`state_cases.odin:1347`), run under
  `env -i PATH=/nonexistent HERDR_ENV=1` (mirror `state-smoke.sh:96`).
- **Source-surface greps** (`state-smoke.sh:115-165`, `grep_absent` at 118): 12 checks over
  `src/app/state.odin` and `src/input/keymap.odin` with `//` comments stripped **first** via
  `sed 's,//.*,,'` — **or the prose about the rule becomes a rule violation.** No `core:os`, no
  `core:sys/posix`, no `core:net`, no `clay|termbox`, no `core:time|sleep|peek_event` (ISC-11: no
  Escape timeout exists), **no `union {`** (O10 tagged struct), no Kitty, no `os.|posix.|net.|open(|read(|write(` shape.
- Safety: real `herdr session list` byte-identical before/after.

**`any_failed` redesign (required here):** `case_state_offline` uses an explicit **save/restore** at
`state_cases.odin:1349-1358`. **Do NOT wrap it.** Split each sub-battery (`sm_reachability`,
`sm_two_step`, `sm_no_selection_noop`, `sm_ctrl_c_everywhere`, `sm_never_default`, `sm_empty_world`,
`sm_offline_proof`) into its own `@(test)` proc — `error_count` is per-test, so the merge becomes
unnecessary. Where a test genuinely needs "did **this inner block** fail, and let me continue":
`before := t.error_count; …block…; block_failed := t.error_count != before`. Cross-run verdicts belong
to the **outer gate**, which is strictly stronger because no earlier reset can erase it.

**Helpers port as-is:** `expect_state`/`expect_cmd`/`expect_noop` (`:220,225,232` — `expect_noop`
asserts BOTH halves: no command AND no state change) · `expect_cell` (`:400` — a **transition** cell,
not a screen cell) → compound `expectf(t, m.state == want && cmd.kind == want_cmd, …)`.

**Preserve (ISC):** O10 tagged struct · O11 guards + `ECHILD` · ISC-11 no Escape timeout ·
ISC-A-4 no Kitty protocol · D12/ISC-18 no Command ever targets `default`.

**Acceptance:** floor 259 met. Floor misses **named**, not summarised.

---

### T10 — Suite: `app` (hermetic floor **437** — tier split + transfer)

**Owner:** U1 · **Depends on:** T2, T6 · **Source:** `dev/app-smoke.sh` + `src/app_cases.odin`

**Parity, said up front:** `app+disc` **armed = 532** = **444 hermetic + 88 fixture-gated** (`app-live`,
`fetch-live`, `discriminator` — those belong to **T14**). Of the 444 hermetic, **7 transfer to `diag`** in
**T2**, leaving this suite a **hermetic floor of 437**. Record every row in `parity.tsv`:
`app hermetic 444→437` · `diag 0→7` · `app fixture 88`. **Transfers and a tier split, not a loss** — if
you cannot account for the 7 or the 88, stop. Record
both rows in `parity.tsv`. **This is a transfer, not a loss.** If you cannot account for the 7, stop.

- `app-unit` → `case_app_unit` (`app_cases.odin:69`).
- **Anti-criteria greps (22 counted checks)** — `app-smoke.sh:227-275`: `"herdr"` outside
  `src/app/herdr.odin` (1) · for each of 4 `PRODUCT_DIRS` (`src/app`, `src/render`, `src/terminal`,
  `src/main.odin`): `2>&1`, `localhost|127.0.0.1`, `core:thread`, `toml`, `kitty|\[>1u`
  (4×5=20) · "nothing hands `default` to a launch/attach builder" (1).
  ⚠️ **Driver files are deliberately EXCLUDED from these greps** (`app-smoke.sh:224-226`) because they
  legitimately construct the illegal inputs they assert against. Keep that exclusion or you fail on
  your own tests.
- **No regex exists.** Use `core:strings` `contains`/`has_prefix` for the literal patterns and
  `os.Walker` for traversal. **Strip `//` comments first.**
- Local `eq`/`eq_i`/`eq_int`/`ne_i`/`to_bytes`/`say_raw` (`app_cases.odin:35-61`) port unchanged.
- Note `app-smoke.sh` **overrides** `assert_formatted` and `tally` locally (lines 80, 99) with the
  older 2-counter versions and resets `PASS_TOTAL=0` — under the uniform gate this suite gets the
  **strong** rules instead. That is an intentional tightening.

**Acceptance:** hermetic floor **437** met, with the 7-assertion transfer and the 88-assertion fixture split both recorded. *ISC-7*

---

### T7 — Suite: `render` (floor 69)

**Owner:** U2 · **Depends on:** T2 · **Source:** `dev/render-smoke.sh` + `src/render_cases.odin`

- Cases: `measure` (offline) · `render` · `clip` · `clay-error` · `layout-dump`.
  ⚠️ `layout-dump` (`render_cases.odin:736`) is a **dump with ZERO assertions** — do not count it
  toward parity and do not port it "because it was a step" (R-14).
- **Back-buffer cell grid — no `core:testing` equivalent. Hand-roll.** `cell_at`/`glyph_at` read
  termbox's **back buffer** via `tb_get_cell(x, y, back=1, &ptr)` (`render_cases.odin:162-171`).
  Port `clay_start` (38), `Cell` (152), `dump_rows` (176-193), `render_and_present` (205),
  `find_text_loc` (221).
  > **The `dump_rows` transcript band is load-bearing evidence and must be kept deliberately.**
  > `core:testing` prints one line per failure and **no grid**. Without the bands, a future reader
  > cannot tell what was on screen. A port that asserts "no panic" instead of the exact
  > glyph+fg+bg triples **loses ~69 checks' worth of actual content while going green** (R-1).
- **Wire-level asserts:** port `expect_wire` (`render-smoke.sh:52`, calls at 85-94) as
  `expectf(t, contains(raw, pat), …)` over the accumulated buffer — truecolour SGRs
  (`38;2;255;60;60`), box-drawing `─ │ ┌`, CJK `中`, emoji `😀`, plus the **negative** check that
  no `ESC[38;5;` indexed-colour fallback appears (lines 96-102).
- The old `tally` (`render-smoke.sh:41-47`) has **NO zero-assertion rule** — the weakest gate of the
  eight. **You inherit the strong rule instead.** This is a deliberate net change.

**Acceptance:** floor 69, with grid dumps present in the transcript. *ISC-A-1, ISC-A-3*

---

### T8 — Suite: `ui` (floor **168**, NOT the stale 90 — 6 cases)

**Owner:** U3 · **Depends on:** T2 · **Source:** `dev/ui-smoke.sh` + `src/ui_cases.odin`

> **⚠️ THE FLOOR IS 168, NOT THE RECORDED 90** (confirmed by the armed run). Measured per-case (see `baseline-measurement.md`):
> `frame 92 · sessions 16 · shrink 12 · edit 20 · list 17 · float 11 = 168`.
> The recorded "90" had `frame 14` — it predates the RCH-1 no-outer-border geometry proofs and the
> `KEYS_MODE` footer-overflow checks, and was never updated. **Porting against a 90 floor would let 78
> assertions vanish while still reporting parity.** Confirm the exact armed numbers in T0, then hold
> yourself to them.

- 6 cases: `ui-frame` (389, **92 assertions**) · `ui-sessions` (635, 16) · `ui-shrink` (881, 12) ·
  `ui-edit` (994, 20) · `ui-list` (1219, 17) · `ui-float` (1338, 11).
- **`ui-frame`'s 92 must all survive** — it carries the RCH-1 proof set: divider span/purity, predicted-
  vs-Clay box equality, `exactly one border call registered as the divider source (RCH-1)`, palette
  opacity, `cell_error == 0`, and the footer `KEYS_MODE … never overflows / cuts no hint in half` checks.
  If your ported `ui-frame` comes in near 14, **you have lost the RCH-1 evidence.**
- **Keystroke feeding** (`ui-smoke.sh:38-45`): `{ sleep 1; input_for "$case"; } | script -q -e -c ...`
  The **1-second delay is load-bearing and documented** — termbox consumes pending bytes during
  `tb_init` (terminal identification responses), so t=0 input is **eaten**. Preserve the delay.
  Inputs: `ui-sessions`←`api` · `ui-edit`←`a世b😀c` · `ui-list`←`ESC[B ESC[B TAB to` · `ui-float`←`CR`.
- `bring_up` (`ui_cases.odin:181`) uses `enter_terminal` (moved in T2 to `tests/support/terminal.odin`)
  + `ui.painter_start`. `shrink_pty` (356) + `Win_Size`/`TIOCSWINSZ`/`foreign ioctl` (340-354) —
  the FFI precedent for T3.
- **The footer-overflow checks at `ui_cases.odin:505-532` now target `ui.key_hints_for()` / the moved
  tables (T2), not `KEYS_MODE` in `main`.**
- The old pass rule (`ui-smoke.sh:48`) accepts `RESULT: PASS` with **zero `[PASS]` lines** as a green
  "(0 checks)" case. **Not portable.** Strong rule instead.

**Acceptance:** floor **168** across all 6 cases, each individually at its measured count
(92/16/12/20/17/11) — **per-case, not just the total**, so a loss in one case cannot be hidden by a gain
in another. *ISC-A-1*

---

### T9 — Suite: `theme` (floor 171)

**Owner:** U4 · **Depends on:** T2 · **Source:** `dev/theme-smoke.sh` + `src/theme_cases.odin`

- In-proc cases: `theme-set` (141) · `theme-resolve` (253) · `config-parse` (329) · `config-save`
  (453) · `config-live` (618) · `colour-wire` (711).
- **Hygiene block (`theme-smoke.sh:58-133`) — must survive verbatim:**
  - real `~/.config/herdr_session.json` **md5 before == after** (RCH-18 / XDG discipline)
  - `XDG_CONFIG_HOME` did **not** leak into the caller
  - no TOML in non-comment `src/` lines (**strip `//` comments first** — the TOML grep at 101 does)
  - no XDG library import · no `localhost` in `src/` · temp-dir accounting under `/tmp/hs-t6-*`
- The old `record()` (line 27) treats **0/0 as not-failed**, so a case emitting nothing never enters
  `CASES_FAILED` → green with zero checks. **Not portable.** Strong rule instead.
- ⚠️ Do **not** move `XDG_CONFIG_HOME` in a way that **relocates herdr's own state dir** — that empties
  `herdr session list`. Isolate *our* config with the per-test config paths the suites already pass to
  `config_parse_json`/`config_save_*`, and fingerprint the real file before/after either way.

**Acceptance:** floor 171 with every hygiene check ported. *ISC-A-1, ISC-18*

---

### T18b — Seam inertness test (small, do alongside T9)

**Owner:** U4 · **Depends on:** T2

**Create:** `tests/unit/seam_test.odin`

Asserts the **decided trade-off** (plan B4) that the developer seams left in the product binary are safe:
- With **no** `HERDR_SESSION_TEST_*` set → `tui_fixture_remotes()` returns an **empty** set.
- With no `HS_TUI_TRACE` → **no trace file is written**; with no `HS_PIDFILE` → **no pidfile**.
- The seams are **additive only** — they may add remotes, never alter or remove a configured/real host.
- Anti-criteria grep: the seam symbols are referenced only from their intended product path.

Document the decision inline: *removing these seams would destroy the fixture path, because the
alternative (temp `XDG_CONFIG_HOME`) moves herdr's own state dir and empties `herdr session list`.*
(Recorded in `../2026-10-18-herdr-session-tui/60-handoff-notes.md`, commit `5e84fae`.)

**Acceptance:** seams proven inert by default. *ISC-18*

---

### T11 — Suite: `handoff` (floor 35) + the Odin probe binaries

**Owner:** U5 · **Depends on:** T5 · **Source:** `dev/handoff-smoke.sh`

**⚠️ THE SINGLE EASIEST THING TO MISS IN THIS ENTIRE MIGRATION (R-8).**
`env_probe.sh` and `sig_probe.py` are **heredocs written at runtime into `$OUT/probes/`** by
`dev/handoff-smoke.sh:37-81`. **Deleting `dev/*.py` does not remove them.** The SIGINT-to-process-group,
`SigBlk` mask, `HERDR_*` scrub, pgroup and cwd proofs must be re-expressed as **Odin probe binaries**
under `tests/it/probes/`, or those three handoff checks vanish silently and the suite still goes green.

**Create:** `tests/it/probes/env_probe.odin` · `tests/it/probes/sig_probe.odin` (each its own
`package main`, built as a separate binary and spawned by the suite exactly where the shell spawned the
scripts).

**Cases to port** (`handoff-smoke.sh:133-205`): `probe` (offline) · `double` · `handoff` (child
`sleep 2`, post-handoff key fed at +4 s) · `child $HOME sh -c 'exit 7'` (exit-code propagation) ·
`child … env_probe` · `child … sig_probe` (SIGINT to the **process group** while the child owns the tty)
· `sig-term` looping `TERM` and `HUP` with expected **143/129**.

**`check_stty` (line 86)** — the termios round-trip assertion (`stty -a` before == after) for every
`run_pty` case. Verdicts go to a **separate `$STTY_LOG`** and are tallied **once** at the end (line 250)
to avoid double counting. Preserve that separation.
SIGTERM/SIGHUP (`for SIG in TERM HUP`, line 205) add **3 counted checks each** (exit code, `?1049l`
present, termios unchanged) — lines 227-245.

**Repaint hook (B5 — required):** `case_handoff` asserts `FRAMES_PAINTED >= 1` (`main.odin:227`) and
`case_child` likewise (272). Your test binary must register **its own** hook via
`terminal.set_full_repaint(hs_repaint_hook)` with a **test-owned** `FRAMES_PAINTED` counter, and must
**never** call `tui_paint` or set `TUI_ACTIVE`. `terminal.set_full_repaint` is a single slot
(`src/terminal/handoff.odin:54`) — do not piggyback `main`'s path. This is what makes `main`'s smoke
painter deletable in T16.

**`stream_order.py` (helper 128, calls 159/200) is informational only — 0 assertions** (R-15).
Retiring it is free. **But do not claim the port covers the "we leave the alt screen before the child
writes" property** — today that is *displayed, never asserted*. Making it a real assertion would be a
**new check**, not a port; if you add one, count it as a **gain above the floor**, not part of the 35.

**Acceptance:** floor 35, with both probe proofs ported to Odin. *ISC-15*

---

### T12 — Suite: `tui` (floor 172)

**Owner:** U3 · **Depends on:** T5, T7, T11 · **Source:** `dev/tui-smoke.sh` + `dev/tui_drive.py`

**This is the largest and most timing-sensitive suite. Do it last among the pty suites.**

**In-process guards (`run_guards`, `tui-smoke.sh:112-127`):** `guard-attach local hs-t-does-not-exist-99`
· `guard-attach local default` · `guard-delete local hs-t-never-created-77` → port `case_guard_attach`
/ `case_guard_delete` (`main.odin:1504`, `1521`). **Preserve the `ECHILD` proof verbatim** (O11):
```odin
st: c.int = 0
kid := posix.waitpid(-1, &st, {.NOHANG})
check("…and spawned no child at all", kid == -1 && int(posix.errno()) == 10,
	fmt.tprintf("waitpid(-1,WNOHANG) = {} (errno={})", int(kid), int(posix.errno())))
```
> The guard's boolean only proves what the function said about itself. **`ECHILD` (errno 10) is the
> proof that we spawned nothing.** Do not drop it as redundant.

**pty scenarios (17 invocations, `tui-smoke.sh:129-146`) — port from `dev/tui_drive.py`:**
`boot-local` (430, 10 checks) · `boot-remote` (489, 7, FIXTURE) · `state(name)` (575, 6 × 8 states) ·
`roundtrip` (619, 18) · `del_key` (774, 15 static → **18 runtime**) · `mode_filter_immutable`
(890, 9 static → **19 runtime**) · `sigterm` (973, 5) · `no_orphan` (996, 5) · `delete_notice`
(1079, 10, FIXTURE) · `refresh_key` (1164, 8).

**Per-scenario notes you must not lose:**
- **`state(name)`** — the footer marker is `"<state>  ·  "`, **NOT the bare word** (`tui_drive.py:600-602`:
  `"attach"` appears in the key hints, so a bare-word match proves nothing).
- **`roundtrip`** — create → child owns tty → `ctrl-b q` → repaint ≥ 500 bytes → footer reports
  `cleanup_policy=only_created` + "stopped and deleted", with the old `never`/`left running` asserted
  **ABSENT** · herdr itself confirms destruction · list refreshed-not-blanked · delete picker has no
  ghost · Ctrl+C quits · termios restored.
- **`del_key`** — `ESC[3~` shortens the real filter line · empty-filter Del is harmless · the table
  **re-widens** · **whole-rune deletion** for a 3-byte CJK and a 4-byte astral with **no U+FFFD left**.
  ⚠️ Depends on **T3's width table**. If a rune's `tb_wcwidth` ≠ the Python width, **stop**.
- **`mode_filter_immutable`** — 23 stray keys leave the filter EMPTY and the row count unchanged · the
  six mode keys still work right after · the same typing **does** reach the filter in `{Attach}`.
  `tui_drive.py:930-934` explicitly notes a whole-screen single-char scan is **worthless**
  (`p` ∈ `pending`, `m` ∈ `mode_selection`) — **check the surface the leak would land on (the filter
  line) plus the effect (row count unchanged)**.
- **`no_orphan`** — runs `guard-attach`/`guard-delete` as subprocesses and greps **`errno=10`**
  (ECHILD from `waitpid(-1,WNOHANG)`) as proof nothing was forked · plus herdr's list unchanged.
- **`delete_notice` (R-9 — do not "simplify" this)** — runs against an **on-PATH `herdr` shim**
  (`SLOW_HERDR` `tui_drive.py:1063-1077`, `slow_herdr_dir` 1079-1095) that answers `session list`
  with **one fabricated row** and sleeps **2 s** on stop/delete. Asserts `working:` reaches the tty
  **< 1 s after the Enter keypress**, the final verdict lands after **≥ 2 s**, inside budget, and
  **no real session is touched**. If you "simplify" by using the real herdr the check becomes
  **unobservable** (20 ms round-trip) — and using the real binary badly can touch real sessions.
  **The shim's contract (fabricated row + 2 s stalls + fixture hosts blanked + temp HOME) ports intact.**
- **`refresh_key`** — footer carries a list-age token · 2.5 s idle ⇒ not `list now` · `Ctrl-L` →
  `list re-read` + `list now` · entering `{Attach}` and `{Delete}` each self-refresh.

**P2-3 rule to preserve (`tui-smoke.sh:101-104`):** a driver that exits non-zero while logging **no
`[FAIL]`** is still a failure. Keep it.

**Single-thread the runner.** `-define:ODIN_TEST_THREADS=1`. Do not widen any threshold.

**Acceptance:** floor 172 with `del_key`=18 and `mode-filter-immutable`=19 at runtime. *ISC-A-2*

---

### T13 — Suite: `resize` (floor 138)

**Owner:** U5 · **Depends on:** T5 · **Source:** `dev/resize-smoke.sh` + `dev/resize_drive.py`

- Shape: `REPS=3` × 5 scenarios = **15 runs**, each into **its own log file** (`slog=` at `:52`; the
  comment at `:55-60` explains: **never concatenate, or a later scenario inherits earlier PASSes**).
- Scenarios: `resize-no-key` (127) · `flood` (165) · `too-small` (250) · `eintr-safe` (374) ·
  `selection-shrink` (320, **FIXTURE**).
- **The trace format string is the contract.** `quit_and_trace()` (`resize_drive.py:84-98`) Ctrl+C's the
  app and **reads the file the app wrote at exit**; `field()`/`total_field()` (100-125) parse
  `key=<int>` out of `resizes=… passes=… max_run=… too_small_paints=… eintr=…` and
  `total=… errs=… frames=…`. Producer side: `tui_dump_trace` (`main.odin:1252`, gated on `HS_TUI_TRACE`)
  and the counters in `terminal/resize.odin`'s `Coalescer` / `summary()` (~150-175).
  The exact format is `"resizes=%d passes=%d max_run=%d ratio=%.1f too_small_paints=%d eintr=%d"`
  (`resize.odin`, an all-`%` string **on purpose** — Odin cannot mix `{}` and `%` verbs).
  **Freeze the format or replace it with a structured dump deliberately — a silent change breaks the port
  and the proof with it.**
- **`flood`** throws 30 unthrottled `TIOCSWINSZ` and asserts `passes*2 <= resizes` when `resizes >= 2`
  (the app coalesced) **OR** `passes <= 1` when the kernel merged them (`:213-227`, reasoning spelled
  out there — port the reasoning). Asserts the **last frame is the final geometry**.
- **`too-small`** walks `9x120, 40x39, 5x20, 2x5`, asserting the notice replaced the spine
  (`─` rule rows == 0) and no line exceeds the width, then recovery at 40x120.
- **`eintr-safe`** asserts a **causal** response: stream silenced, then Down produces **> 3 bytes**
  (more than the 3-byte key, so a repaint, not an echo).
- **SKIP protocol** (`skipped()` `:48-61` returns exit 77): `core:testing` has **no skip concept**.
  Use `support.skip()` + the gate's skip ledger. Never a bare `return`.
- `MIN_COLS`/`MIN_ROWS` are at `src/terminal/resize.odin:53-54`; `too_small` at `:58`;
  `too_small_now` at `:159`.

**Acceptance:** floor 138 across 15 isolated runs. *ISC-A-2*

---

### T14 — Fixture-gated suites (the 130-assertion remote half of the 1544)

**Owner:** U4 · **Depends on:** T11, T12, T13 · **Source:** `src/app_live.odin`, `src/fetch_live.odin`,
`dev/device_discriminator.py`

**These CANNOT run in the nix sandbox (no network — verified). They belong to `odinTestsFull`.**

- `app-live` → `case_app_live` (`app_live.odin:65`), `fetch-live` → `case_fetch_live`
  (`fetch_live.odin:57`). Helpers: `eq_code` (57), `check_int` (61) → `testing.expect_value`.
  Fixture: `HERDR_SESSION_TEST_REMOTE` / `_ALIAS` / `_UNREACHABLE=192.0.2.201` (RFC-5737 — no real
  host names in the scripts).
- **`live_device_discriminator`** (`app_live.odin:617`) + `dev/device_discriminator.py` →
  port to `tests/it/disc_*`.
  - **`_ALIAS` is a SECOND SSH TARGET STRING for the same machine, registered as its own Remote —
    NOT a display label.** Read the comment at `main.odin:435-442`: on this box local and remote are the
    same herdr install, so the only way to catch a device-blind model is to reach the identical session
    set twice under two different names. Made a label instead, the table shows one row and every
    device-blind bug passes.
  - Assertions: the same name appears as **two rows with different devices**, specifically PRIMARY and
    ALIAS verbatim · filtering by either target narrows to that device alone, **both directions**.
  - Table parsing by **column offsets**: `DEVICE_W = 12`, rows detected by a timestamp pattern,
    `devices_in()` = first 12 chars stripped, `names_in()` via the timestamp+width suffix. **No regex —
    keep the column-offset approach.**
  - **Preserve the explicit "what this does NOT prove" note (`:118-146`):** "attach carries the selected
    row's device" is **not** checked here — that proof lives at **argv level** in `app-live`
    (`attach_target_argv`, `src/app/exec.odin`), because a footer-string check would pass with a
    completely device-blind implementation. **Keep this reasoning; do NOT "add coverage" by weakening
    it into a footer grep.**
  - **BUG NOT TO INHERIT (B9 / R-10):** `device_discriminator.py:163` is
    `bad = [r for r in results if not r[1]]` — `r[1]` is the **label**, not the boolean, so `bad` is
    always empty and **this driver always exits 0**. Derive the verdict from the boolean and let the
    outer gate count assertions independently.
- **`selection-shrink`** (resize) and `boot-remote`/`roundtrip`/`delete_notice` (tui) fixture arms
  are covered in T12/T13 — coordinate rather than duplicate.
- Fixture arms **must self-skip loudly** (reason sentence) when unset, never silently pass.

**Acceptance:** `hs_check --tier=full` reaches **1544 total** with the per-suite figures matched.
*ISC-8, ISC-A-9*

---

## PARALLELISM SUMMARY

```
SERIAL SPINE (one agent, S):
  T0 ──► T1 ──► T2 ─────────────────────────────────────────┐
                                                            │
LANE P (serial within lane):                                │
  T3 ──► T4 ──► T5 ─────────────────┐                       │
                                    │                       │
PARALLEL SUITES:                     │                       │
  U1: T6 ──► T10                    │                       │
  U2: T7                            │                       │
  U3: T8 ──────────────► T12 ◄─────┘                       │
  U4: T9 ──► T18b ─────────────────────────► T14 ◄─────────┘
  U5: T11 ◄─► T13 (both after T5)                   │
                                                    ▼
FINAL SERIAL (S):   T15 ──► T16 ──► T17 ──► T18
```

- **Nothing starts before T0 and T1 are done.**
- **T3 → T4 → T5 strictly serial** (FFI → emulator → driver).
- **T6, T7, T8, T9, T18b run in parallel** once T2 lands (disjoint file sets by the ownership table).
- **T11, T13 start once T5 lands; T12 needs T7+T11; T14 needs T11+T12+T13.**
- **T15 → T16 → T17 → T18 are strictly serial and single-owner (S).** T16 cannot precede the suites
  (the dispatch is their fallback entrypoint); T17 cannot precede T16 (deleting the `.sh` first would
  strand the product); T11 must precede T17 (the heredoc probes live inside `handoff-smoke.sh`).
