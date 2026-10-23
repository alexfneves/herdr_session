# Orchestrator decisions — RCH-10 + test-migration continuation

> **HARD LIMIT: maximum 3 concurrent agents at any time (halogen is a local LLM).**
> Count before every spawn. Do not spawn a fourth — wait instead.

Made by the orchestrator. The user is unavailable and explicitly delegated all decisions.
**These bind the planner and all workers. Do not re-litigate them; if one is actually wrong,
record the contradiction loudly rather than silently deviating.**

## D-A — Sequencing: product change BEFORE the big test ports

Do the seven UI changes **first**, as **RCH-10**. Then port `ui`/T8 (168) and `tui`/T12 (145).

Rationale: 313 as-yet-unported assertions touch precisely the dimensions these seven changes
move — caret glyph, row-highlight colour model, horizontal rules, footer colouring, row geometry.
Porting them against the old UI and then again against the new one is the worst available outcome,
and RCH-9 already demonstrated the cost of changing paint under a floor.

Consequence: **no new `ui_*`/`tui_*` test files until RCH-10 is merged.**

## D-B — Where work happens (unchanged, binding)

- **Product/UI changes:** an **opened herdr worktree** (`herdr worktree create/open` — bare
  `git worktree add` does not make it visible to the human).
- **Test porting:** the **main worktree** on `main`, **one lane at a time**. The orchestrator does
  not merge into `main` while a test lane is live.

## D-C — Test adaptation lives INSIDE the product branch

Never merge paint changes and fix the tests afterwards. The branch must land green including its
own test adaptation, so `main` is never red between merge and repair. This is exactly what made
RCH-9 survivable.

## D-D — Floors are RE-DERIVED, never re-asserted, after a paint change

`ui` 168 and `tui` 145 are **pre-RCH-10 numbers**. After the change:
- Rebuild the per-case assertion inventory against the new paint.
- If the new UI genuinely exposes fewer or more checkable properties, record the delta in
  `tests/parity.tsv` **explicitly as a consequence of RCH-10**.
- Never silently lower a floor to get green. A floor that moves is documented; a floor that is
  quietly missed is a lost requirement.

## D-E — Anti-vacuity is mandatory on every new assertion

RCH-9 and T11 each independently uncovered assertions that could not fail:
- a printf guard that scanned "everything logged so far" and passed by running early,
- an `eintr` liveness test that passed because the footer age token made output non-empty,
- an env-scrub test counting an empty room.

Every assertion added for these seven changes must state **how it could fail**, and be demonstrated
falsifiable. Do not assert a colour by grepping the whole screen when the claim is about one cell.

## D-F — Prefer structural assertions over substring needles

RCH-9's best outcome was replacing `"filter:"` with a structural marker (title + state row +
column header, with the negative half asserted on the notice frames). Apply the same standard to:
- separation lines (assert the rule is on a specific ROW, and that the previous layout's empty row is gone)
- caret position (assert the derived column, not that the glyph appears somewhere)
- two-tone footer (assert per-span colour, not that the text contains the key)

## D-G — The blinking-cursor constraint is decided by evidence, not preference

If terminal-driven blink (real cursor) cannot coexist with Clay-clipped painting, do NOT fake it
with an app timer that also breaks clipping. In that case deliver the fat block cursor and record
blink as an explicit, named limitation with the reason — rather than shipping something that
fails under a clipped region or under a screen reader/re-render.

Decide from the scout's finding on `tb_set_cursor` / `TB_CMD_SET_CURSOR` availability.

## D-H — Colour changes go through the palette, not literals

New semantic roles (key vs description fg, caret, state-under-highlight) must be added as palette
entries with theme-resolution + fallback, so `theme`/`colour_wire`/`hygiene` keep meaning
something and a theme change still reaches them. No hardcoded RGB in `src/ui/*`.

## D-I — Agent budget: **at most 3 concurrent agents**

Halogen is a local LLM; parallelism is a hard resource limit, not a preference.
- Never exceed **3** concurrently running agents, counting scouts, planners and workers.
- Workers against a shared repo run **sequentially**; parallelism only across disjoint worktrees.
- Before spawning, count what is already running. If at the limit, **wait** — do not queue a fourth.
- (This supersedes the earlier cap of 4.)

## D-J — Deletion discipline

Do not delete anything under `dev/` — that is T17 and it is gated behind T14/T15/T16.
`dev/*_drive.py` still encodes the real requirement behind several unported floors.
