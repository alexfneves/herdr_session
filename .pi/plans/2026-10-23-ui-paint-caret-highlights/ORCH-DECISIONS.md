# Orchestrator decisions — RCH-10 + test-migration continuation

> **HARD LIMIT: maximum 3 concurrent agents at any time (halogen is a local LLM).**
> Count before every spawn. Do not spawn a fourth — wait instead.

Made by the orchestrator. The user is unavailable and explicitly delegated all decisions.
**These bind the planner and all workers. Do not re-litigate them; if one is actually wrong,
record the contradiction loudly rather than silently deviating.**

## ACKS — planner pushed back on three orchestrator assumptions. All three accepted.

### ACK-0 — Dispatch discipline from repeated agent failures (binding on every dispatch)

**4 of the last 6 long-running agents in this session died without producing a result** (scout at 759m,
scout at 6m, planner killed, worker at 523m). Consistent failure mode: **long runs read for hours and
write nothing**, and with no commit the loss is total.

Mitigation for every remaining dispatch:
1. **One task per dispatch.** The last worker was told UIP-1 through 6, completed only UIP-1, died
   mid-UIP-2 with 0 commits and lost ~8h.
2. **Commit before you think.** Land the source change as soon as it builds; tests follow as a second
   commit. Never hold unwritten work across a reasoning step.
3. **WIP commits are fine.** A commit saying what is broken preserves the work. An empty tree preserves
   nothing.
4. **Resume beats restart** when the session still holds expensive computation — the palette values were
   mid-derivation and would otherwise have to be recomputed from scratch.
5. **Verify the tree, not the report.** `git rev-list --count main..HEAD` plus
   `git status --porcelain -uall` settles in one command whether anything survived.

## ACK-1 — D-M is WRONG as written. Use `run_hl` + `stop_hl`, not a single `state_hl`. (palette 13 → 19)

A single `state_hl` makes **selected-running and selected-stopped render identically** — which is
precisely the flattening that change 5 forbids. One colour cannot preserve a distinction it is supposed
to preserve. `run_hl` + `stop_hl` is the only version the requirement can falsify, at the same
mechanical cost. **D-M is superseded on this point.**

### ACK-2 — Colour IS machine-testable. My earlier claim was wrong.

I recorded that colour and cursor are "invisible to the pty emulator" and therefore eyeball-only. The
pty *rune* emulator is indeed blind, but `tb_get_cell(back = 1)` exposes the real back buffer — which
is exactly what the landed `render` suite already asserts against. So per-cell foreground/background,
rule spans and caret colours **are** assertable in CI.

Revised split: **eyeball-only** = that it blinks, that the block reads as "fat", subjective contrast,
key-visual-dominance. Everything else goes through `tb_get_cell`. Do not demote testable properties to
eyeball checks on the strength of my earlier statement.

### ACK-3 — CONTRADICTION C-3: ACKNOWLEDGED. RCH-11 deliberately reverts landed, live-tested behaviour.

`adt_r1_only_created_destroys_ours_spares_theirs` currently asserts that a **merely attached** session
survives. The user's amendment makes that assertion **wrong by design**. The user was explicit:
"This is valid for when we create a session OR when we attach to a session."

Ruling:
1. **The amendment is authoritative.** `DEFAULT_CLEANUP_POLICY` becomes `.always`.
2. **Invert the existing test — do not delete it.** It must be rewritten to assert the NEW contract
   (attached session is destroyed). Deleting it would lose the coverage of the policy mechanism itself.
3. **Re-derive the landed `app` row (444 → 446) explicitly as an RCH-11 consequence**, in the
   parity notes, naming the inverted assertion. A silently edited floor is a lost requirement.
4. Add the `HERDR_SESSION` refusal that **outranks every policy value**, alongside the existing `default`
   refusal. Without it the destroy path can kill the user's own session and our own process — that
   guard is non-negotiable regardless of which policy is default.

### ACK-4 — RCH-11 pre-check leak resolved as the planner chose (option a)

`delete_session` refuses identities absent from the model (`herdr.odin:768-775`), so a just-created
session would leak. **Refresh the device list before deleting.** Workers must **stop and report** rather
than silently falling back to a raw `delete_argv` if the refresh fails — bypassing `delete_session` to
force a delete drops the `default` guard and the never-trust-`deleted:true` check with it.

---

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

## D-K — Blink: ship BOTH halves, and blink is **not** a floor requirement

Decided from scout section A/J1.

- **Shape + pair colour = Clay.** Keep the caret a real Clay element so it stays clipped by layout
  (the reason `CARET_GLYPH` is a Clay `Text` at all). Change `▏` → a fat block.
- **Blink = the terminal's own cursor**, requested with DECSCUSR (`ESC[3 q` / blinking block) via
  `tb_send`. **One-shot escape at paint time — no app-side timer.** An app timer is FORBIDDEN: it
  breaks the frozen `idle <= 2 ticks / 5 s` floor.
- **Blink can never be asserted.** The pty emulator ignores private modes and colour
  (`tests/pty/screen.odin:33-38`), and this machine's `cnorm` explicitly clears blink, hence the
  need for DECSCUSR in the first place. Therefore: implement it, but **do not encode blink as an
  assertion or a floor component.** Test the testable half (block shape, caret cell, pair colours,
  derived column) and record blink as a named, deliberate limitation.
- Also record: blink ultimately depends on the user's terminal/`—cursor` config. That is honest, not a
  failure.

## D-L — Change 6: fix the spine **symmetrically**

Root cause is Clay centring the betweenChildren rule at `child_top - floor(gap/2) - floor(between/2)`
(`clay.h:2861`): with gap=2 the rule lands on row 3 while header content ends at row 1, so **row 2
is the empty line**, and **no `(gap, between)` pair fixes it** — which is exactly what the
"DO NOT LOWER" guard at `frame.odin:68` protects. So the rule must become a 1-row element /
header bottom border.

Decision: apply the **same mechanism to both spine boundaries**. Fixing only the top makes the two
halves of one spine look different, which is a new defect introduced to remove an old one. If the
bottom does not have the same defect, confirm that explicitly rather than assuming symmetry.

## D-M — Palette: add an explicit `state_hl` role; do NOT re-tune `accent` per theme

Re-tuning `accent` changes **every** highlighted element across all 10 themes and can regress the
existing highlight-legibility behaviour broadly and silently. An explicit `state_hl` role is
contained and directly assertable. Since `key_fg`, `desc_fg`, `caret_bg`, `caret_fg` already take
the palette 13 → 17, adding `state_hl` (→ 18) is not a special burden — roughly 10 literal values
per slot per `theme.odin`. All new roles need a fallback so an incomplete theme cannot paint
undefined colour (D-H: no literals in `src/ui/*`).

## D-N — Re-derive the rule assertion by POSITION, not by Clay mechanism

With the top rule moving from `betweenChildren` to a border element, do **not** assert which Clay
internal produced it. The user-visible property is "a `─` rule is drawn at row N, and no empty row
sits between the state and that rule". So:
- assert the **rendered rule rows and their positions**,
- re-derive `st.rules` / `st.borders` expected values from the new layout, honestly,
- keep the existing landed survival check intact — `rh_rule_count` counts rendered `─` rows
  (`resize_harness.odin:350-358`) and is already mechanism-independent. That is the model to follow.

## D-O — T12's floor stays 145 as a labelled placeholder; and its source is STALE

The per-case `tui` inventory was not read this pass, so the re-derived floor **cannot** be set yet.
- Keep `tui` floor at 145 in `tests/parity.tsv` and mark it **`RE-DERIVE BEFORE PORTING (RCH-10)`**
  in the notes so nobody treats it as settled.
- **Bigger hazard:** `dev/tui_drive.py` is already stale against RCH-9 (it still expects the footer
  list-age token that no longer exists). Porting T12 by transcribing that driver would port
  **obsolete expectations that can no longer pass**. T12 must be re-derived from the requirements +
  current paint, using the old driver only as a list of *properties to check*, never as a source of
  needles.
- Schedule the T12 per-case inventory as the first step of the T12 port, not before RCH-10.

## D-P — Sequencing refinement from the scout's size numbers

Scout measured: **~78 of the 92 `ui/frame` assertions are the footer hint-width sweep**, and ~149
of the 168 `ui` assertions touch one of the changed dimensions — only `float` (11) is untouched.
That is ~89% of the `ui` floor sitting on the footer, which the footer redesign rewrites.

This strengthens D-A decisively: **do not start T8 at all until RCH-10 is merged.** There is no
partial-early-start that is safe here.

## D-Q — Change 5 is a narrow edit; do not over-engineer it

The flattening is a single deliberate condition: `state_fg := fg; if !is_sel { running/stopped }`
(`sessions.odin:287-289`). The fix is to give the state cell its own fg under selection
(`state_hl`, per D-M). Note the scout's warning: **overlay blending is a no-op since Phase 2**
(`sessions.odin:32-37`) — any blend/tint approach paints *nothing at all*. Per-cell fg is the only
working model. Do not attempt blending.

## D-I — Agent budget: **at most 3 concurrent agents**

Halogen is a local LLM; parallelism is a hard resource limit, not a preference.
- Never exceed **3** concurrently running agents, counting scouts, planners and workers.
- Workers against a shared repo run **sequentially**; parallelism only across disjoint worktrees.
- Before spawning, count what is already running. If at the limit, **wait** — do not queue a fourth.
- (This supersedes the earlier cap of 4.)

## D-J — Deletion discipline

Do not delete anything under `dev/` — that is T17 and it is gated behind T14/T15/T16.
`dev/*_drive.py` still encodes the real requirement behind several unported floors.
