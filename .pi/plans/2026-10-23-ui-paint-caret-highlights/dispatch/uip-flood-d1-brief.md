# DISPATCH — Flood invariant (d.1): make APP-MERGED aggregate, not per-run

**Workspace:** `/home/alexfneves/gits/herdr_session` (MAIN worktree)
**Branch:** `fix/resize-flood-invariant-d` — already exists, HEAD `792a350`. Switch to it as your FIRST command.
**Task owner:** worker. **Budget:** 1 of 3 concurrent agents.

## READ THIS FIRST — the work is already on disk, do not re-derive it

Commit `792a350` (on your branch) contains the flood lane's recovered, **uncommitted-when-killed**
rework of `tests/it/resize_flood_test.odin`. Read that diff before you type anything:

```sh
cd /home/alexfneves/gits/herdr_session
git switch fix/resize-flood-invariant-d
git show 792a350
```

It already adds `issued` (harness-side count of *successful* `pty_resize` calls in the storm) and
splits the old single `COALESCED` check into three. **Do not re-justify the denominator change** —
it is settled: `resizes` is the count of SIGWINCH delivered *and counted by the app*; the kernel
coalesces before that counter runs, so it measures scheduler luck, not app behaviour.

## The one thing left to fix: APP-MERGED is load-fragile

Measured independently by the orchestrator, **idle box, 3 runs of one rep each**:

| rep | issued | resizes | passes | max_run | verdict |
|---|---|---|---|---|---|
| 1 | 30 | 8 | 8 | 1 | **FAIL** `APP-MERGED` (needs `passes < resizes`) |
| 2 | 30 | 26 | 6 | 6 | pass |
| 3 | 30 | 26 | 7 | 7 | pass |

The lane's own heavier measurements: end-to-end (`passes*2 <= issued`) **never failed in ~126 runs**;
`APP-MERGED` failed 4/90 under load with `resizes=5 passes=5 max_run=1`, `resizes=8 passes=8`,
`resizes=2 passes=2`. Same signature as rep 1 above: **the kernel delivered the events spaced out,
so the app had nothing to merge.** A per-run assertion of "the app merged" is not observable when
there is no merge opportunity, so it fails on luck while claiming to fail on behaviour — the exact
misattribution the `issued` reformulation was supposed to delete.

### Decision (d.1) — authoritative, implement this

1. **Headline stays:** `passes * 2 <= issued` (end-to-end collapse against what the user asked for).
2. **Keep unconditional:** `passes <= resizes` — the app never invents repaints. Robust, still falsifiable.
3. **Keep the storm-observed / delivery guard:** `resizes >= 1` and `resizes <= issued`, all three
   numbers printed together (`issued`, `resizes`, `passes`, `max_run`).
4. **APP-MERGED stops being a per-run check.** Re-express it as an **aggregate across the burst reps**:
   *at least one rep must show `max_run >= 2`* — proof the app collapsed two received events into one
   layout pass when it had the chance. Name it so the ledger reads as the app-merge property it is.
   Use enough bursts that one unlucky rep cannot flip it (the existing `REPS` loop plus as many extra
   bursts as you need — report the count you chose and why).

**Why that keeps the tooth.** The hole the per-run check was guarding: a non-merging app can pass the
end-to-end check if the kernel swallowed enough requests (`issued=30 resizes=11 passes=11` → 22 ≤ 30).
With `max_run >= 2` required across the reps, an app whose merging is disabled produces `max_run == 1`
in every rep and **fails**. Verify this rather than asserting it (see Perturbation below).

## Hard constraints

- **Ownership:** `tests/it/resize_flood_test.odin` (+ `tests/it/resize_harness.odin` only if you
  genuinely need a new harness reader). **No `src/` changes.** If you cannot express (d.1) inside
  `tests/it`, STOP and report — do not reach into the product.
- **Do NOT touch `tests/parity.tsv`.** Report numbers; the orchestrator folds them (D-D).
- **Odin only. No Python / awk / sed / jq — including throwaway analysis scripts.** This is a project
  requirement (`docs/requirements.md`, commit `0964357`). `hs_check` and the existing tally paths
  exist; if you believe Python is truly unavoidable, STOP and escalate instead of writing it.
- **Do not run 40-burner synthetic load.** The previous run of this task ended `exit 137` (killed)
  during a 40-burner stress loop. Cap synthetic load at ≤ 8 concurrent `odin build` jobs and say so.
- **Never `git add -A`.** Stage only your own paths.
- **Live sessions are off-limits:** never touch `2026-10-20-19-16-08-614` / `2026-10-20-21-07-27-640`.
  Scratch sessions `hs-t-*` only. Report `md5sum ~/.config/herdr_session.json` before and after —
  must still be `0cce060b885d2796d87ef1f4fd8d98b5`.
- **Odin gotcha:** `for a, b in slice` yields **(value, index)** — reversed from the usual convention.
- **Commit-first discipline.** Make the smallest correct code change, build, **commit immediately**,
  then iterate. Four of six agents in this migration died with hours of unread work in their context.

## Also fix while you are in the file

The file-header block comment still documents the **old** invariant
(`resizes >= 2 → passes*2 <= resizes`, `resizes == 1 → passes <= 1`). That is now false and will
mislead the next reader. Rewrite it to the three-check model and keep the provenance note about
`dev/resize_drive.py:213-235` being where the old reasoning came from.

## Characterise, do not fix (report only)

Under the previous 40-burner stress one non-APP-MERGED failure appeared:
`the surviving frame is the FINAL size, not a stale one — spine widths lo=118 hi=118 want 118
(last request 25x118, rules=1, settled=true)`. Determine whether that frame check is *also*
load-fragile or a real product issue, and report which. Do not change it unless it falls inside
your owned files.

## Toolchain

```sh
export PATH=/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/bin:$PATH
cd /home/alexfneves/gits/herdr_session
odin build ./tests/it -build-mode:test -define:ODIN_TEST_THREADS=1 -out:/tmp/fl_it
BIN=$PWD/result/bin/herdr-session /tmp/fl_it -tests:it.resize_flood_survives_and_lands_final_size
```
`result/bin/herdr-session` is a fresh-enough nix build; if you rebuild it, report the command.
Gate usage is in `tests/tools/hscheck/HOWTO.md` — **always pass the report path explicitly**
(`ODIN_TEST_JSON_REPORT` is a compile-time `#config`, not an env var).

## Report (do not summarise a gap as a pass)

1. The checks exactly as written, and the aggregate burst count you used.
2. **Perturbation table for the NEW form** — at minimum: normal; app-merge disabled; kernel-ate-the-storm;
   app-does-not-see-the-storm. State which check kills each.
3. Flake rate over **N ≥ 30** at ordinary (not pathological) load, per check.
4. How often the aggregate app-merge condition actually **fires** (if it fires rarely, it is vacuous — say so).
5. The observed `issued / resizes / passes / max_run` triplets.
6. `resize` row total vs floor 123.
7. The frame-check characterisation above.
8. Commit hashes, and the config md5 before/after.
