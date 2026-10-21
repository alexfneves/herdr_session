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

---

## D-T6 — `state` lands at 270 against the 259 floor; three findings the next suite inherits

**Delivered (U1, c02e00c + 1250d62).** `tests/unit/state_harness.odin` + `state_machine_test.odin`
+ `state_offline_test.odin` + `state_surface_test.odin` + `state_safety_test.odin`.
Gate run: **270 pass / 0 fail / 0 skip, 43 registered**, stable over 5 consecutive runs;
`nix build .` green. The old bash suite still reports `259 PASS / 0 FAIL`.
The 189 `state-machine` and 54 `state-offline` assertion **names** diff **1:1** against the baseline
logs — 0 missing, 0 renamed, no filler substituted for a real check. The 11 extra are itemised in the
`state` row of `tests/parity.tsv`.

### Finding 1 — `core:os`'s `_environ` duplicates its leading entry on this toolchain

`len(os.environ)` reported **180** over **178** distinct keys: `HOME` appeared twice with the *same*
value. Any assertion of the form "N variables remain" is wrong against the raw slice. Every count and
comparison in `state_offline_test.odin` is **DISTINCT-KEY** based. Anyone porting an environment
assertion later: do not trust the entry count.

### Finding 2 — the offline run must stay IN-PROCESS; `env -i` as a child silently loses the suite

The old shape was `env -i … herdr-session state-offline`, a child process. A child tallies into its
own ledger copy and the parent reports nothing — so porting the child literally would drop
`state-offline`'s 54 assertions out of the suite's count while still printing a green line somewhere.
The swap therefore happens in the process that owns the ledger: all-distinct-key snapshot into a `.bss`
byte pool → **refuse to strip** if the snapshot does not fit (a truncated restore is worse than not
running) → `clear_env` + 3 vars → run → restore → verify key-by-key. Each battery then carries its own
counted proof that its window really was stripped, so "ran offline" is never inherited from a prior case.

### Finding 3 — `SUPPORT-ENV-MU` (a request to S, NOT done here: the support layer is not mine to touch)

There is **no support-wide mutex for environment mutation**. Each offline proc holds its own
`ST_ENV_MU`, which serialises the offline file against *itself* but cannot see the theme suite's
`XDG_WRITE_MU`. **A per-file mutex only covers the files that remember to take it.** The concrete
hazard: a theme XDG swap live while the offline window has `HOME` unset resolves against the
developer's real `~/.config/herdr_session.json`.

`ODIN_TEST_THREADS=1` — already mandated for the unit binary — is what keeps this safe **today**.
Ask: one mutex in `tests/support` that **every** environment mutation in **every** suite takes, so the
safety is structural rather than a coincidence of the thread setting.

### Two notes for T15 (gate wiring)

* Gate rule 7 (`%!` sweep) currently trips on a **pre-existing** `theme_hygiene_test` line
  (`%!(EXTRA <UNSET>)`) **whenever suites share one log file.** Per-suite report files keep that
  failure attributed where it belongs. Nothing in any `state_*` group emits fallout.
* `hs_check` takes the report path as `--suite=NAME=BINARY:REPORT_JSON`. Without `:REPORT_JSON` the
  suite goes red on rule 2 ("registered count unknown") even at a passing assertion total — correct
  behaviour, worth documenting in the T15 wiring so it is not misread as a floor failure.

### What T6 still does not prove (unchanged from the old suite)

That anything appears on a screen, and that the real remote is ever contacted. `state` is the state
machine and the surface only; the pty and fixture tiers own those claims.
