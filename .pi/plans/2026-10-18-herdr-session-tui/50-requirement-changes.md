# Requirement Changes Post-Planning

Read this **before** touching any UI code. Changes here **override** `docs/requirements.md`
and `plan.md` where they conflict.

---

## RCH-1 — No outer border around the application (user, 2026-10-19) — ✅ APPLIED (D14, commit c087c01)

> *"i want to remove the border around the application. i still want a division between the
> header, main content and footer"*

### What changes

| | Before (per `docs/requirements.md` diagram) | After |
|---|---|---|
| Outer border around the whole TUI | **Present** (all four sides) | **REMOVED** — no left/right/top/bottom box |
| Divider between Header ↔ Main | Present | **KEPT** |
| Divider between Main ↔ Footer | Present | **KEPT** |

Target layout:

```
         Header
────────────────────────
      Main content

────────────────────────
         Footer
```

i.e. the app is bounded only by the terminal edges; the **two horizontal rules between the three
sections remain**. The Header is no longer boxed and the Footer is no longer boxed.

### Implementation notes

- This is exactly the case our renderer already understands: **`BorderWidth.betweenChildren`**
  produces the divider, while the per-side widths (`left/right/top/bottom`) must be **0 / unset**.
- Do **not** set a `border` on the root element with `BorderAll(1)` — that is what draws the outer box.
- The dividers must come from the section container's `betweenChildren`, **not** from hand-painted glyphs
  (that is a forbidden anti-pattern — ISC-A: no hand-painted box glyphs outside Clay's knowledge).
- **`childGap` must stay ≥ 2** — established in Phase 2: at gap 1 the `betweenChildren` rule lands on the
  *following* child's row and paints over its text. Removing the outer border does **not** relax this.
- Removing the outer border **frees 2 columns and 2 rows** of usable space. Any width/height arithmetic
  that subtracted an outer-border allowance must be reviewed so content is not left short by 2.

### Affected acceptance criteria (must be updated when applied)

- **T5.1 acceptance** currently reads *"outer border + a rule between each section"* → becomes
  **"no outer border; a rule between Header/Main and between Main/Footer"**.
- Any UI smoke assertion counting border glyphs on the screen edge must be **inverted**: the first and last
  row/column must contain **no** box-drawing glyphs.
- Positive assertions stay: the two horizontal divider rules exist and sit between the sections.
- **"terminal too small" threshold** (~40×10) should be re-checked — the usable area grew by 2×2.

### Follow-ups when this is applied

1. Fold the change into `plan.md` (Decision Register **D14**) and `todos.md` (T5.1 acceptance text).
2. Re-run the full suite fixture-armed and confirm no regression count drops.

---

# RCH-2 — Environment drift: herdr upgraded 0.8.2 → 0.9.5 mid-project

**Discovered during T6.1/T6.2 verification (2026-10-20).** The plan pinned behaviour to herdr **0.8.2**
(the version installed when research began). The box now runs **0.9.5**, and the user's own session set
changed too (`HERDR_SESSION` is now `2026-10-20-08-42-00-459`; the two August sessions are gone).

## Verified behavioural differences

| Behaviour | 0.8.2 (planned against) | 0.9.5 (current) |
|---|---|---|
| No-tty launch of a new session | **exit 101** + ratatui panic | **exit 1** + clean message: `herdr: cannot attach without a usable terminal: … run inside a terminal` |
| Aborted no-tty launch leaves an orphan | **YES** — server spawns before tty init, session left `running:true` | **NO** — nothing is created |
| `herdr machine` | absent (`unknown command`) | **present**; `machine list --json` → `[]` (valid, empty) |

**Both changes are upstream improvements.** The orphan hazard our guards were written against has been
fixed upstream in 0.9.5.

## Decisions (mine, orchestrator — recorded as O11/O12)

### O11 — KEEP every guard. The drift does not retire them.
The orphan hazard is gone **on 0.9.5 only**. Our "never attach an unvalidated name" and "pre-check
before delete" guards are **defence in depth**: they remain correct and necessary for any user on 0.8.x
and harmless on 0.9.x. **Do not remove or weaken a guard because upstream got safer.**

### O12 — Tests must be made version-tolerant, not pinned to a dead version
Three `app-live` checks now fail **because they assert 0.8.2 behaviour**, not because the product is wrong:
```
[FAIL] no-tty launch panics with 101                 got 1 want 101
[FAIL] 101 maps to tty_panic (never parsed as JSON)  got "herdr error" want "terminal-init panic"
[FAIL] an aborted launch still leaves a live session  names=2026-10-20-08-42-00-459
```
Required shape:
1. **Exit-code map must accept BOTH** `101` (old panic) and `1`-with-clean-message (new) as
   "launch failed, needs a terminal". The product already must be robust to either, depending on the
   user's herdr version.
2. **Assert the GUARD prevents the orphan**, not that the hazard exists. The guard is what we own;
   whether upstream orphans is not our contract.
3. **Compute the "pre-existing session" baseline dynamically.** The old hardcoded expectation is invalid
   now that the user's session set changed. (This is also the fix for the vacuous-drift weakness already
   noted for T6.6.)

### O13 — `machine list` returning `[]` must NOT suppress config `remotes`  ⚠️ check this
Now that 0.9.5 answers `machine list --json` with a **valid empty array**, a naive shape gate would read
"available, zero machines" and stop — silently dropping the user's own configured `remotes`.
**Discovery must MERGE both sources** (machine registry + `herdr_session.json` `remotes`), not pick one.
This must be explicitly tested with `machine list == []` **and** a non-empty config `remotes`.

## Honest note on the reported totals
The worker reported **`app` 336 PASS / 3 FAIL** and **proved** those 3 reproduce identically on the
pre-T6 baseline `d483f86`. So this is **not a T6 regression** — the environment moved underneath a
green suite. The prior "823 PASS / 0 FAIL" was true when it was measured; it is no longer reproducible
on this box until O12 is applied.

---

# RCH-3 — Four user requirements post-v1 (2026-10-20)

The user added/corrected four behaviours after the first version. Each was checked against the code
before being restated; three are **spec-conformance fixes the implementation had rationalised away**.

## R1 — Destroy-on-detach for sessions WE created. **This resolves parked D2.**
> "After creating/starting a session, then going back (the session was detached), it should delete the
> session and update the list when going back to the main state. If the session was already deleted
> there is no error to show."

**Decision: `cleanup_policy` default becomes `only_created`** (was `never`).
- Delete the session after the handoff returns **only when we created it**.
- **Attaching to a pre-existing session must NOT delete it** — that is exactly what `only_created`
  encodes, and why it is the right default rather than `always`.
- **Refresh the list on return to `{Mode selection}`** — local immediately, remote fan-out merges in.
- **Delete is idempotent and silent on "already gone".** herdr's `session delete` already returns
  success for a non-existent name; we must not surface an error for it. A session the user deleted in
  another terminal is not our problem to report.

*D2 status: RESOLVED. The "parked at `never`" caveat in earlier notes is superseded.*

## R2 — `{Mode selection}` must NOT accept filter typing  *(spec-conformance bug)*
Spec lists the bindings for `{Mode selection}` as: `Enter`, `n`, `r`, `s`, `a`, `d`, `t`, `Escape`,
`Ctrl+C`. **There is no "type in the filter" binding for Mode selection.** Only these states have it:
- `{Select remote server for new remote session}`
- `{Select session to attach}`
- `{Select session to delete}`
- `{Select theme}`

The implementation currently does the opposite, **with a comment rationalising it**
(`src/app/state.odin` `at_mode_selection`): *"Every other printable key filters the Sessions table …
which is what keeps the spec's filter line usable in the Sessions view."* It is not what the spec says.
Any unclaimed printable key leaks into the filter, so a mistyped mode key silently changes the list
instead of doing nothing.

**Decision:** filter editing lives **only** in the four states above. In `{Mode selection}`, an
unclaimed printable key is a **no-op** — it must not mutate the filter. The filter **line is still
displayed** in the Sessions layout (the spec requires it); it just isn't editable from there.

## R3 — Delete key must remove filter characters  *(new requirement, root cause found)*
**Root cause: `KEY_DELETE` is never mapped.** `src/input/keymap.odin:map_code` handles `KEY_BACKSPACE`
(0x08) and `KEY_BACKSPACE2` (0x7f) but **not** `KEY_DELETE` (`CSI 3 ~` — the Del key, and fn+Delete on
a Mac keyboard). It falls through to `.none`, `ch == 0`, and decodes to `NO_KEY`: the keypress is
silently dropped. The filter's own backspace handler is fine — it just never sees that key.

**Decision:** map `KEY_DELETE` → `.backspace` so it removes the last rune in every filter/edit state
(`text_backspace` already deletes whole runes, so UTF-8 is safe).

## R4 — Something is always highlighted unless the list is empty  *(new requirement)*
- **Theme picker:** the **currently applied theme** is highlighted on open — already correct, keep it.
- **Every other list:** the **first element** is highlighted on entry.
- Today `rebuild_shown` sets `a.sel = -1`, so lists open with **no highlight**.

**Decision + the invariant that keeps it safe.** The current `-1` exists for a good reason, documented as:
*"if the selected row is filtered out the cursor must drop to -1, NOT slide onto whatever row shifted
into its slot — sliding is how Enter ends up acting on a row the user never pointed at."*
R4 supersedes the `-1`, but the danger is removed a different way by strengthening the real invariant:

> **The highlighted row is always the selection.** After clamping to the first visible row, `held` MUST
> be re-synced (`sync_cursors`) so `held` always denotes the highlighted row — never a row that was
> filtered away, never a phantom.

With that, "always highlighted" is *safer* than `-1`, not less safe: Enter can never act on a row that
isn't visibly pointed at. An **empty** list still yields `sel = -1` with `held` invalid, and Enter is a
no-op (spec: "If nothing was selected, pressing the key does nothing").

---

# RCH-4 — CORRECTION to R4: `{Mode selection}` must show NO highlight

**User correction (2026-10-20), supersedes the "always highlight" half of RCH-3/R4.**

R4 as originally recorded said a list must always have something highlighted unless empty, first element
by default. That is **still correct for the picker states**, but **wrong for `{Mode selection}`**.

## Final rule

| State | Highlight on entry |
|---|---|
| `{Mode selection}` | **NONE** — `sel = -1`, no row pointed at |
| `{Select session to attach}` | first visible row |
| `{Select session to delete}` | first visible row |
| `{Select remote server…}` | first visible row |
| `{Select theme}` | the **currently applied** theme |
| any list, after its selection was filtered away | first *visible* row |
| **empty** list | none (`sel = -1`), Enter is a no-op |

## Why this is the right shape, not a contradiction
The highlight is a **promise about what `Enter` will act on**. In the picker states `Enter` acts on the
pointed row, so one must always be pointed at. In `{Mode selection}` **`Enter` means "New session"**
(spec: `[Enter] New session …`) — it does **not** act on any listed row. A highlighted row there would
point at something and then do something else with it: exactly the misleading UI R4 existed to prevent.

`{Mode selection}` also has **no `Up`/`Down` bindings in the spec**, which confirms it: there is no
cursor to move in that state.

## Consequences (must hold)
1. `a.sel = -1` in `{Mode selection}` **and** `held = NO_SELECTION` — never a stale selection from a
   picker the user just left.
2. **Returning to `{Mode selection}` from any picker clears the selection**, along with the filter.
3. The invariant from RCH-3 survives, sharpened: **the highlighted row is exactly the row `Enter` acts
   on.** No highlight ⇒ `Enter` acts on nothing (or on the state's own meaning, for a create).
4. Any R4 test asserting "first row highlighted in every list" must be **scoped to the picker states**
   and a new test must assert the opposite for `{Mode selection}` — show the corrected test rather than
   deleting the old one.

---

# RCH-5 — `tests/` folder, all tests in Odin, using `core:testing`

**User requirement (2026-10-20).** Tests belong in a `tests/` folder, written in Odin, using the Odin
testing suite. Investigation before recording — the current state is worse than "wrong folder":

## Findings

| Area | Lines | Notes |
|---|---|---|
| Product (`app`,`ui`,`render`,`terminal`,`input`) | **8,730** | already properly modular |
| Test code living **inside `src/`** (`*_cases.odin`, `*_live.odin`) | **8,255** | `package main` |
| `src/main.odin` | 1,612 | product TUI **and** the test dispatcher |
| Python pty drivers (`dev/*.py`) | 2,282 | not allowed as our language |

**Three real problems, not cosmetic:**

1. **The product binary IS the test harness.** `main()` dispatches on `argv[1]`: default `tui`, but
   ~30 named cases are baked in and **reachable by anyone who has the binary** — `app-live`,
   `fetch-live`, `theme-set`, `config-save`, `probe`, `guard-attach`, `guard-delete`, `handoff`,
   `layout-dump`… Test code ships, and so does its attack surface.
2. **`core:testing` is not used anywhere.** Assertions are hand-rolled: `check_int`, `expect_cell`,
   `expect_cmd`, `expect_noop`, `expect_state`, `say_raw` — bespoke plumbing to reinvent what the
   standard library already does.
3. **Tests outnumber the product** (~10.5k test-controlled lines vs 8.7k product), which makes
   the misplacement expensive rather than trivial.

## Target shape
```
src/                     PRODUCT ONLY. No test code. No argv case dispatch.
  main.odin              entry + TUI only
  app/ ui/ render/ terminal/ input/     (unchanged — already importable packages)
tests/                   ALL tests, Odin only, `core:testing`
  *_test.odin            unit: state, config/theme, model, herdr argv, render, ui
  live_test.odin         integration against real herdr (fixture-gated)
  pty_*.odin            Odin pty drivers replacing dev/*.py (posix.openpty + fork/exec)
dev/                     thin bash runners ONLY (or deleted once nix runs the tests)
```

**Imports work without a rebuild of the module system** — current imports are relative
(`./app`, `../clay-odin`), so `tests/` can use `import app "../src/app"`. Adding an `odin.json`
module for clean `herdr_session/...` paths is a nice-to-have, not a prerequisite.

**Build separation (required):** product build must not contain tests. Add a distinct test target
(`odin test tests` / a second derivation) and wire `nix flake check` — there is currently **no check
phase at all**, so CI never runs these.

## Non-negotiable migration constraint
> **Verification strength must not decrease.** Every assertion moved must be counted before and after.
> If a suite goes from N to fewer than N assertions, that is a REGRESSION, not a cleanup — report it as
> such rather than reporting a green suite.

Port **one suite at a time**, prove parity, commit, then the next. Keep the house rule that *zero
assertions executed = failure* (`core:testing` reports 0 tests as a pass otherwise).

## Ordering
This restructures the very files (`src/*_cases.odin`, `src/*_live.odin`, `dev/*`) that the in-flight
RCH-3/RCH-4 work is editing. **It must run AFTER that lands** — two agents in those files is a
guaranteed conflict.

---

# RCH-6 — **ALL** test-related `sh` and `py` replaced by Odin tests  (tightens RCH-5)

**User instruction (2026-10-20):** do the RCH-5 migration **after** the in-flight agent finishes, and
every `sh`/`py` script related to tests must be **replaced** by Odin tests — not wrapped, not kept as
"thin bash runners". RCH-5's suggestion of keeping thin bash runners in `dev/` is **withdrawn**.

## Complete replacement inventory

**Must become Odin tests (or be deleted):**
```
dev/app-smoke.sh              herdr integration + parallel fetch + discriminator
dev/state-smoke.sh            state machine
dev/render-smoke.sh           renderer
dev/handoff-smoke.sh          terminal handoff
dev/ui-smoke.sh               UI components
dev/theme-smoke.sh            config + themes
dev/tui-smoke.sh              full TUI end-to-end
dev/resize-smoke.sh           resize coalescing / too-small / EINTR
dev/lib.sh                    the tally rules  → replaced by core:testing semantics
dev/tui_drive.py              pty driver       → Odin (posix.openpty + fork/exec)
dev/resize_drive.py           pty driver       → Odin
dev/theme_drive.py            pty driver       → Odin
dev/device_discriminator.py   pty driver       → Odin
dev/stream_order.py           stream-order     → Odin
```

**NOT test-related — out of scope, may remain:**
- `dev/local-build.sh` — build helper, not a test
- `dev/*.md` (`test-remote.md`, `device-discriminator.md`) — documentation/transcripts, not scripts
- `nix/*`, `flake.*` — build system
- `vendor/**` — third-party

## Acceptance gates (grep-verifiable)
1. `find . -name '*.py' -not -path './vendor/*'` → **nothing**.
2. `git ls-files 'dev/*.py'` → **nothing**.
3. No `dev/*-smoke.sh`, no `dev/lib.sh`.
4. Repo contains **no test-related `sh` or `py` of ours**. Product is **Odin only**.
5. Tests run through a single Odin entrypoint: `odin test ./tests` (or an equivalent Odin runner).
6. `nix flake check` runs them — CI finally exists.

## Preserve while migrating
- **Assertion-count parity per suite** (RCH-5's rule): moving a suite must not reduce its assertion
  count. Report before/after per suite; a drop is a **regression**, said out loud.
- **The zero-assertions-is-failure rule.** `core:testing` treats 0 tests run as a pass — add an explicit
  guard (assert the registered test count is non-zero).
- **Every current check must still be covered**: the ~1,354 checks that today pass, re-expressed in Odin.
  Deleting a check because porting it is annoying is the failure mode to avoid.
- The fixture discipline stays: `HERDR_SESSION_TEST_REMOTE`/`_ALIAS`, TEMP `XDG_CONFIG_HOME`,
  `hs-t-*` scratch only, live user sessions untouched, teardown traps (as Odin `defer`/cleanup).
- Product invariants untouched: O11/O12/O13, `--` before the ssh device, `resizefd` in the poll set,
  0.000% idle CPU, RCH-1 no outer border, all anti-criteria greps clean.

## Execution order (strict)
1. **Wait for the in-flight RCH-3/RCH-4 agent to land** — it owns the same files. Do not overlap.
2. Remove the argv test dispatch from `main` so the product binary contains **no test code**.
3. Create `tests/`, migrate **one suite at a time** to `core:testing`, parity-checked, one commit each.
4. Port the Python pty drivers to Odin; retire the `.py` files only once their replacement passes.
5. Delete `dev/lib.sh` and every `*-smoke.sh` last, once nothing references them.
6. Wire `nix flake check`.
7. Re-run the whole thing and report the honest new total vs the current ~1,354 baseline.

---

# RCH-7 — Scope pin for the migration: TESTS ONLY  (supersedes any folder reorg)

**User instruction (2026-10-20):** *"Forget about changing folder structure for now, and only make
changes related to tests."*

## Explicitly OUT of scope — do not do these
- **Renaming `vendor/` → `bindings/`.** (Discussed after this instruction; withdrawn.)
- Creating `libs/`, `assets/`, or reshaping `src/`'s subsystem layout.
- Moving `docs/`, changing `nix/package.nix`'s **filter** semantics, or touching import paths of
  Clay/termbox2 for cosmetic layout reasons.
- Any refactor whose motivation is "the folder layout should look like X".

**Existing layout stays as-is:** `src/` (product), `vendor/termbox2-odin/` (termbox2 FFI wrapper),
`clay-odin/` (build-time materialized, gitignored), `dev/`, `docs/`, `nix/`.

## In scope — everything that is *about tests*
The RCH-5 / RCH-6 mandate stands, and `tests/` is created **because it is the tests' home**, not as a
layout exercise:
1. **Test code must leave the product.** Delete the `argv[1]` case dispatch from `main` — the shipped
   binary must not contain ~30 runnable test entrypoints.
2. **`tests/` folder, Odin only, `core:testing`.** Port the 8,255 lines currently in
   `src/*_cases.odin` / `src/*_live.odin`.
3. **Replace every test-related `.sh` and `.py` with Odin tests** (RCH-6 inventory).
4. **`nix flake check` runs them** — there is no check phase today.

## Baseline to preserve (verified by the orchestrator, fixture armed, 2026-10-20 ~21:50)
```
state 259 · app+disc 532 · tui 172 · theme 171 · resize 138 · ui 90 (6/6) · render 69 · handoff 35
TOTAL: 1461 PASS / 0 FAIL
```
**RCH-3 and RCH-4 are DONE and independently verified** (source inspection + full suite run), despite the
worker's completion report arriving empty:
- **R1** `only_created` is the cleanup default · **R2** `at_mode_selection` has **no** filter append
  (the only one lives in `filter_navigate`, reached solely by the four editable states)
- **R3** `KEY_DELETE` mapped · **RCH-4** `{Mode selection}` highlights nothing
So the plan does **not** need to "finish" RCH-3/4 — only to **keep parity** with them.

## Migration rule that matters more than the layout
> **Assertion-count parity per suite.** Port one suite, count before/after, commit. Fewer assertions
> after = **regression**, said out loud. Plus: guard against `core:testing` scoring **0 tests as a pass**.
