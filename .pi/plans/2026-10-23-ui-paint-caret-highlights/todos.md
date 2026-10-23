# TODOS — `ui-paint`

**Plan:** `/home/alexfneves/gits/herdr_session/.pi/plans/2026-10-23-ui-paint-caret-highlights/plan.md`
**Tag:** `ui-paint` (all tasks)
**Created:** 2026-10-23

> **Dispatch note.** Every task carries a `WORKSPACE` line. Do not work outside it.
> **Concurrency cap is 3 agents total (D-I).** The schedule in `plan.md` never needs more than 2.
> **Never `git add -A`** — stage only your own paths.
> **Lanes never edit `tests/parity.tsv`.** Report numbers; the orchestrator folds them (D-D).

---

# LANE A — RCH-10 (nine paint/keyboard changes) — SERIAL

**Workspace for every A task:** `/tmp/wt-ui-paint` on `feat/ui-paint-highlights`
(an opened herdr worktree — bare `git worktree add` is invisible to the human, D-B.)

**Verify after EVERY A task (all four, every time):**

```sh
export PATH=/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/bin:$PATH
cd /tmp/wt-ui-paint
./dev/local-build.sh                                    # ~7.4s, must be clean
BIN=/tmp/hs-local CASES="ui-frame" ./dev/ui-smoke.sh    # RCH-1 proof set
BIN=/tmp/hs-local ./dev/ui-smoke.sh                     # all 6, floor 94/16/12/20/17/11
odin build ./tests/unit -build-mode:test -define:ODIN_TEST_THREADS=1 \
     -define:ODIN_TEST_JSON_REPORT=/tmp/unit.json -out:/tmp/bin_unit && /tmp/bin_unit
```

**Hermetic rows that must never drop below their landed value:** `theme 142 · keyhints 54 ·
render 70 · app 446 · state 270 · diag 10`. Report every delta.

---

### UIP-1 — Rebase the paint worktree and confirm the starting state is what the plan says

**Tag:** `ui-paint` · **Workspace:** `/tmp/wt-ui-paint` · **Depends on:** nothing · **Blocks:** UIP-2..UIP-6

**Do:**
1. `cd /tmp/wt-ui-paint && git rebase main`
2. Confirm the gitignored build deps are still present (they are, verified):
   `clay-odin/clay.odin`, `clay-odin/linux/clay.a`, `vendor/termbox2-odin/lib/libtermbox2.a`
3. Run the four-command verify block above.

**Expected, exactly:**
- build clean in ~7.4 s
- `dev/ui-smoke.sh` → **6/6 PASS**, per case: `ui-frame 94 · ui-sessions 16 · ui-shrink 12 ·
  ui-edit 20 · ui-list 17 · ui-float 11` (total 170)
- `~/.config/herdr_session.json` md5 still `0cce060b885d2796d87ef1f4fd8d98b5`

**If any of these differ, STOP and report.** The whole lane's floor is calibrated to these numbers.

**Anti-pattern:** proceeding past a red starting state because "it's probably my change later."
It isn't yours; it's an unreported drift.

---

### UIP-2 — Palette: 13 → 19 semantic roles (foundation for everything else)

**Tag:** `ui-paint` · **Workspace:** `/tmp/wt-ui-paint` · **Depends on:** UIP-1 · **Blocks:** UIP-3, UIP-4, UIP-5

**Files owned:**
`src/app/theme.odin` (struct `Palette` at `:86-99`, `PALETTE_SLOTS` at `:104`, all 10 `THEMES`
entries at `:169+`), `src/ui/frame.odin` (`Palette`, `palette_of` at `:58-73`,
`DEFAULT_PALETTE` at `:82-96`), `src/theme_cases.odin` (legacy slot-count assertion),
`tests/unit/theme_set_test.odin`, `tests/unit/theme_resolve_test.odin`.

**Add 6 slots** (see the note on the count below), each filled in **all 10 themes** and in
`DEFAULT_PALETTE`:

```odin
// src/app/theme.odin — appended to the existing 13 fields, same style.
key_fg   : u32, // the KEY token in a footer hint — the token the eye hunts for (AD-1.2)
desc_fg  : u32, // the DESCRIPTION token — muted relative to key_fg
caret_bg : u32, // background of the cell the caret sits on
caret_fg : u32, // the caret glyph itself
run_hl   : u32, // the "running" word WHILE its row is selected
stop_hl  : u32, // the "stopped" word WHILE its row is selected
```

Mirror all six into `ui.Palette`, `palette_of` (maps 1:1 by field name) and `DEFAULT_PALETTE`,
and bump `PALETTE_SLOTS` 13 → 19.

**Reference — follow the existing pattern exactly** (`src/ui/frame.odin:58-73`):
```odin
palette_of :: proc(t: app.Theme) -> Palette {
    return Palette{
        bg      = clay_colour(t.pal.bg),
        ...
        stopped = clay_colour(t.pal.stopped),
        // ADD the six here. Field names must match app.Palette exactly —
        // the mapper maps BY NAME, so a skip is a compile error, not a silent miscolour.
    }
}
```

**⚠️ Count deviation from D-M — record it in your report, do not silently deviate.**
D-M says "13 → 18" with a single `state_hl`. A single `state_hl` **cannot satisfy change 5**
("selection must not flatten running/stopped") — with one role, a selected *running* row and a
selected *stopped* row render identically, which is a flattening by another name. **Two roles
(`run_hl` + `stop_hl`) is the only version the requirement can be tested against.** Same
mechanical cost. Total is 19, not 18. Flag it; do not re-litigate it further.

**Falsifiability:** the existing "every theme fills every slot" check fails if any theme omits a
slot. `PALETTE_SLOTS` mismatch fails the count assertion. Neither can pass vacuously.

**Acceptance:** build clean · `theme` row ≥ 142 with the new slot count asserted · all 10 themes
fill all 19 slots · `DEFAULT_PALETTE` complete · `ui-smoke` unchanged at 94/16/12/20/17/11.
*ISC-1*

**Anti-patterns:**
- A slot with no `DEFAULT_PALETTE` value — a nil/absent theme must never paint undefined colour.
- A hex literal anywhere in `src/ui/*` (D-H forbids it).

---

### UIP-3 — Change 5: selection stops flattening running/stopped

**Tag:** `ui-paint` · **Workspace:** `/tmp/wt-ui-paint` · **Depends on:** UIP-2 · **Blocks:** UIP-6

**Files owned:** `src/ui/sessions.odin` (`sess_paint_row`, the block at `:282-290`),
`src/ui_cases.odin` (`ui-sessions`), any new `tests/unit/` selection-colour test.

**Current code being changed (`src/ui/sessions.odin:286-290`):**
```odin
state_fg := fg
if !is_sel {
    if row.running { state_fg = pal.running } else { state_fg = pal.stopped }
}
paint_cell(state_text(row.running), cols.state, state_fg)
```

**Target:** the state word keeps its own colour in **both** states — selected and not:
```odin
state_fg := fg
if row.running {
    state_fg = pal.run_hl
} else {
    state_fg = pal.stop_hl
}
paint_cell(state_text(row.running), cols.state, state_fg)
```
(`run_hl`/`stop_hl` come from UIP-2; they are the accent-legible variants.)

**⚠️ DO NOT ATTEMPT BLENDING / TINT.** Overlay blending has been a **no-op since Phase 2** —
see the comment at `src/ui/sessions.odin:32-37`: a tint request paints *nothing at all*.
Per-cell foreground is the only working model (D-Q).

**The assertion must be positional, not a screen scan** (D-E, D-F). Model the assertion shape on
`render_cell_at` (`tests/unit/render_harness.odin:540-551`), which returns the exact
`{ch, fg, bg}` triple from termbox's **back buffer**:
```odin
// how this fails: if the flatten guard survives, BOTH cells report sel_fg,
// so sel_run == sel_stop and the check cannot pass by accident.
sel_run  := render_cell_at(state_col_x, row_sel_running).fg
sel_stop := render_cell_at(state_col_x, row_sel_stopped).fg
support.check(t, "selection does not flatten running vs stopped",
    sel_run == run_hl_attr && sel_stop == stop_hl_attr && sel_run != sel_stop,
    fmt.tprintf("run=0x{:08X} stop=0x{:08X} sel_fg=0x{:08X}", sel_run, sel_stop, sel_fg_attr))
```
Also assert the **unselected** pair still equals `pal.running` / `pal.stopped`, so the fix cannot
be "the state column is now always the highlight colour" — that would pass the first check and
silently destroy the unselected encoding.

**Acceptance:** selected-run ≠ selected-stop, both via palette roles; unselected pair unchanged;
`ui-sessions` ≥ 16. *ISC-2, ISC-3*

**Anti-pattern:** asserting the colour by grepping the whole screen for a colour name or scanning
all cells for "some cell is green." That is the exact anti-pattern D-F names.

---

### UIP-4 — Changes 3 + 4: fat block caret, arrow-key caret, real terminal cursor

**Tag:** `ui-paint` · **Workspace:** `/tmp/wt-ui-paint` · **Depends on:** UIP-2 · **Blocks:** UIP-6

**Files owned:** `src/ui/edit.odin` (`CARET_GLYPH`/`CARET_TEXT` at `:52-56`, `edit_paint` at
`:371-391`), `src/app/state.odin` (`consume_edit_key` at `:742`, `filter_navigate` at `:873`),
`src/main.odin` (paint tail: `ui.frame_close` → `tb_present` at `:1070-1074`),
`src/ui_cases.odin` (`ui-edit`), new `tests/unit/` caret tests.

**4a — the glyph.** `CARET_GLYPH :: '▏'` → `'█'` (and `CARET_TEXT :: "█"`). Paint it
`caret_fg` over `caret_bg`. **Keep it a real Clay element** — the reason it is a Clay `Text` at
all is that it stays clipped by the enclosing scissor (`src/ui/edit.odin:33-37`). Give the caret
its **own Clay ID** (e.g. `hs.edit.<field>.caret`) so the caller can read its absolute box back
after layout with `clay.GetElementData(clay.ID(...))` (`clay-odin/clay.odin:493`).

**4b — arrow keys.** `edit_left` / `edit_right` **already exist** (`src/ui/edit.odin:266` and
`:281`), move one whole rune, and are **currently called by nothing**. Wire them in. The key
kinds already arrive: `KEY_ARROW_LEFT → .left`, `KEY_ARROW_RIGHT → .right`
(`src/input/keymap.odin:100-101`). Add `case .left:` / `case .right:` to **both**
`consume_edit_key` (name field) and `filter_navigate` (`src/app/state.odin:873`) — follow the
existing `case .backspace:` shape in each.

**4c — the real cursor + blink.** After `frame_close` returns and `tb_present()` runs, place the
terminal cursor on the caret cell and request a blinking block:
```odin
tb.tb_set_cursor(caret_cx, caret_cy)               // emits ESC[<cy+1>;<cx+1>H
buf := []u8{0x1b, '[', '3', ' ', 'q'}             // DECSCUSR, blinking block
tb.tb_send(raw_data(buf), c.size_t(len(buf)))
```
In any state with **no** visible caret: `tb.tb_hide_cursor()` (`termbox.odin:282`).

**Verified FFI gotcha (measured this pass):** `tb.tb_send` will **not** take a string literal —
`Error: Cannot convert '"\x1b[3 q"' to 'rawptr'`. Use the explicit `[]u8` + `raw_data()` form
above.

**ONE-SHOT AT PAINT TIME. NO APP TIMER.** A timer breaks the frozen
`idle ≤ 2 ticks / 5 s` floor (D-K). Emit once per frame.

Emit **after** `tb_present()`. If measurement shows termbox's own sequence overrides it, move it
before `tb_present()` — and **record which order you landed on and why.**

**Assertions (machine-testable half — all must be written):**
- caret cell glyph is the block, not `▏` — at the **derived** column, via `render_cell_at`
- caret cell fg == `caret_fg` **AND** bg == `caret_bg` (requirement 4 is both, not either)
- derived caret column == display width of the prefix (the rule already in `edit.odin:300`)
- Right then Left returns the caret to the same derived column (whole-rune stepping, CJK + astral)
- the wire contains `ESC[<cy+1>;<cx+1>H` **for the caret cell specifically**
- the wire contains `ESC[3 q`

**Anti-vacuity warning:** asserting "some CUP appeared on the wire" is worthless — termbox emits
CUP for every painted cell. Pin the coordinates of **the caret**.

**Eyeball-only — do NOT encode as an assertion:** that it actually blinks, that the block reads as
"fat", perceived contrast. Record as a named limitation (D-K).

**Acceptance:** `ui-edit` ≥ 20 with the new caret assertions added on top; wire-level CUP + DECSCUSR
asserted; arrow keys move the caret in both the name field and the filter. *ISC-4, ISC-5, ISC-6*

**Anti-patterns:** `tb_set_cell` smeared over the layout (breaks the Clay→render.paint frame
rule); an app-side blink timer; asserting blink through the pty emulator's cursor
(measured: after a full stream the emulator's `cx/cy` reads **0,0** because termbox's shutdown
escapes move it — the emulator parses-and-ignores DECSCUSR with `dropped=0`).

---

### UIP-5 — Changes 7 + 8(AD-1) + 9(AD-2): the footer as coloured spans

**Tag:** `ui-paint` · **Workspace:** `/tmp/wt-ui-paint` · **Depends on:** UIP-2 · **Blocks:** UIP-6
**⚠️ ONE PASS, not two (AD-4).** Two passes would break the landed 54 twice.

**Files owned:** `src/ui/keyhints.odin` (all `KEYS_*` tables `:33+`, plus new display strings),
`src/ui/frame.odin` (`Key_Hint` `:215`, `keys_line` `:591-627`, `keys_joined` `:641`,
`SEP` `:631`, `frame_footer` `:545-573`), `tests/unit/keyhints_test.odin` (floor 54, width
sweep at `:149-179`), `src/main.odin` (`tui_keys` `:1155`).

**Target format:** `Description: key`, units joined by ` | `.
**Two-tone:** `desc_fg` on the description, `key_fg` on the key. **The key stays the visually
dominant token** (AD-1.2) — the user scans for an action and reads off the key.

**Spans become the source of truth**, so colour and text cannot disagree:
```odin
Footer_Span_Kind :: enum { .desc, .key, .sep }
Footer_Span     :: struct { text: string, kind: Footer_Span_Kind }

footer_spans :: proc(keys: []Key_Hint, max: i32) -> [dynamic]Footer_Span
keys_line     :: proc(keys: []Key_Hint, max: i32) -> string  // join(footer_spans(...))
```
`frame_footer` then renders **per-kind colour** instead of one `pal.dim` Text (replacing the
single-hue call at `src/ui/frame.odin:571`).

**AD-2 — display strings are NEW and SEPARATE.** Do **not** derive a shortcut label from RCH-9's
`state_label` (which returns "Name remote session" etc.). Extend this mapping to **every**
shortcut — leave none on the old pattern:

| key | shortcut description | state |
|---|---|---|
| `r` | New remote | `remote_server` |
| `s` | **New named remote** | `name_remote_named` |
| `a` | Attach | `attach` |

**What genuinely changes and must be RE-MEASURED, not assumed (AD-3):**
1. **Unit width.** `New remote: r` ≠ `r new remote`. The 8-width sweep
   (`{120,100,80,60,40,30,20,10}`) moves: which hint survives at 10/20/30, and where `theme`
   crosses its own threshold, must be re-derived against the new units.
2. **Separator cost.** ` | ` is **3 cells** per join vs today's `  ` = 2 cells. N hints cost
   **N-1 more cells.** Re-verify the never-blank rule and exit-hint survival at **40 columns**,
   not just 100 — 40 is `MIN_COLS` (`src/terminal/resize.odin:56`), the smallest supported
   terminal.
3. **Where the eye lands.** The key moves from leading to trailing inside each unit.

**What does NOT need "fixing" (AD-3) — leave it alone:** `keys_line` **already** drops whole hints
and never half a hint, and its retention rule is **table-order-based** ("keep the hints nearest the
exit"), not format-based (`src/ui/frame.odin:576-600`). Inverting each unit's internals preserves
the exit-visibility contract intact.

**Falsifiability — the truncation predicate must be rewritten for the new atom.** The existing
`no_half_hint` splits on the old separator; under ` | ` it would mis-slice. The new predicate
must split on `" | "` and require **every** visible piece to contain `": "`, so a
`"Description:"` with no key, or a bare key, fails:
```odin
// how this fails: if truncation ever emits "Attach: " with no key, or a bare "a",
// a piece without ": " appears and partial > 0.
parts := strings.split_to_line(line, " | ")
partial := 0
for p in parts { if p == "" || p == "…" { continue }
                if !strings.contains(p, ": ") { partial += 1 } }
```

**Acceptance:** `keyhints` row **≥ 54** with the numbers re-derived (report the delta and the
reason: "AD-1 unit-width change"), every width green including **40**, no half unit, exit hint
present at every width the atom can fit. *ISC-7, ISC-8, ISC-9*

**Anti-patterns:** implementing the colour change and the format change as separate passes;
deriving shortcut text from `state_label`; leaving any table on `key action` order.

---

### UIP-6 — Changes 1 + 2 + 6: dedicated spine rules, with the row accounting that follows

**Tag:** `ui-paint` · **Workspace:** `/tmp/wt-ui-paint` · **Depends on:** UIP-2..UIP-5 all in
the branch · **Blocks:** the Lane A merge
**⚠️ HIGHEST-RISK TASK IN LANE A. Deliberately last. Do the row arithmetic on paper first.**

**Files owned:** `src/ui/frame.odin` (`FRAME_GAP` `:68`, `HEADER_ROWS` `:74`,
`FOOTER_ROWS` `:75`, `RULE_ROWS` `:76`, `frame_layout` `:96-106`, ROOT config `:474-494`,
header element `:503-521`, footer element `:545-573`), `src/main.odin` (`session_body`
`chrome`/`body` at `:1088-1095`, `picker_body` `visible` at `:1122`, `edit_body` at `:1098`),
`src/ui/sessions.odin` (filter line `:197-213`), `src/ui_cases.odin` (`ui-frame` rule
assertions `:434-447`, `:624-631`, hardcoded index `:604`; `ui-shrink`),
`tests/it/resize_*.odin` (`rh_rule_count` at `resize_harness.odin:348-358`),
`tests/unit/render_fixture.odin` + `tests/probe/render_fixture.odin` (`RENDER_FRAME_GAP`).

**MEASURED BASIS (probe run this pass, then deleted).** A `SizingFixed(1)` element carrying only
`border.width.bottom = 1`, under a ROOT with `childGap = 0`, renders like this at 120 cols:
```
row 0: TITLE
row 1: Mode selection
row 2: ───────────────  (120/120 cells, border colour)   ← NO blank row
row 3: BODYROW
stats: borders=1  rules=0  rects=1
```

**Design:**
- ROOT: `padding = 0`, **`childGap = 0`**, and **remove `border.width.betweenChildren`**.
- Dedicated rule elements: `RULE_TOP_ID` (header→main), `RULE_BOT_ID` (main→footer), plus one
  under each filter/edit surface (change 1 and change 2).
- Each: `SizingFixed(1)` + `border = clay.BorderElementConfig{color = pal.border,
  width = clay.BorderWidth{bottom = 1}}`.

**New row arithmetic — every added rule consumes a row. Update every consumer or the table paints
over the rule:**
```
l.rule_top  = FRAME_PAD + HEADER_ROWS                       // directly under the state word
l.main_y    = l.rule_top + RULE_ROWS
l.main_rows = rows - (FRAME_PAD + HEADER_ROWS + RULE_ROWS + RULE_ROWS + FOOTER_ROWS + FRAME_PAD)
l.rule_bot  = l.main_y + l.main_rows                         // directly above the footer
l.footer_y  = rows - FRAME_PAD - FOOTER_ROWS
```

**Consumer sites that MUST follow (all verified present today):**
- `src/main.odin:1090-1092` — `chrome: i32 = 1` (+1 if `show_filter`) → **now +1 per rule row**
- `src/main.odin:1122` — `visible := l.main_rows - 1` (picker) → **now `- 2`** (filter line + rule)
- `src/ui_cases.odin:604` — hardcoded `first = l.main_y + 2` → re-derive
- `MIN_ROWS = 10` (`src/terminal/resize.odin:57`) and `MIN_COLS = 40`

**Do this on paper before coding:** at `rows = 10`, with the new rule elements, what is
`main_rows`? Then `body = main_rows - chrome` for the *filter-shown* case? **If either is ≤ 0
you have underflowed the table at the smallest supported terminal.** Write the numbers down and
assert them in the test.

**D-L — SYMMETRY IS MANDATORY.** Apply the identical mechanism at **both** spine boundaries.
Fixing only the top makes two halves of one spine look different — a new defect replacing an old
one. If the bottom boundary does **not** exhibit the same defect, **confirm that explicitly in
your report** rather than assuming.

**RE-DERIVE THE RENDER STATS HONESTLY (D-N).** The probe measured the inversion: moving the rule
to a dedicated element changes `{rules: 2, borders: 1}` → `{rules: 0, borders: N}`.
`render.Stats.rules` counts `draw_rule` calls from the `betweenChildren` fill-rect path
(`src/render/renderer.odin:503`); a rule drawn by `render_border`'s bottom side
(`src/render/renderer.odin:602-608`) counts as a **border**. Therefore:
- `st.rules >= 2` (`src/ui_cases.odin:626`) — **expect `rules` to fall to 0.** Say so out loud.
- `st.borders == 1` (`src/ui_cases.odin:629`, the landed RCH-1 assertion) — becomes the count of
  dedicated rule elements.
- **Never assert which Clay internal produced the rule.** Assert the rendered property: "a `─`
  rule occupies row N, and the row that used to be blank is now the rule."
- **Model to follow:** `rh_rule_count` (`tests/it/resize_harness.odin:348-358`) counts rendered
  `─` rows and is already mechanism-independent.

**Rewrite the `DO NOT LOWER` guard comment at `frame.odin:68`.** Do not delete it. State what
invariant now protects the layout (no `betweenChildren` rule exists any more, so the old
"rule lands on the next child's first row" hazard cannot recur) and what must be revisited if
`betweenChildren` is ever re-enabled.

**Acceptance:** `ui-frame` ≥ its landed count with every rule asserted **by row position**;
`ui-shrink` ≥ 12; resize IT suite (`tests/it/resize_*`) still green through `rh_rule_count`;
`main_rows > 0` asserted at `MIN_ROWS`; both spine boundaries handled identically.
*ISC-10, ISC-11, ISC-12*

**Anti-patterns:** lowering `FRAME_GAP` to close the empty row (the guard exists because that
makes the `betweenChildren` rule overwrite content — the dedicated-element mechanism replaces the
need for the trick); asserting the Clay mechanism instead of the rendered position; fixing only
the top boundary.

---

# LANE A CLOSE-OUT (orchestrator, not a worker)

1. Full re-derivation report: per-case counts for all 6 legacy cases + every landed hermetic row,
   against starting values, each delta attributed to a specific RCH-10 change (D-D).
2. Merge `feat/ui-paint-highlights` → `main`. **Stop and report if not cleanly mergeable** — do
   not paper over conflicts.
3. Fold `tests/parity.tsv`: `ui` 168 → measured (note the pre-existing `94 vs 92` drift
   explicitly), `keyhints` 54 → measured, `theme` 142 → measured.
4. **Cleanup, all three steps:** `herdr worktree remove /tmp/wt-ui-paint` → `git worktree remove
   /tmp/wt-ui-paint` → `git branch -d feat/ui-paint-highlights`. Verify `git worktree list`
   shows only the main checkout.
5. **Eyeball pass before merge** (see the eyeball protocol at the bottom of this file).

---

# LANE B — RCH-11 (destroy on handoff return)

**Workspace:** a NEW opened herdr worktree, e.g. `/tmp/wt-destroy`, branch
`feat/destroy-on-return`. Created with `herdr worktree create`/`open` — **not** bare
`git worktree add` (D-B).
**Starts only after the Lane A merge and cleanup.**

---

### UIP-7 — Destroy the session when herdr hands the terminal back (create AND attach)

**Tag:** `ui-paint` · **Workspace:** `/tmp/wt-destroy` · **Depends on:** Lane A merged ·
**Blocks:** UIP-8 (T12) and the T14 `tui:fixture` row

**Files owned:** `src/app/herdr.odin` (`DEFAULT_CLEANUP_POLICY` `:837`, `cleanup_should_run`
`:859-867`, `delete_session` `:758-808`), `src/app/exec.odin` (`post_detach` `:384-415`,
`do_launch` `:198-211`, `do_attach` `:240-266`, `cleanup_argv` `:358`),
`src/main.odin` (`tui_run_command` `:580`), `tests/unit/app_cleanup_test.odin`,
`tests/unit/app_detach_test.odin`.

**Current, verified:**
```
do_launch  -> run_child -> post_detach(device, name, we_created = true)    exec.odin:209
do_attach  -> run_child -> post_detach(device, name, we_created = false)   exec.odin:265
post_detach -> cleanup_should_run(policy, name, we_created) -> run_capture(stop + delete)
DEFAULT_CLEANUP_POLICY = Cleanup_Policy.only_created                        herdr.odin:837
cleanup_should_run:  never->false   only_created->we_created_it   always->true
```

**Required end state (user-amended RCH-11):**
1. **`DEFAULT_CLEANUP_POLICY` → `.always`.** Create **and** attach both destroy on return. The
   earlier data-loss objection was explicitly withdrawn: closing the terminal is how you keep herdr
   running, so the return path is free to destroy.
2. **`cleanup_should_run` gains a `HERDR_SESSION` refusal that outranks every policy**, sitting
   beside the existing `default` refusal at `:860`. Getting this wrong kills the user's own
   session and our own process — so it must be an explicit, asserted refusal, not an implicit
   consequence of the caller happening not to ask.
3. **Route through `app.delete_session(rows, device, name, timeout)`**, not the hand-built
   `cleanup_argv` + `run_capture`. `delete_session` (`herdr.odin:758`) *is*
   `herdr session delete --json <name>` underneath, plus stop-before-delete, name validation, and
   the model pre-check. Use it as-is.
4. **Record the handed-off `(device, name)`** at the `launch_argv` / `attach_argv` site so the
   return path deletes that exact target — never re-derived from whatever is selected on screen.

**⚠️ THE HARDEST PART — the pre-check conflict. Decide this explicitly and report your choice.**
`delete_session` **refuses any identity not present in the `sessions` slice it is given**
(`src/app/herdr.odin:768-775`: `"{} is not in our list for {} — nothing was deleted"`).
At the moment a handoff returns from a **create**, the newly created session is **not in our
model** — so a literal `delete_session(stale_model, …)` **refuses and the session leaks.**

| Option | Verdict |
|---|---|
| **(a) Refresh that device's list synchronously before deleting; pass the fresh rows** | **CHOSEN.** Keeps the pre-check meaningful: if the row is genuinely gone we honestly report "nothing was deleted" rather than claiming a delete. Costs one extra list call per handoff return. |
| (b) Synthesise a one-row model from the handoff record | **REJECTED.** Weakens the pre-check to "we assert it exists" — reintroduces exactly the `deleted:true` trust the requirement forbids. |
| (c) Keep `cleanup_argv` + `run_capture` | **REJECTED.** Contradicts the user's explicit "go through `delete_session`". |

**If (a) turns out unworkable in practice: STOP AND REPORT. Do not silently fall back to (b).**

**Tests required.** Every one asserts the **actual session state after the run, by re-listing** —
never merely that a delete command was issued (D-E):
- create → handoff returns → session **absent** from a fresh list
- attach to a **pre-existing** session → handoff returns → session **absent**
- **`HERDR_SESSION` refused on the destroy path** — asserted explicitly, because the failure mode
  is killing the user's own session
- `default` refused (existing D12)
- remote deleted via its **remote device path**; a local session sharing the name **untouched**
  (`src/app/herdr.odin:708-712` documents this footgun)
- **SIGTERM during a handoff destroys NOTHING.** This is a real test, not a comment — assert the
  session **survives**. `install_terminal_restore_handlers` (`src/terminal/handoff.odin:309-312`)
  restores the *terminal* on SIGTERM/SIGHUP and must **not** gain a destroy call. Without this
  test, a future contributor will "helpfully" add exit-path cleanup.
- herdr's `deleted: true` for a never-existing name is **not trusted** — the model decides

**Hard prohibitions:** NO signal handlers for this feature. NO crash ledger. NO orphan sweep.
NO created-by-us snapshot (the user explicitly overrode that hedge — do not re-introduce it).

**⚠️ CONTRADICTION C-3 — flag it in your report, do not re-litigate it.**
This lane **reverts a landed, live-tested behaviour.** `adt_r1_only_created_destroys_ours_spares_theirs`
(`tests/unit/app_detach_test.odin:156`) currently asserts that a *merely attached* session
**SURVIVES** (its half-2 comment at `:203` says so verbatim). The amendment makes that assertion
**wrong by design.** The amendment is user-authoritative and stands, but the landed `app` row
(444→446) carries the old contract and **must be re-derived explicitly as a consequence of
RCH-11**, in the user's words, not quietly edited.

**Acceptance:** all six test bullets pass with post-run state verification; no signal handler added;
the landed `app` delta reported with the C-3 note. *ISC-13 … ISC-18*
**Orchestrator:** add a NEW additive `destroy` row to `tests/parity.tsv` — this behaviour has no
bash predecessor.

---

# LANE C — Test-migration completion — MAIN worktree, STRICTLY SERIAL

**Workspace for every C task:** `/home/alexfneves/gits/herdr_session` on `main`.
**One lane at a time. The orchestrator never merges into `main` while a test lane is live (D-B).**

---

### UIP-8 — T8: port the `ui` suite, floor 168 (re-derived under RCH-10)

**Tag:** `ui-paint` · **Workspace:** main · **Depends on:** Lane A merged · **Blocks:** UIP-9, T14

**Blocked by RCH-10 — not a preference (D-A, D-P).** ~89% of this floor (≈149 of 168) sits on
the footer hint-width sweep that UIP-5 rewrites, plus the caret (UIP-4) and the rule geometry
(UIP-6). Porting before the merge means porting twice.

**Files owned:** new `tests/unit/ui_*.odin` (6 cases), new `tests/unit/ui_harness.odin`.
**Source:** `dev/ui-smoke.sh` + `src/ui_cases.odin` (delete nothing — that is T17).

**Per-case floor, EACH INDIVIDUALLY** — not just the total, so a loss in one case cannot be hidden
by a gain in another. Baseline `frame 92 · sessions 16 · shrink 12 · edit 20 · list 17 ·
float 11 = 168`; the current tree measures `94/16/12/20/17/11`. **Re-measure on the merged
branch and hold to that number.**

**Harness requirement (do not skip):** use the **openpty + `tb_init_rwfd(slave, slave)` pattern**
from `tests/unit/render_harness.odin:245-320`, **NOT** `tests/support/terminal.odin::enter_terminal`.
`enter_terminal` calls `tb_init()` → `/dev/tty` → **`-4 ENXIO`** under the gate/CI (documented at
`render_harness.odin:8-16`) and gives no readable byte stream.

**Keystroke feeding:** the **1-second delay is load-bearing and documented** (`ui-smoke.sh:38-45`)
— termbox consumes pending bytes during `tb_init`, so t=0 input is **eaten**. Preserve it.
Inputs: `ui-sessions`←`api` · `ui-edit`←`a世b😀c` · `ui-list`←`ESC[B ESC[B TAB to` ·
`ui-float`←`CR`.

**`ui-frame`'s count carries the entire RCH-1 proof set** — divider span/purity,
predicted-vs-Clay box equality, `cell_error == 0`, palette opacity, footer never-overflow /
no-half-hint. **If the ported `ui-frame` comes in near 14, you have lost the RCH-1 evidence.**

**Do not port the Clay *mechanism* assertion.** Port the rendered-position assertion (D-N + the
probe finding that `rules` inverts to 0 and `borders` rises). Model on `rh_rule_count`
(`tests/it/resize_harness.odin:348-358`).

**The old pass rule (`ui-smoke.sh:48`) accepts `RESULT: PASS` with ZERO `[PASS]` lines as a green
"(0 checks)" case. NOT portable.** Strong rule instead.

**Single-thread:** `-define:ODIN_TEST_THREADS=1`.

**Acceptance:** per-case ≥ re-derived counts; total ≥ 168; nothing ported by mechanism-assertion.
*ISC-A-1*

---

### UIP-9 — T12: port the `tui` suite, floor 145

**Tag:** `ui-paint` · **Workspace:** main · **Depends on:** Lane A merged AND UIP-7 merged ·
**Blocks:** T14

**Blocked by UIP-7 as well as RCH-10:** it asserts the footer (UIP-5), the state row, **and the
cleanup notices (UIP-7)**. Porting before the merge ports a notice sentence that has already
changed.

**Files owned:** new `tests/it/tui_*.odin` + harness.
**Source:** `dev/tui-smoke.sh` + `dev/tui_drive.py` — **as a list of PROPERTIES only.**

**⚠️ `dev/tui_drive.py` IS STALE against RCH-9 (D-O).** It still expects the footer list-age
token that no longer exists. Transcribing it would port **expectations that can no longer pass.**
Re-derive from the requirements + current paint. Old driver = properties checklist, never needles.

**Step 1 of THIS task is the per-case inventory** — not before it. The floor stays 145 as a
labelled placeholder; mark it `RE-DERIVE BEFORE PORTING (RCH-10 + RCH-11)`.

**Preserve verbatim:**
- **The `ECHILD` proof (O11)** — the guard's boolean only proves what the function said about
  itself; `errno 10` is the proof nothing was forked:
  ```odin
  st: c.int = 0
  kid := posix.waitpid(-1, &st, {.NOHANG})
  check("…and spawned no child at all", kid == -1 && int(posix.errno()) == 10,
      fmt.tprintf("waitpid(-1,WNOHANG) = {} (errno={})", int(kid), int(posix.errno())))
  ```
- **`state(name)` footer marker is `"<state>  ·  "`, NOT the bare word** — `"attach"` appears in
  the key hints, so a bare-word match proves nothing (`tui_drive.py:600-602`).
- **A driver that exits non-zero while logging NO `[FAIL]` is still a failure** (P2-3,
  `tui-smoke.sh:101-104`).
- `mode_filter_immutable`: check **the surface the leak would land on (the filter line) plus the
  effect (row count unchanged)** — a whole-screen single-char scan is worthless (`p` ∈ `pending`,
  `m` ∈ `mode_selection`).
- **`delete_notice` (R-9) must NOT be "simplified"**: it runs against an on-PATH `herdr` shim
  that fabricates one row and sleeps 2 s on stop/delete, asserting `working:` reaches the tty in
  < 1 s, the verdict lands after ≥ 2 s, and **no real session is touched**. Using the real herdr
  makes it unobservable (20 ms) **and risks real sessions**. The shim's contract ports intact.

**Post-RCH-11 note:** the `roundtrip` expectations change — the cleanup notice is no longer
`only_created … left running`, and an **attached** session now disappears. Derive from post-merge
paint, not from the old driver.

**Acceptance:** per-case inventory reported first; floor 145 held or the delta explicitly
re-derived as a consequence of RCH-10/RCH-11. *ISC-A-2*

---

### UIP-10 — T14: the fixture tier — 166 assertions

**Tag:** `ui-paint` · **Workspace:** main · **Depends on:** UIP-8, UIP-9

| Sub-suite | Floor | Content |
|---|---|---|
| `theme` pty | **36** | picker-preselect 7 · apply-persist 7 · corrupt-warning 5 · unknown-theme 5 · sgr-truecolour 4 · black-is-black 3 · remote-from-config 5 |
| `app` fixture | **88** | app-live + fetch-live + discriminator |
| `tui` fixture | **27** | boot-remote + roundtrip + delete-notice |
| `resize` fixture | **15** | selection-shrink × 3 |

**Fixture arming — READ ONLY, three vars, never defaulted** (`tests/support/env.odin:117-135`):
`HERDR_SESSION_TEST_REMOTE` · `HERDR_SESSION_TEST_REMOTE_ALIAS` ·
`HERDR_SESSION_TEST_UNREACHABLE`.
A **partial** fixture is **not armed** — "half a fixture is the state in which a suite quietly
degrades into asserting less." `support.describe_missing()` names which one is absent; use it.
Loopback is verified working (`ssh localhost` → `SSH_OK`, `ssh 127.0.0.1` → `SSH_OK`) but the
vars are **not currently exported**. Arm them in the **lane's own environment only** — never
globally, never persisted.

**`localhost` is a fixture, not a product concept** (`dev/test-remote.md`):
`grep -rn 'localhost|127\.0\.0\.1' src/` must remain **empty**.

**Safety:** scratch sessions `hs-t-*` only. **NEVER** touch live sessions
`2026-10-20-19-16-08-614` / `2026-10-20-21-07-27-640`. Config md5
`0cce060b885d2796d87ef1f4fd8d98b5` must be unchanged after every run.

**Acceptance:** all four sub-suites at floor, armed, **zero skips**. An unarmed run is a
**reported blocker with `describe_missing()` output**, not a silent skip. *ISC-A-3*

---

### UIP-11 — T15: nix wiring — a separate test derivation + `checks` outputs

**Tag:** `ui-paint` · **Workspace:** main · **Depends on:** UIP-8, UIP-9

**Current state (verified): `nix/` has ZERO test wiring** — `grep -n "checks|mkDerivation|doCheck|passthru"
flake.nix nix/*.nix` returns only one `stdenv.mkDerivation` in `nix/package.nix:18`. Nothing
gated.

**Toolchain trap that must be respected.** From `tests/tools/hscheck/HOWTO.md`:
`ODIN_TEST_JSON_REPORT` is a **compile-time `#config`**, not an env var. Setting it in the
child's env does **nothing** — the binary was built with `""` baked in and writes no report.

```sh
odin build ./tests/tools/hscheck/cmd -out:/tmp/hs_check

# ONE build per report path, baked IN at build time
odin build ./tests/unit -build-mode:test \
     -define:ODIN_TEST_JSON_REPORT=/tmp/reports/unit.json -out:/tmp/bin_unit

/tmp/hs_check --parity=tests/parity.tsv --tier=hermetic --report-dir=/tmp/reports/run \
  --suite=ui=/tmp/bin_unit:/tmp/reports/unit.json \
  --suite=keyhints=/tmp/bin_unit:/tmp/reports/unit.json
#                ^ ALWAYS pass the report path explicitly.
```
Omit the `:REPORT_JSON` and the gate looks for `<report-dir>/<ROW>.json`, the binary wrote
somewhere else, and you get a **vacuous `registered=0`** that reads as a pass.
**Many rows may share one binary and one report — `pass` is attributed by ledger GROUP, not by
binary.** And **never sum `HS_TALLY` lines** — one `tests/pty` run line-sums to 7999 where
max-per-group is 218.

**No full `nix flake` rebuild should be attempted casually** — it is long and the nix store is
shared live. Build the check derivation, verify it, report the exact command and output.

**Acceptance:** `nix flake check` (or the equivalent named check) runs the hermetic tier through
`hs_check` in the sandbox and passes, with per-row `registered`/`pass` visible. *ISC-A-4*

---

### UIP-12 — T16: delete the `argv[1]` test dispatch from `src/main.odin`

**Tag:** `ui-paint` · **Workspace:** main · **Depends on:** every suite landed and green

The dispatch switch in `src/main.odin` is what makes the product binary also be the test driver.
Deleting it is what makes the product honest.

**Acceptance:** the built product binary no longer responds to test-case argv; it still launches
normally; the full hermetic tier stays green after the deletion. *ISC-A-5*

**Anti-pattern:** deleting it before a suite is landed, which silently strands that suite's
requirement with no way to run it.

---

### UIP-13 — T17: delete `dev/*-smoke.sh`, `dev/lib.sh`, `dev/*.py` — LAST

**Tag:** `ui-paint` · **Workspace:** main · **Depends on:** UIP-12 · **Gated behind T14/T15/T16**

**Never before T16 (D-J).** These scripts encode the real requirement behind several floors.

Before deleting each file: **confirm every property it asserts exists in a landed Odin suite**, and
list the mapping (file → landed test file). **A property with no landed equivalent is a lost
requirement — report it rather than deleting it.**

Currently present in `dev/` (18 entries — enumerate and account for each in your report):
`ui-smoke.sh · tui-smoke.sh · tui_drive.py · theme-smoke.sh · theme_drive.py · resize-smoke.sh ·
resize_drive.py · app-smoke.sh · handoff-smoke.sh · render-smoke.sh · state-smoke.sh ·
device_discriminator.py · stream_order.py · lib.sh · local-build.sh · device-discriminator.md ·
test-remote.md · wip/`.

`local-build.sh` is the **dev build entry point** used by every lane in this plan — confirm
whether it is in scope before deleting it, and report the answer rather than guessing.

**Acceptance:** nothing deleted with an unmapped property; a file-by-file mapping table in the
report. *ISC-A-6*

---

### UIP-14 — T18: final honest parity report

**Tag:** `ui-paint` · **Workspace:** main · **Depends on:** everything

Landed total vs floor, **per row**, with **every** delta explained and named
("consequence of RCH-10 change N" / "consequence of RCH-11" / "AD-1 unit width").
Unported properties **named**, not summarised away.

**The report is not allowed to summarise a gap as a pass.**

**Acceptance:** the report exists, every row is accounted for, and no delta is unexplained.
*ISC-A-7*

---

# APPENDIX — Eyeball protocol (part of the Lane A close-out, not optional)

Half of RCH-10 is not machine-verifiable. Do this once, on the merged branch, and record the
result **per change** — not as a single "looks good".

**Setup:** the built binary, inside an **opened herdr worktree**, at **two** sizes:
**40×10** (`MIN_COLS` × `MIN_ROWS`) and **120×40**. Cycle **all 10 themes** (`t` key) at each
size.

| # | Change | What to look at | Machine-covered? |
|---|---|---|---|
| 1 | Rule below the filter | In every state that shows a filter, a rule sits directly under it | ✅ fully |
| 2 | Rule below the edit field | `name_local` / `name_remote_named` | ✅ fully |
| 3 | Fat block caret | Reads as **fat** to a human | ⚠️ shape yes, "fat" is perception |
| 4 | Arrows + caret cell highlight | Cell has **both** bg and fg; arrows move it | ✅ fully |
| 5 | Selection keeps state colour | Running vs stopped still **distinguishable on the accent bar**, per theme | ⚠️ values yes, contrast perception no |
| 6 | Empty row removed | No blank row between the state word and the rule | ✅ fully |
| 7 | Key vs description colour | The **key catches the eye** | ⚠️ colours yes, dominance no |
| 8 | AD-1 `Description: key` + ` \| ` | Format reads correctly at 40 **and** 120 | ✅ fully |
| 9 | "New named remote" | The label reads as expected | ✅ fully |
| — | **Blink** | Does it blink? | ❌ **NOT machine-testable** — terminal + `--cursor` config dependent |

**Record the outcome of every ⚠️ row explicitly.** "Not covered by a test" is a finding, not an
afterthought.
