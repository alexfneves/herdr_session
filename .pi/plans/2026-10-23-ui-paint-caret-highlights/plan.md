# RCH-10 Paint + RCH-11 Destroy + Test-Migration Completion

**Date:** 2026-10-23
**Status:** Ready for dispatch
**Directory:** `/home/alexfneves/gits/herdr_session`
**Todos tag:** `ui-paint`
**Hard concurrency cap:** 3 agents (D-I). This plan never needs more than 2 at once.

---

## Intent

Finish the repo in one continuous, non-overlapping push: land the nine RCH-10 paint/keyboard
changes, land RCH-11 (destroy the session when herdr hands the terminal back), and then carry
the remaining **479 assertions** across from the Python/Bash harness into Odin — without ever
porting a suite twice against two different paints.

## User story

As the operator of `herdr-session`, I want the terminal UI to read cleanly (rules where they
belong, a fat caret I can find, a footer whose keys pop against their descriptions, selection
that never hides whether a session is running), and I want a session I entered through this
program to be gone once I hand the terminal back.

---

## Measured starting position (do not re-guess these)

| Fact | Value | How measured |
|---|---|---|
| Landed `pass_after` total | **1447** | sum of `pass_after` in `tests/parity.tsv` |
| Total floor | **1862** | sum of `floor_before` |
| Remaining | **479** | T8 168 + T12 145 + T14 166 |
| Product build time | **~7.4 s** | `odin build src -out:/tmp/hs-ui-check -o:speed -vet` |
| Legacy `dev/ui-smoke.sh` | **6/6 green** today | `ui-frame 94 · ui-sessions 16 · ui-shrink 12 · ui-edit 20 · ui-list 17 · ui-float 11` |
| Unit binary | **236 tests, 996 tally passes, 39 groups** | `/tmp/bin_unit` max-per-group |
| IT binary | **232 passes** (handoff 67 + resize 165) | `/tmp/bin_it` |
| Live config untouched | md5 `0cce060b885d2796d87ef1f4fd8d98b5` | `~/.config/herdr_session.json` |

> **Note on `ui-frame 94`:** the recorded `ui` floor is 168 built from `frame 92`. The current
> tree measures **94**. That is a +2 drift already present on `main`. It must be reported and
> folded, not silently absorbed.

### Two throwaway probes were run to settle load-bearing unknowns. Both are deleted.

**Probe 1 — can a dedicated 1-row element draw the spine rule with no empty row above it?**
**YES, measured.** A `SizingFixed(1)` element with `border.width.bottom = 1` and ROOT
`childGap = 0` produced:

```
row 0: TITLE
row 1: Mode selection
row 2: ─────────────── (120/120 cells, border colour)   ← no blank row
row 3: BODYROW
stats: borders=1  rules=0  rects=1
```

The decisive consequence is **`rules=0`, not `rules=1`**. `render.Stats.rules` counts
`draw_rule` calls (the `betweenChildren` fill-rect path, `renderer.odin:503`). A rule drawn by
`render_border`'s bottom side (`renderer.odin:602-608`) counts as a **border**. So moving the
spine rule to a dedicated element moves the counts from `{rules: 2, borders: 1}` to
`{rules: 0, borders: N}`. The landed assertion `st.rules >= 2` (`ui_cases.odin:626`) does not
survive the mechanism change and **must be re-derived by position** — exactly as D-N requires.

**Probe 2 — is the real-cursor work testable at all?**
Split verdict, measured on the wire:

- `tb.tb_set_cursor(x, y)` emits **`\x1b[<y+1>;<x+1>H`** — visible on the wire. **Machine-testable.**
- `tb.tb_send(ESC [ 3 SP q)` **lands on the wire**. "We requested a blinking block" is **machine-testable**.
- The pty emulator reports **`dropped = 0`** — it parsed and ignored DECSCUSR silently.
- The emulator's own `cx/cy` after a full stream reads **0,0** (termbox's shutdown escapes move
  it). **Do not assert caret position through the emulator cursor. Assert it through the raw
  wire bytes.**
- Whether the cursor *actually blinks* on a real terminal: **not machine-testable.** Eyeball only.

**Odin gotcha found:** `tb.tb_send` does not accept a string literal (`Cannot convert '"\x1b[3 q"'
to 'rawptr'`). It must be `tb.tb_send(raw_data([]u8{0x1b,'[','3',' ','q'}), 5)`.

---

## Global invariants (every task; repeated deliberately)

1. **Max 3 concurrent agents.** Count before spawning. This plan needs ≤2.
2. **Product changes in an opened herdr worktree.** Bare `git worktree add` is invisible to the
   human (D-B).
3. **Test porting happens in the MAIN worktree on `main`, one lane at a time.**
4. **Test adaptation lives inside the product branch** (D-C). `main` is never red between merge
   and repair.
5. **Lanes never edit `tests/parity.tsv`.** Report numbers; the orchestrator folds them.
6. **Floors are re-derived, never silently lowered** (D-D).
7. **Every new assertion states how it could fail** (D-E) and prefers structural position over
   substring needles (D-F).
8. **No colour literal in `src/ui/*`** (D-H). Everything goes through a palette role.
9. **No app-side timer for blink** (D-K). It breaks the frozen `idle ≤ 2 ticks / 5 s` floor.
10. **Nothing under `dev/` is deleted until T17** (D-J).
11. **Scratch sessions are `hs-t-*` only.** Never touch live sessions
    `2026-10-20-19-16-08-614` or `2026-10-20-21-07-27-640`.
12. **`~/.config/herdr_session.json` must remain md5 `0cce060b885d2796d87ef1f4fd8d98b5`** across
    every test run. The theme hygiene suite enforces this; do not break it.
13. **Odin `for a, b in slice` → `a` is the VALUE, `b` is the INDEX.** Not the reverse.

---

# LANE A — RCH-10 (nine paint/keyboard changes)

**Worktree:** `/tmp/wt-ui-paint` (already exists, already has `clay-odin/clay.odin`,
`clay-odin/linux/clay.a` and `vendor/termbox2-odin/lib/libtermbox2.a` staged)
**Branch:** `feat/ui-paint-highlights`
**Step 0 for the first A-task:** `cd /tmp/wt-ui-paint && git rebase main`
**Rule:** tasks A1→A5 are **strictly sequential** — they share `frame.odin`, `main.odin` and the
`ui-frame` case file. No parallelism inside Lane A.

**Per-task verification (run all of it every task):**

```sh
export PATH=/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/bin:$PATH
cd /tmp/wt-ui-paint
./dev/local-build.sh                                   # ~7.4 s, must be clean
BIN=/tmp/hs-local CASES="ui-frame" ./dev/ui-smoke.sh   # the RCH-1 proof set
BIN=/tmp/hs-local ./dev/ui-smoke.sh                    # all 6 legacy cases
odin build ./tests/unit -build-mode:test -define:ODIN_TEST_THREADS=1 \
     -define:ODIN_TEST_JSON_REPORT=/tmp/unit.json -out:/tmp/bin_unit && /tmp/bin_unit
```

**Expected floor through Lane A:** every legacy case stays ≥ its starting count
(`94/16/12/20/17/11`), and the landed hermetic rows `theme 142`, `keyhints 54`, `render 70`,
`app 446`, `state 270` never drop below their landed value. Deltas are **reported per task**.

---

### A1 — Palette: 13 → 18/19 semantic roles

**Files owned:** `src/app/theme.odin` (Palette struct, `PALETTE_SLOTS`, all 10 `THEMES`
entries), `src/ui/frame.odin` (`Palette`, `palette_of`, `DEFAULT_PALETTE`),
`tests/unit/theme_set_test.odin`, `tests/unit/theme_resolve_test.odin`,
`src/theme_cases.odin` (legacy slot-count assertion).
**Depends on:** nothing. **Blocks:** A2, A3, A4.

**Add 5 slots, each with a fallback:** `key_fg`, `desc_fg`, `caret_bg`, `caret_fg`, `state_hl`.

```odin
// src/app/theme.odin — Palette gains these beside the existing 13.
key_fg  : u32, // the KEY token in a footer hint — the thing the eye hunts for (AD-1.2)
desc_fg : u32, // the DESCRIPTION token — muted relative to key_fg
caret_bg : u32, // background of the cell the caret sits on
caret_fg : u32, // the caret glyph itself
state_hl : u32, // the running/stopped word WHEN the row is selected (see C-1)
```

`PALETTE_SLOTS` must become the new count, and `theme_set_test`'s
`PALETTE_SLOTS matches` assertion re-derived with it. **Every one of the 10 `THEMES` entries
needs all slots filled** — an incomplete theme is exactly what `PALETTE_SLOTS` exists to catch.

**Falsifiability:** the existing `every theme fills every slot` check fails if any theme omits a
slot. `palette_of` maps by field name, so skipping the mapper is a compile error, not a silent
miscolour (the invariant is already documented at `theme.odin:84-86`).

**Anti-pattern:** do not add a slot without a `DEFAULT_PALETTE` value. A nil/absent theme must
never paint an undefined colour.

---

### A2 — Change 5: selection stops flattening running/stopped

**Files owned:** `src/ui/sessions.odin` (`sess_paint_row`), `src/ui_cases.odin`
(`ui-sessions` selection assertions), new assertions in `tests/unit/` if the property is not
already reachable.
**Depends on:** A1.

The flattening is one deliberate condition today:

```odin
// src/ui/sessions.odin:286-290 — CURRENT
state_fg := fg
if !is_sel {
    if row.running { state_fg = pal.running } else { state_fg = pal.stopped }
}
```

Replace with a state that keeps its own colour under selection:

```odin
state_fg := fg
if row.running { state_fg = sel_to_hl(is_sel, pal.run_hl_or_running) } else { ... }
// see CONTRADICTION C-1 for the exact role split
```

**Do NOT attempt blending.** Overlay blending has been a no-op since Phase 2
(`sessions.odin:32-37`): a tint approach paints *nothing at all* (D-Q). Per-cell fg is the only
working model.

**Assertion must be positional, not a screen scan** (D-E/D-F). Assert the fg attribute of the
**state column cells specifically**, on a selected running row and a selected stopped row, and
assert the two differ:

```odin
// how this fails: if the flatten guard survives, both cells report sel_fg and
// sel_a == sel_b -> the check cannot pass by accident.
sel_run  := cell_at(state_col_x, selected_running_row).fg
sel_stop := cell_at(state_col_x, selected_stopped_row).fg
check("selection does not flatten running vs stopped",
    sel_run != sel_stop && sel_run == hl_running && sel_stop == hl_stopped, ...)
```

A whole-screen colour grep would pass forever. That is the anti-pattern named in D-F.

---

### A3 — Changes 3 + 4: fat block caret, arrow-key caret, real terminal cursor

**Files owned:** `src/ui/edit.odin` (`CARET_GLYPH`, `CARET_TEXT`, `edit_paint`),
`src/app/state.odin` (`consume_edit_key`, `filter_navigate`), `src/main.odin` (cursor placement
around `frame_close`/`tb_present`), `src/ui_cases.odin` (`ui-edit`), `tests/unit/` caret tests.
**Depends on:** A1.

**3a. The glyph.** `CARET_GLYPH :: '▏'` → a fat block (`'█'`), painted `caret_fg` over
`caret_bg`. Keep it a real Clay element so it stays clipped by layout (the reason it is a Clay
`Text` at all — `edit.odin:33-37`). Give the caret its **own Clay ID** so its absolute box can
be read back after layout:

```odin
clay.Text(CARET_TEXT, clay.TextElementConfig{textColor = pal.caret_fg})
// inside an element that carries backgroundColor = pal.caret_bg
```

**3b. Arrow keys.** `edit_left` / `edit_right` already exist (`edit.odin:266`, `:281`) and move
one whole rune. Nothing calls them. Wire `.left`/`.right` into `consume_edit_key` (name field)
and `filter_navigate` (filter line). `input.Key` already maps `KEY_ARROW_LEFT/RIGHT`
(`input/keymap.odin:100-101`).

**3c. The terminal cursor + blink.** After `frame_close` returns, read the caret element's
bounding box (`clay.GetElementData(clay.ID(...))`), convert to cells with the painter's scale,
and emit:

```odin
tb.tb_set_cursor(cx, cy)                          // emits ESC[<cy+1>;<cx+1>H  — verified on wire
buf := []u8{0x1b, '[', '3', ' ', 'q'}            // DECSCUSR blinking block
tb.tb_send(raw_data(buf), c.size_t(len(buf)))     // string literal will NOT compile — verified
```
In states with **no** visible caret: `tb.tb_hide_cursor()`.

Order: emit **after** `tb_present()`, so the escape lands last. If termbox's own emit sequence
proves to reset it, move it before `tb_present()` and re-verify — record which was chosen.

**One-shot at paint time. No timer.** A timer breaks the frozen idle floor (D-K).

**Machine-testable half (assert these):**
- the caret cell's glyph is the block, not `▏` (back-buffer glyph at the derived column)
- the caret cell's fg == `caret_fg` **and** bg == `caret_bg` (both, per requirement 4)
- the derived caret column is the display width of the prefix (already the rule in `edit.odin`)
- pressing Right then Left returns the caret to the same derived column
- the wire contains `\x1b[<y+1>;<x+1>H` for the caret cell
- the wire contains `\x1b[3 q`

**Eyeball-only half (do NOT encode as an assertion):** that it actually blinks, that the block
"feels" fat, that the two-tone footer is readable. Record as a named limitation.

**Anti-vacuity note for the CUP check:** assert the escape for **the caret's** cell. Asserting
"some CUP appeared" passes trivially — termbox emits CUP for every painted cell.

---

### A4 — Changes 7, 8 (AD-1) and 9 (AD-2): the footer as spans

**Files owned:** `src/ui/keyhints.odin` (all `KEYS_*` tables + display strings),
`src/ui/frame.odin` (`keys_line`, `keys_joined`, `SEP`, `frame_footer`),
`tests/unit/keyhints_test.odin` (floor 54 — re-derive the width numbers).
**Depends on:** A1. **Must be one pass, not two** (AD-4).

**Target format:** `Description: key`, units joined by ` | `. Two-tone: `desc_fg` on the
description, `key_fg` on the key — the **key stays visually dominant** (AD-1.2).

**Spans become the source of truth.** `keys_line` returns a string today; it must become a
derived projection of a span list so colour and text cannot disagree:

```odin
Footer_Span_Kind :: enum { .desc, .key, .sep }
Footer_Span :: struct { text: string, kind: Footer_Span_Kind }

footer_spans :: proc(keys: []Key_Hint, max: i32) -> [dynamic]Footer_Span
keys_line     :: proc(keys: []Key_Hint, max: i32) -> string   // join(footer_spans(...))
```

`frame_footer` renders per-kind colour instead of one `pal.dim` Text.

**AD-2 display strings are new and separate.** Do **not** derive shortcut labels from
`state_label` (RCH-9). Known mapping, extend to every shortcut:
`r → New remote`, `s → New named remote`, `a → Attach`.

**What genuinely changes (AD-3), and must be re-measured, not assumed:**
1. **Unit width.** `New remote: r` ≠ `r new remote`. The 8-width sweep at
   `keyhints_test.odin:149-179` moves: which hint survives at 10/20/30 cells, and where
   `theme` crosses its threshold, must be re-derived against the new units.
2. **Separator cost.** ` | ` is 3 cells per join vs today's 2 — N hints cost N-1 more cells.
   **Re-verify at 40 columns, not just 100.** 40 is `MIN_COLS` (`resize.odin:56`), the smallest
   supported terminal.
3. **Where the eye lands.** The key moves from leading to trailing within each unit.

**What does NOT need fixing (AD-3):** the existing implementation already drops **whole** hints
and never half a hint, and retention is table-order-based, not format-based. Inverting each unit's
internals preserves the exit-visibility contract. Do not "fix" it.

**Falsifiability:** `no_half_hint` must be rewritten for the new atom — a half unit is a
description with no key, or a bare key with no description. Under the old split-on-`"  "` logic a
` | `-joined unit would mis-slice, so the predicate must split on `" | "` and require each piece
to contain `": "`. Assert it, or the truncation proof silently degrades to nothing.

---

### A5 — Changes 1, 2, 6: the spine rules, with the row accounting that follows

**Files owned:** `src/ui/frame.odin` (`FRAME_GAP`, `HEADER_ROWS`, `FOOTER_ROWS`,
`frame_layout`, `frame_open`, `frame_close`), `src/main.odin` (`session_body`, `picker_body`,
`edit_body`, `chrome`/`visible`/`body` arithmetic), `src/ui/sessions.odin` (filter-line element),
`src/ui_cases.odin` (`ui-frame`, `ui-shrink` — rule positions and hardcoded row indices),
`tests/it/resize_*` (rule-count assertions through `rh_rule_count`).
**Depends on:** A1–A4 merged in the branch. **Highest-risk task. Do it last in Lane A.**

**Measured basis (Probe 1):** ROOT `childGap = 0` + a dedicated 1-row element with
`border.width.bottom = 1` renders a clean full-width rule directly under the state line.

**Design:**
- ROOT: `padding = 0`, `childGap = 0`, **no `betweenChildren`**.
- Insert dedicated rule elements: `RULE_TOP_ID` (header→main), `RULE_BOT_ID` (main→footer),
  plus one under each filter/edit surface.
- Every rule element: `SizingFixed(1)` + `border = {color = pal.border, width = {bottom = 1}}`.

**New row accounting — every added rule consumes a row. Update all three sites or the table
paints over the rule:**

```
l.rule_top  = FRAME_PAD + HEADER_ROWS                        // directly under the state
l.main_y    = l.rule_top + RULE_ROWS
l.main_rows = rows - (PAD + HEADER_ROWS + RULE_ROWS(top) + RULE_ROWS(bot) + FOOTER_ROWS + PAD)
l.rule_bot  = l.main_y + l.main_rows                          // directly above the footer
l.footer_y  = rows - FRAME_PAD - FOOTER_ROWS
```

Consumer sites that must follow (all verified present today):
- `main.odin:1090-1092` — `chrome = 1 (column header) (+1 if show_filter)` → **now +1 per rule**
- `main.odin:1122` — `visible = l.main_rows - 1` (picker) → **now `- 2`** (filter line + rule)
- `ui_cases.odin:604` — `first = l.main_y + 2` — hardcoded index, must be re-derived
- `MIN_ROWS = 10` (`resize.odin:57`): `main_rows` must stay > 0 at the smallest terminal.
  **Do the arithmetic out loud in the task body and assert it.**

**D-L symmetry:** apply the identical mechanism at **both** spine boundaries. If the bottom
boundary does not exhibit the same defect, **confirm that explicitly** rather than assuming
symmetry — a half-fixed spine is a new defect replacing an old one.

**Re-derive the stats honestly (D-N).** Probe 1 measured `borders=1, rules=0` for one dedicated
rule element versus the current `{rules: 2, borders: 1}`. So:
- `st.rules >= 2` (`ui_cases.odin:626`) → becomes the value the new mechanism actually produces.
  **Expect `rules` to go to 0.** Say so.
- `st.borders == 1` (`ui_cases.odin:629`, the landed RCH-1 assertion) → becomes the number of
  dedicated rule elements.
- **Do not assert which Clay internal produced the rule.** Assert the rendered property:
  "a `─` rule occupies row N, and the row that used to be blank is now the rule."
- `rh_rule_count` (`resize_harness.odin:350-358`) counts rendered `─` rows and is already
  mechanism-independent. **That is the model to follow.**

**Anti-pattern:** do not lower `FRAME_GAP` to close the empty row. Probe 1 shows the fix is a
dedicated element; and the current `DO NOT LOWER` guard at `frame.odin:68` exists precisely
because lowering the gap makes the `betweenChildren` rule land on the next child's first row.
The new mechanism replaces the need for the guard; **rewrite the guard's comment to say what
invariant now protects the layout** rather than deleting it.

---

### A6 — Lane A close-out (orchestrator)

1. Full re-derivation report: per-case counts for all 6 legacy cases + all landed hermetic rows,
   against their starting values, with every delta attributed to a specific change.
2. Merge `feat/ui-paint-highlights` → `main`.
3. Fold `tests/parity.tsv` rows: `ui` 168 → measured, `keyhints` 54 → measured, `theme` 142 →
   measured. Each fold carries a note naming the RCH-10 change that moved it (D-D).
4. **Cleanup:** `herdr worktree remove /tmp/wt-ui-paint` **and** `git worktree remove /tmp/wt-ui-paint`,
   then `git branch -d feat/ui-paint-highlights`. Verify `git worktree list` shows only the main
   checkout.
5. Un-mergeable → **stop and report**. Do not paper over it.

---

# LANE B — RCH-11 (destroy on handoff return)

**Worktree:** new, opened with herdr (`herdr worktree create` / `open`), e.g. `/tmp/wt-destroy`
**Branch:** `feat/destroy-on-return`
**Starts:** only after A6 (Lane A merged and cleaned up).
**Rule:** one lane at a time.

**⚠️ This lane reverts a landed, live-tested behaviour. See CONTRADICTION C-3.**

### B1 — Flip the destroy-on-return policy and route it through `delete_session`

**Files owned:** `src/app/herdr.odin` (`DEFAULT_CLEANUP_POLICY`, `cleanup_should_run`),
`src/app/exec.odin` (`post_detach`, `do_launch`, `do_attach`, `cleanup_argv`),
`src/main.odin` (`tui_run_command`), `tests/unit/app_cleanup_test.odin`,
`tests/unit/app_detach_test.odin`.

**Today (all verified):**
```
do_launch  -> run_child -> post_detach(device, name, we_created = true)
do_attach  -> run_child -> post_detach(device, name, we_created = false)
post_detach -> cleanup_should_run(policy, name, we_created) -> run_capture(stop+delete)
DEFAULT_CLEANUP_POLICY = .only_created     (herdr.odin:837)
cleanup_should_run:  never->false  only_created->we_created_it  always->true
```

**Required end state (per the amendment):**
1. Default policy becomes **`.always`** — create **and** attach both destroy.
2. `cleanup_should_run` gains a **`HERDR_SESSION` refusal that outranks every policy**, beside the
   existing `default` refusal. This is the guard that stops the destroy path killing the user's
   own session and our own process.
3. `post_detach` routes through **`app.delete_session(rows, device, name, timeout)`** rather than
   the hand-built `cleanup_argv` + `run_capture`. `delete_session` (`herdr.odin:758`) is the
   same `herdr session delete --json <name>` underneath, plus stop-before-delete, name validation,
   and the model pre-check.
4. Record the handed-off `(device, name)` at the `launch_argv` / `attach_argv` site so the return
   path deletes that exact target rather than re-deriving from the on-screen selection.

**The pre-check conflict — the hardest part of this lane, and a live design question.**
`delete_session` **refuses** any identity not present in the `sessions` list it is given
(`herdr.odin:768-775`). At the moment a handoff returns from a **create**, the newly created
session is **not in our model** — so a literal `delete_session(stale_model, ...)` refuses and
**the session leaks**. Three options:

| Option | What | Verdict |
|---|---|---|
| (a) | Refresh the device's list synchronously before delete, pass the fresh rows | **Recommended.** Keeps the pre-check meaningful: if the row is genuinely gone we report "nothing was deleted" instead of claiming a delete. Costs one extra list call per handoff return. |
| (b) | Synthesise a one-row model from the handoff record | Weakens the pre-check to "we assert it exists" — reintroduces exactly the `deleted:true` trust the requirement forbids. |
| (c) | Keep `cleanup_argv` + `run_capture` | Directly contradicts the user's explicit "go through `delete_session`". |

**Decision: (a).** If the worker finds this unworkable in practice, report it — do not silently
pick (b).

**Tests required (each asserts ACTUAL session state after, by re-listing — not that a delete was
issued):**
- create → handoff returns → session **absent** from a fresh list
- attach (pre-existing) → handoff returns → session **absent**
- `HERDR_SESSION` refused **on the destroy path**, asserted explicitly
- `default` refused (D12)
- remote deleted via its **remote** device path; the local same-named session **untouched**
- **SIGTERM during handoff destroys NOTHING** — so a future contributor cannot "helpfully" add
  exit-path cleanup. This is a real test, not a comment: assert the session **survives**.
- herdr's `deleted:true` for a never-existing name is **not** trusted (model decides)

**No signal handlers. No crash ledger. No orphan sweep.** `install_terminal_restore_handlers`
(`handoff.odin:309`) restores the *terminal* on SIGTERM/SIGHUP and must **not** gain a destroy
call. `dev/tui-smoke.sh:134` is a live test that `herdr-session sigterm` destroys **nothing** —
today it passes because the default is `only_created`; after B1 it must pass because the destroy
is tied to the handoff return, not to process exit.

**Orchestrator:** new **additive** `destroy` row in `tests/parity.tsv` (no bash predecessor).

---

# LANE C — Test-migration completion (MAIN worktree, strictly serial)

**Worktree:** `/home/alexfneves/gits/herdr_session` on `main`.
**One lane at a time. The orchestrator never merges into `main` while a test lane is live.**

### C1 — T8: `ui` hermetic, floor 168 (re-derived under RCH-10)

**Blocked by: Lane A merged.** Not a preference — D-A/D-P. ~89% of this floor (≈149 of 168)
sits on the footer hint-width sweep, which A4 rewrites, plus the caret (A3) and rule geometry
(A5). Porting it before RCH-10 means porting it twice.

**Files owned:** new `tests/unit/ui_*.odin` (6 cases), `tests/unit/ui_harness.odin`.
**Source:** `dev/ui-smoke.sh` + `src/ui_cases.odin`.

- Per-case floor, **each individually** — `frame / sessions / shrink / edit / list / float` at
  their **re-measured post-RCH-10** counts. Baseline was `92/16/12/20/17/11`; the current tree
  measures `94/16/12/20/17/11`. **Re-measure on the merged branch and hold to that.**
- `ui-frame` carries the entire RCH-1 proof set: divider span/purity, predicted-vs-Clay box
  equality, palette opacity, `cell_error == 0`, footer never-overflow / no-half-hint. If the
  ported `ui-frame` comes in near 14, **the RCH-1 evidence has been lost.**
- **Keystroke feeding:** the 1-second delay before input is load-bearing and documented
  (`ui-smoke.sh:38-45`) — termbox eats t=0 input during `tb_init`. Inputs:
  `ui-sessions`←`api` · `ui-edit`←`a世b😀c` · `ui-list`←`ESC[B ESC[B TAB to` · `ui-float`←`CR`.
- Use the **`render_harness` openpty + `tb_init_rwfd` pattern** (`tests/unit/render_harness.odin`),
  **not** `support/terminal.odin::enter_terminal` — the latter opens `/dev/tty`, which fails with
  `-4 ENXIO` under the gate and gives no readable byte stream.
- The old pass rule accepting `RESULT: PASS` with **zero `[PASS]` lines** is **not portable.**
  Strong rule instead.
- **Port nothing about `st.rules`/`st.borders` by Clay mechanism** — port the rendered-position
  assertion (D-N + Probe 1).

### C2 — T12: `tui` hermetic, floor 145

**Blocked by Lane A merged AND Lane B merged.** It asserts the footer (A4), the state row, and
the cleanup notices (B1). Porting before B1 ports a notice sentence that is about to change.

**Files owned:** new `tests/it/tui_*.odin` + harness.
**Source:** `dev/tui-smoke.sh` + `dev/tui_drive.py` — **as a list of properties only.**

**⚠️ `dev/tui_drive.py` is STALE against RCH-9** (D-O). It still expects the footer list-age
token that no longer exists. Transcribing it would port expectations that **can no longer pass**.
Re-derive from the requirements + current paint.

**Floor stays 145 as a labelled placeholder**; mark it `RE-DERIVE BEFORE PORTING (RCH-10 + RCH-11)`
and produce the per-case inventory as the **first step of this task**, not before it.

Preserve verbatim:
- The **`ECHILD` proof** (O11): `waitpid(-1, &st, {.NOHANG})` returning `-1` with `errno == 10`
  is the proof nothing was forked. The guard's boolean only proves what the function said about
  itself.
- `state(name)` footer marker is `"<state>  ·  "`, **not the bare word** — `"attach"` appears in
  the key hints, so a bare-word match proves nothing.
- A driver that exits non-zero logging **no `[FAIL]`** is still a failure (P2-3).
- Single-thread: `-define:ODIN_TEST_THREADS=1`. Widen no threshold.

### C3 — T14: fixture tier, 166 assertions

**Blocked by C1, C2.** Needs the armed remote triple.

| Sub-suite | Floor | Needs |
|---|---|---|
| `theme` pty | 36 | real tty: picker-preselect 7, apply-persist 7, corrupt-warning 5, unknown-theme 5, sgr-truecolour 4, black-is-black 3, remote-from-config 5 |
| `app` fixture | 88 | app-live + fetch-live + discriminator |
| `tui` fixture | 27 | boot-remote + roundtrip + delete-notice |
| `resize` fixture | 15 | selection-shrink × 3 |

Fixture arming is **read-only, three vars, never defaulted**: `HERDR_SESSION_TEST_REMOTE`,
`HERDR_SESSION_TEST_REMOTE_ALIAS`, `HERDR_SESSION_TEST_UNREACHABLE`
(`tests/support/env.odin:117-135`). A partial fixture is **not** armed — `describe_missing()`
names which one is absent. Loopback connectivity confirmed working
(`ssh localhost` → `SSH_OK`, `ssh 127.0.0.1` → `SSH_OK`) but the vars are **not currently
exported**; whoever arms them does it in the lane's own env, not globally.

**`delete_notice` (R-9) must not be "simplified."** It runs against an on-PATH `herdr` shim that
answers `session list` with one fabricated row and sleeps 2 s on stop/delete, asserting `working:`
reaches the tty in < 1 s, the verdict lands after ≥ 2 s, and **no real session is touched**.
Using the real herdr makes the check unobservable (20 ms round-trip) **and risks real sessions.**
The shim's contract ports intact.

**Note:** the `tui:fixture` roundtrip assertion set is directly affected by B1 (the cleanup
notice text changes from `only_created ... left running` to `always ... stopped and deleted`, and
an **attached** session now disappears). Derive from the post-B1 paint, not from the old driver.

### C4 — T15: nix wiring

Separate test derivation + `checks` outputs. **`nix/` currently has zero `checks` wiring** (grep
confirms no `checks`/`passthru`/`doCheck` in `flake.nix` or `nix/package.nix`). Gate through
`tests/tools/hscheck` (`tests/tools/hscheck/HOWTO.md`).

**Critical toolchain trap:** `ODIN_TEST_JSON_REPORT` is a **compile-time** `#config`, not an env
var. The gate must be bound explicitly per row:
`--suite=ROW=BINARY:REPORT_JSON`. Omit the report path and the gate reads
`<report-dir>/<ROW>.json`, the binary writes elsewhere, and you get a vacuous `registered=0`.
**Many rows may share one binary and one report; `pass` is attributed by ledger GROUP.**

**No nix sandbox rebuild should be attempted casually** — it is long, and the live nix store is
shared. Build the check derivation, verify it, record it.

### C5 — T16: delete the `argv[1]` test dispatch from `src/main.odin`

Only after every suite lands and is green. The dispatch switch in `main.odin` is what makes the
product binary also be the test driver; deleting it is what makes the product honest.
Verify the product binary no longer responds to test-case arguments and still runs normally.

### C6 — T17: delete `dev/*-smoke.sh`, `dev/lib.sh`, `dev/*.py`

**LAST. Never before T16.** D-J. These scripts encode the real requirement behind several floors.
Before deleting: confirm every property they assert exists in a landed Odin suite. **A property
with no landed equivalent is a lost requirement — report it rather than deleting it.**

### C7 — T18: final honest parity report

Landed total vs floor, per row, every delta explained. Unported properties named. The report is
not allowed to summarise a gap as a pass.

---

## Dispatch schedule (≤2 concurrent, cap 3)

```
Wave 1:  A1 → A2 → A3 → A4 → A5            (1 agent, sequential, /tmp/wt-ui-paint)
Wave 2:  A6 merge + cleanup                (orchestrator, ~0 agents)
Wave 3:  B1                                (1 agent, /tmp/wt-destroy)  ∥  C1 T8  (1 agent, main)
         ^ disjoint worktrees, so 2 concurrent is legal and productive
Wave 4:  B-merge + cleanup → C2 → C3 → C4 → C5 → C6 → C7   (1 at a time, main)
```

RCH-11 is **never** merged while a test lane that will re-derive against it is mid-flight on `main`.

---

## Explicitly OUT OF SCOPE

- **Signal handlers, crash-reconciliation ledgers, orphan sweeps** — user explicitly forbade (RCH-11).
- **Closing-the-terminal cleanup** — deliberately NOT a trigger. Closing the terminal keeps herdr
  running; that is the other half of the user's choice.
- **Re-tuning `accent` per theme** (D-M) — would regress highlight legibility across 10 themes.
- **Any colour literal in `src/ui/*`** (D-H).
- **App-side blink timer** (D-K).
- **Changing `state_label`'s RCH-9 output to drive shortcut labels** (AD-2) — separate concerns.
- **Blending/tint for the selection highlight** (D-Q) — no-op since Phase 2.
- **Deleting anything in `dev/`** before T17.
- **Lowering any floor to get green** (D-D).
- **Widening any timing threshold** in any suite.
- **New `ui_*`/`tui_*` test files before RCH-10 merges** (D-A).
- **Real-host/network anything** outside the armed fixture triple.
- **touching the two live sessions or the user's config file.**

---

## Risks & open questions (risk-ordered)

| # | Risk | Mitigation |
|---|---|---|
| R1 | **A5's row accounting breaks `MIN_ROWS=10`** — adding rule rows can make `main_rows ≤ 0` at the smallest supported terminal, underflowing the body. | Do the arithmetic explicitly in the task. Assert `main_rows > 0` at 10 rows. `ui-shrink` + the resize IT suite are the net. |
| R2 | **C-3: RCH-11 reverts landed, live-tested `only_created` behaviour.** `adt_r1_only_created_destroys_ours_spares_theirs` asserts a *merely attached* session **SURVIVES** — the amendment makes that assertion **wrong**. | Flagged, not re-litigated. The landed `app` 444→446 row carries the old contract; B1 must re-derive it explicitly as an RCH-11 consequence. **Needs explicit user ack before B1 dispatch.** |
| R3 | **`delete_session`'s model pre-check refuses a just-created session** (it isn't in the stale model), leaking it. | Resolved: option (a) — refresh the device list before deleting. If unworkable, stop and report; do not fall back to a synthesised model. |
| R4 | **Blink is not machine-testable.** The pty emulator parses-and-ignores DECSCUSR (measured `dropped=0`). | Ship both halves; assert emission, not behaviour. Named limitation, per D-K. |
| R5 | **`st.rules` goes to 0 and `st.borders` rises** when the spine moves to dedicated elements — a landed RCH-1 assertion's numbers invert. | Measured in Probe 1, so this is a known re-derivation, not a surprise. Position-based assertions only (D-N). |
| R6 | **A4's ` | ` separator costs N-1 extra cells**; hints drop earlier at 40 columns. | Re-verify the never-blank + exit-hint survival sweep at **40 cols** specifically, not 100. |
| R7 | **`dev/tui_drive.py` is stale vs RCH-9**; transcribing it ports unpassable expectations. | D-O: properties list only, never needles. Per-case inventory is C2's first step. |
| R8 | **`ui-frame` measured 94 vs recorded 92** — a +2 drift already on `main`. | Report it. Fold it explicitly; never absorb it silently into a total. |
| R9 | **Fixture never gets armed**, so 166 assertions silently never run. | `describe_missing()` names the missing var. C3 must report armed/unarmed as a first-class result, not a skip. |

---

## CONTRADICTIONS flagged (not re-litigated — recorded per the dispatch rule)

**C-1 — D-M's single `state_hl` cannot satisfy requirement 5.**
D-M mandates one new role `state_hl` for the state cell under selection. But requirement 5 is
"selection must not **flatten running/stopped**". With a single `state_hl`, a selected *running*
row and a selected *stopped* row render **identical** — that is a flattening by a different name.
**Decision taken: two roles, `run_hl` and `stop_hl`** (palette 13 → **19**, not 18). Same
mechanical cost, and it is the only version the requirement can actually be tested against.
*If the orchestrator holds to 18:* the alternative that still satisfies req 5 is to use the
existing `running`/`stopped` roles directly under selection (**+0 slots**), accepting that some
themes will render them low-contrast on `accent`. Either is defensible; a single `state_hl` is not.

**C-2 — the scout brief's "no machine-testable colour" framing is wrong.**
The brief says the pty emulator "gives no colour verification." True of `tests/pty/screen.odin`
(rune grid). But `render_cell_at` reads termbox's **back buffer** via `tb_get_cell(x, y,
back=1)`, which returns **exact fg and bg attrs** — this is how the landed `render` suite already
asserts colour. So changes 4, 5 and 7 **are** machine-testable for colour, through the back
buffer rather than the screen emulator. The plan uses the back-buffer surface. **Blink and CUP are
wire-level; colour is back-buffer level; only perceived contrast is eyeball.**

**C-3 — RCH-11 as amended reverses a landed, live-tested requirement.** See R2. The existing
`adt_r1_only_created_destroys_ours_spares_theirs` is a green test whose subject behaviour the
amendment explicitly withdraws. The amendment is user-authoritative and stands, but the landed
`app` row's meaning changes and the change must be written into the parity note in the user's words.

---

## Honest verification split (the user asked for this explicitly)

**Machine-testable — must be asserted, and must be capable of failing:**
- Rule presence, row index, span purity (back buffer glyph == `─` across the full width)
- "The row that used to be blank is now the rule" (position, before/after)
- Caret cell identity: glyph, `caret_fg`, `caret_bg` at the **derived** column
- Caret column == display width of the prefix (wide-rune correctness)
- Arrow keys move the caret by whole runes and return to the same column
- `main_rows` / `chrome` / `visible` arithmetic at `MIN_ROWS` and `MIN_COLS`
- Footer: unit-atomic truncation (no half unit), exit-hint survival at 40 cols,
  per-span colour (`key_fg` on key, `desc_fg` on desc — assert the **cell**, not the line)
- Wire: `ESC[<y+1>;<x+1>H` for the caret cell; `ESC[3 q` emitted
- RCH-11: session **absent on a fresh re-list** after handoff return; refusal of
  `HERDR_SESSION`/`default`; correct device routing; nothing destroyed on SIGTERM

**Eyeball-only — record, never encode as a floor:**
- That the caret actually blinks (terminal + `--cursor` config dependent)
- That the block reads as "fat" to a human
- Perceived contrast of `run_hl`/`stop_hl` on `accent` per theme
- That the two-tone footer is readable and the key catches the eye
- Overall visual polish of the rule placement

**Eyeball procedure (part of A6, not optional):** run the built binary in an opened herdr
worktree at **40×10** and **120×40**, cycling **all 10 themes**, checking each of the nine
changes against the checklist above, with the result recorded per change.
