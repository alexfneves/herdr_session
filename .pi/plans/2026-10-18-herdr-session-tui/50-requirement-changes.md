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
