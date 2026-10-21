# T0 — Baseline Measurement (partial: fixture UNARMED)

**Date:** 2026-10-20 · **Binary:** `./result/bin/herdr-session` (nix-built, `02c9ced`)
**Fixture:** `HERDR_SESSION_TEST_REMOTE`/`_ALIAS`/`_UNREACHABLE` **UNSET**
**`ALLOW_SKIP=1`** (fixture-gated sections skip rather than fail)
**Real `~/.config/herdr_session.json` md5 before == after:** `0cce060b885d2796d87ef1f4fd8d98b5` ✅
**Live herdr sessions before == after:** `2026-10-20-19-16-08-614`, `default` ✅ (untouched)

> This is the measurement the plan's **T0** calls for. It was taken with the fixture **unarmed**
> (no test remote configured in this environment), so it establishes the **hermetic tier** and the
**fixture delta**, but is **not** the final armed baseline. The armed re-run is still owed.

## Measured vs the RCH-7 authoritative baseline

| Suite | RCH-7 baseline (armed) | Measured (unarmed) | Δ | Interpretation |
|---|---|---|---|---|
| `state` | 259 | **259** | **0** | ✅ **100 % hermetic** — no fixture-gated assertions at all |
| `theme` | 171 | **171** | **0** | ✅ **100 % hermetic** (its pty scenarios ran against a fabricated config host, not a real remote) |
| `render` | 69 | **69** | **0** | ✅ **100 % hermetic** |
| `handoff` | 35 | **35** | **0** | ✅ **100 % hermetic** (all 35 ran, 0 skipped) |
| `app+disc` | 532 | **444** | **−88** | 88 assertions are fixture-gated (`app-live`, `fetch-live`, `device_discriminator`) |
| `tui` | 172 | **145** | **−27** | 27 fixture-gated (2 scenarios skipped: `boot-remote`, `roundtrip`) |
| `resize` | 138 | **123** | **−15** | 15 fixture-gated (3 runs skipped: `selection-shrink` ×3 reps) |
| `ui` | 90 | **168** | **+78** | ⚠️ **BASELINE UNDERSTATED — see below** |
| **Total** | **1461** | **1414** | **−47** | |

**Hermetic total verified runnable today with no network: 1414 assertions, 0 failures.**
That is the honest number `nix flake check` can enforce in-sandbox (the nix sandbox has a pty but no network).

## ⚠️ FINDING: the `ui` baseline figure is stale

The RCH-7 baseline records **`ui` = 90**. Measured **168**.

Per-case comparison against the last recorded breakdown
(`40-execution-log.md:472` — *"frame 14, sessions 16, shrink 12, edit 20, list 17, float 11"*):

| Case | Recorded | Measured | Δ |
|---|---|---|---|
| `ui-frame` | 14 | **92** | **+78** |
| `ui-sessions` | 16 | 16 | 0 |
| `ui-shrink` | 12 | 12 | 0 |
| `ui-edit` | 20 | 20 | 0 |
| `ui-list` | 17 | 17 | 0 |
| `ui-float` | 11 | 11 | 0 |
| **Total** | **90** | **168** | **+78** |

**Five of six cases match the historical record exactly.** The entire delta is in `ui-frame`, and the
cause is visible in the log: `ui-frame` now carries the **RCH-1 no-outer-border frame-geometry proofs**,
e.g. *"exactly one border call, registered as the divider source (RCH-1)"*, divider-span, rule-row
purity, predicted-vs-Clay box equality, and the `KEYS_MODE` footer-overflow checks at 120 cols
(plus `never overflows` / `cuts no hint in half` / `is not blank`).

These are **real assertions with real detail strings**, not screen-dump lines being miscounted — verified
by cross-checking the harness's own per-case count (`PASS ui-frame (92 checks)`) against an independent
`grep -c '\[PASS\]'` over the same section: **both give 92**.

**Conclusion:** the `ui-frame` case grew from 14 → 92 assertions during RCH-1 and the footer-hint work,
and the aggregate "ui 90" figure was **never updated**. The recorded total 1461 is therefore an
**understatement**, and the true current armed total is approximately:

```
1414 (measured hermetic)
 + 88 (app fixture-gated)
 + 27 (tui fixture-gated)
 + 15 (resize fixture-gated)
= 1544  expected armed total
 − 1461 recorded
= 83 unexplained, of which 78 is the ui-frame growth above; residual ≈ 5 (minor drift in app/tui/resize)
```

## What this means for the migration

1. **This vindicates the plan's T0 mandate and risk R-17.** A prose baseline that has drifted 78
   assertions is exactly why the plan forbids trusting recorded numbers and requires a real run before
   any code moves. Had the migration ported `ui` against a floor of 90, it could have **dropped 78
   assertions and still reported "parity."**
2. **`ui`'s per-suite floor must be corrected to ~168 before U3 starts.** Recording 90 would have made
   the single largest assertion-loss in the migration invisible.
3. **Four suites are proven 100 % hermetic** — `state` 259, `theme` 171, `render` 69, `handoff` 35
   = **534 assertions** that run identically with or without the fixture. These are the strongest
   candidates for the in-sandbox `nix flake check` tier and need no fixture-armed reconciliation.
4. **The fixture delta is now quantified**: ~130 assertions across `app`/`tui`/`resize` depend on a
   test remote, and they map to the specific scenarios already identified in the plan
   (`app-live`, `fetch-live`, `discriminator`, `boot-remote`, `roundtrip`, `selection-shrink`).

## Still owed (T0 completion, fixture ARMED)

- [ ] Re-run all 8 suites with `HERDR_SESSION_TEST_REMOTE` + `_ALIAS` + `_UNREACHABLE` set.
- [ ] Confirm the armed total and correct every `floor_before` in `tests/parity.tsv` — **`ui` → ~168**,
      not 90.
- [ ] Explain the ≈5-assertion residual beyond the `ui-frame` growth.
- [ ] Re-freeze the timing thresholds table verbatim from `dev/*.py`.
- [ ] Have the orchestrator confirm the corrected total, so the corrected number — not 1461 —
      becomes the parity target of record.

**Do not start suite ports until the armed re-run corrects these floors.**
