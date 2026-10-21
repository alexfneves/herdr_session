# Orchestrator decisions — odin-test-migration

## D-T9 — DECIDED: **A, with C as the permanent home**

U4 found a real plan gap: T9's floor of **171** includes **36 PTY-driven assertions** whose driver
(`tests/pty/**`, Agent P's T3–T5) does not exist yet, while T9 is listed as depending only on T2.
**Those 36 are assigned to no task.**

### Ruling
1. **Deliver the 135 hermetic in-proc assertions now** (`theme` in-proc 129 + hygiene 6) in
   `tests/unit/theme_*.odin`, with the hygiene block as **real proofs** — real
   `~/.config/herdr_session.json` md5 before==after, XDG non-leak, TOML/XDG-import/`localhost` greps,
   scratch accounting.
2. **The 36 PTY assertions are DEFERRED, not deleted, and the floor is NOT lowered.**
   `parity.tsv` must read: floor **171**, with an explicit visible gap marker
   (`delivered 135 / gap 36 / deferred_to: T14`).
   > A lowered floor is the forbidden outcome. An honest gap in the artifact is required.
3. **Permanent home for the 36 = T14**, as `tests/it/live_theme_pty_*.odin`, under a
   **new tier label `pty`**.
4. **Keep the in-proc picker-preselect proof.** Driving the real state machine (`cursor_id` +
   `rebuild_shown` → the selected row IS the applied theme) is **better** than scraping the screen for
   it. It is **additive**. Label it so it is never conflated with the PTY screen-scrape of the same
   property — both are kept (defence in depth), and neither is counted twice as two properties.

### Why not B
Reimplementing a pty harness inside `tests/unit/theme_pty.odin` duplicates exactly what Agent P owns and
is mid-build. The single-owner rule exists precisely to stop two divergent pty implementations
coexisting. **Rejected.**

---

## ⚠️ PLAN CORRECTION — the tier taxonomy was conflating two different things

The plan labels suites `hermetic` = "no network / no remote fixture". But **`hermetic` does NOT mean
"no pty"**, and that distinction was never made explicit:

| Suite | floor | needs remote fixture? | needs a tty/pty? |
|---|---|---|---|
| `state` | 259 | no | **no** — pure function |
| `render` | 69 | no | **partly** — `enter_terminal` |
| `theme` | 171 | no | **36 of them** |
| **`ui`** | **168** | no | **YES — `bring_up`, `shrink_pty` via `TIOCSWINSZ`** (`src/ui_cases.odin:181,347,356`) |
| `handoff` | 35 | no | **yes, definitionally** |

**Consequence: U3 will hit the identical wall at T8** that U4 hit at T9 — `ui`'s floor is pty-dependent
but T8 is listed as depending only on T2.

**Instruction to U3 (delivered with the T8 brief / follow-up):** report explicitly how many of the 168
are pty-gated, and if `tests/pty/` is not ready, deliver the non-pty remainder with a **visible, named
gap** — exactly the T9 pattern. **Do NOT substitute weaker non-pty checks to hit 168.**

---

## Open question to settle during T15 (nix wiring) — record the answer, don't assume
**Can a pty even be allocated inside the nix sandbox?**
`openpty` needs `/dev/ptmx`. The plan already verified there is **no network** in the sandbox, but says
nothing about `/dev/ptmx`. This determines whether the **`pty` tier** belongs in `nix flake check` or in
`odinTestsFull`.

> Determine this **empirically** and write the answer into the plan. If pty is unavailable in the
> sandbox, the `pty` tier moves to `odinTestsFull` and `nix flake check` runs only the true
> in-proc hermetic set — which is a legitimate outcome, but it must be **stated**, so nobody later
> assumes `nix flake check` covers more than it does.

---

## Standing rule extracted from this incident
> **A task's `Depends on:` must include every capability its FLOOR requires.**
> T9's floor required a pty driver; T9 depended on T2. That is how 36 assertions became orphaned.
> Apply this check to every remaining task before dispatch, not just the one that surfaced it.

---

## D-T15 — the sandbox question is ANSWERED: the `pty` tier belongs in `nix flake check`

Agent P probed it empirically inside a real `nix build` sandbox (`pkgs.runCommand`, sandbox enabled):
```
PTY_OK master=3 slave=4 · WINSZ_OK 24x80 · CTTY_CHILD_EXIT=0
PTMX_OPEN=yes errno=0 · PTS_DIR=present · WRITABLE_TMP=yes
```
**`/dev/ptmx` is available and a forked child can take the controlling terminal.** There is **no sandbox
reason to defer pty-tier tests.**

→ **T15 design decision: `pty`-tier tests go in `nix flake check`.** Only `fixture`-tier (real ssh /
remote herdr) is excluded from CI. Corrects the earlier assumption that pty might not survive the sandbox.

## OPEN — parity rows for lane P, owed by S (do NOT lose these)
P deliberately did **not** touch `tests/parity.tsv` (not its lane). Rows ready to add, **additive, not
transfers** — S must re-verify the arithmetic with its own script:
```
pty  pty  width-parity table (tb_wcwidth vs python)   67   T3  frozen reachable set + recorded divergence record
pty  pty  pty alloc/resize/ctty/teardown             27   T3  interrogability probes
pty  pty  Screen emulator (ported, unit-tested)      73   T4  no byte-grep anywhere in the lane
```
Ledger groups: `width_test`, `ffi_test`, `screen_test`.

**Verification note for whoever adds these:** `HS_TALLY` lines are **cumulative snapshots per test**, so
summing distinct lines **double-counts** (naive sum of the 24 lines gives 820; the correct
**max-per-group** total is **167**). Use max-per-group, as the gate already does.

## Verified by the orchestrator (not taken on report)
`odin build ./tests/pty -build-mode:test -define:ODIN_TEST_THREADS=1` → **"Finished 24 tests. All tests were successful."**
Max-per-group: width 67 / ffi 27 / screen 73 = **167**, 0 fail.
