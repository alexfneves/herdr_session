# RCH-10 — plan: nine UI paint changes (caret / rules / footer / selection) + test-migration sequencing

**Tag:** `ui-paint`
**Plan dir:** `/home/alexfneves/gits/herdr_session/.pi/plans/2026-10-23-ui-paint-caret-highlights/`
**Worktree (BINDING — work here, never in the main checkout):** `/tmp/wt-ui-paint`
**Branch:** `feat/ui-paint-highlights`
**Base:** **current `main`** — the branch tip (`2bc2311`) is currently *behind* `main` (`6aea79a`); the drift is docs-only (RCH-10 orchestrator/decision/scout docs + the new RCH-11 scout docs) and the **product source is identical** between the two (`git diff --stat 2bc2311 main -- src tests` is empty). Before any worker edits anything: **rebase `/tmp/wt-ui-paint` onto `main`**. After rebase the branch base = current `main` and the work continues here.

**Binding inputs, in order (all read; all binding):**
1. `/home/alexfneves/gits/herdr_session/.pi/plans/2026-10-23-ui-paint-caret-highlights/ORCH-DECISIONS.md` — D-A … D-Q (plus D-I … D-L as numbered).
2. `/home/alexfneves/gits/herdr_session/.pi/plans/2026-10-23-ui-paint-caret-highlights/REQUIREMENTS-addendum.md` — AD-1 … AD-4.
3. `/home/alexfneves/gits/herdr_session/.pi/plans/2026-10-23-ui-paint-caret-highlights/scout-context.md` — §A–J, `file:line` citations.
4. RCH-9 record: `/home/alexfneves/gits/herdr_session/.pi/plans/2026-10-18-herdr-session-tui/` — the previous paint change; **match its discipline** (display change + its own on-branch test adaptation + floor re-derived, never silently lowered).

**The user is unavailable and explicitly delegated all decisions.** No clarifying questions. No pauses for confirmation. Every "what should we do" is answered above; this plan is the HOW.

---

## 1. Mission

Land **RCH-10**: nine user-facing paint/keyboard changes to the `herdr-session` Odin TUI, then sequence the remaining test migration (T8/T12/T14) so it runs *after* the paint change instead of against it.

The nine changes:

| # | Change | Status |
|---|---|---|
| 1 | Separation line below the filter wherever the filter is displayed | product |
| 2 | Separation line below the edit field in name-local / name-remote states | product |
| 3 | Fat block caret instead of the thin `▏` line caret | product |
| 4 | Left/Right arrows move the caret; the cell under the caret is highlighted (bg + fg) | product |
| 5 | Row selection highlight must stop flattening the session-state (running/stopped) colour | product |
| 6 | Remove the empty row between the state text and the rule below it | product |
| 7 | Footer: key and description get different colours | product |
| 8 | **AD-1**: footer pattern becomes `Description: key` joined by ` \| ` (inverts today's `key desc`) | product |
| 9 | **AD-2**: "Named remote" → "**New named remote**" | product |

Plus, per the orchestrator: floor re-derivation for `keyhints` (54) and `ui` (168), test adaptation inside the same branch, and the sequencing decision that the big test ports (T8/T12) come *after* RCH-10 (D-A).

---

## 2. Binding decisions — read once, apply always

### D-A — product change BEFORE the big test ports
Do the seven UI changes first as **RCH-10**. Then port `ui`/T8 (168) and `tui`/T12 (145). No new `ui_*`/`tui_*` test files until RCH-10 is merged.

### D-B — where work happens
Product/UI changes: an **opened herdr worktree**. `/tmp/wt-ui-paint` qualifies in spirit (it is the branch the orchestrator opened); test porting: **main worktree on `main`**, one lane at a time. RCH-10 is a product change → all of it in `/tmp/wt-ui-paint`.

### D-C — test adaptation lives INSIDE the product branch
The RCH-10 branch must land green including its own test adaptation → `main` is never red between merge and repair.

### D-D — floors are re-derived, never re-asserted, after a paint change
After RCH-10: rebuild the per-case assertion inventory against the new paint; record deltas in `tests/parity.tsv` **explicitly as a consequence of RCH-10**; never silently lower a floor.

### D-E — anti-vacuity is mandatory on every new assertion
Every new assertion must state **how it could fail** and be demonstrated falsifiable. No whole-screen greps when the claim is about one cell. Demonstrate with negative controls where cheap (the resize suite's SIGSTOP pattern).

### D-F — prefer structural assertions over substring needles
Separation lines: assert the rule is on a specific ROW and that the previous layout's empty row is gone. Caret: assert the *derived column*, not that the glyph appears somewhere. Footer two-tone: assert per-span colour, not that the text contains the key.

### D-G — blink decided by evidence
Ship the fat block + terminal-cursor blink via DECSCUSR (`tb_send`); record blink as a named, deliberate limitation.

### D-K — blink: ship BOTH halves; blink is NOT a floor requirement
Shape + pair colour = Clay; blink = terminal cursor via DECSCUSR, one-shot at paint time, **no app timer**. Blink can never be asserted; test the testable half; record blink as a named limitation.

### D-L — change 6: fix the spine symmetrically
Rule must become a 1-row element / header bottom border, applied at **both** spine boundaries (top AND bottom). No `(gap, between)` pair fixes the top; guard at `frame.odin:68` exists for that reason.

### D-M — palette: add an explicit `state_hl` role; do NOT re-tune `accent` per theme
Add slots with theme-resolution + fallback (D-H). New roles: `key_fg`, `desc_fg`, `caret_bg`, `caret_fg`, `state_hl` → palette 13 → **18**.

### D-N — re-derive the rule assertion by POSITION, not by Clay mechanism
Assert rendered rule rows + positions; re-derive `st.rules` / `st.borders` expected values honestly; `rh_rule_count` (rendered `─` rows, `tests/it/resize_harness.odin:350-358`) is already mechanism-independent → follow it.

### D-O — T12's floor stays 145 as a labelled placeholder; source is STALE
Keep `tui` floor at 145 in `tests/parity.tsv`, mark it **`RE-DERIVE BEFORE PORTING (RCH-10)`**. `dev/tui_drive.py` is already stale against RCH-9 — T12 must be re-derived from requirements + current paint, old driver only as a list of properties.

### D-P — sequencing refinement from scout's size numbers
Scouts: ~78 of 92 `ui/frame` assertions are the footer hint-width sweep; ~149 of 168 `ui` assertions touch a changed dimension; only `float` (11) untouched. Do NOT start T8 until RCH-10 is merged.

### D-Q — change 5 is a narrow edit; do not over-engineer
The flattening is `state_fg := fg; if !is_sel { running/stopped }` (`src/ui/sessions.odin:287-289`). Fix: give the state cell its own fg under selection (`state_hl`, D-M). Overlay blending is a no-op since Phase 2 → per-cell fg is the only working model.

### D-I — agent budget: max 3 concurrent agents (halogen is a local LLM).
### D-J — deletion discipline: do not delete anything under `dev/`.

### AD-1 — footer pattern
Target: `New remote: r | Named remote: s | Attach: a` — **`<Description>: <key>`**, units joined by ` | `. Key stays visually dominant. Description muted, key brighter `key_fg`. Truncation must become unit-atomic.

### AD-2 — terminology
"Named remote" → "**New named remote**". Shortcut descriptions are NEW display strings, separate from RCH-9's `state_label` (which stays "Name remote session" etc.).

### AD-3 — effect on landed `keyhints` floor 54
Unit-internal inversion does **not** break unit-atomicity (already safe). Genuinely changes: (1) unit width (`New remote: r` = 13 vs `r new remote` = 12), (2) key moves to trailing position, (3) separator cost ` | ` = 3 cells vs `  ` = 2. The 8-width overflow sweep (`tests/unit/keyhints_test.odin:149-179`) must be re-measured against new units. Never-blank rule + exit-hint survival at 40 cols must be re-verified.

### AD-4 — change 7 + AD-1 are one subsystem; design together.

---

## 3. The nine changes, in implementation order

### Change 1 — separation line below the filter wherever the filter is displayed

- **Requirement:** wherever the filter line is drawn (`src/ui/sessions.odin` table filter; picker filter via `src/main.odin` `picker_body` → `ui.edit_paint(&tui.filter_ed, "hs.tui.pick.filter", …)`), a full-width `─` separation row appears immediately below it.
- **Sites (three rule sites total, one helper):**
  1. `hs.tui.sessions.filter` — `src/ui/sessions.odin` (the `clay.UI(clay.ID(SESS_HEADER_FILTER_ID))` element).
  2. `hs.tui.pick.filter` — `src/main.odin` `picker_body` (same `ui.edit_paint`, different Clay id).
  3. (change 2 covers the name edit field; see below.)
- **Mechanism:** scout **C.2 route 1** — dedicated 1-row rule element: an empty Clay element, `height = SizingFixed(1)`, with `border = {color: pal.border, width: {bottom: 1}}`. Caveat: counts as a `borders` call, **not** a `rules` call; consumes **one row of MAIN's budget**.
- **Row arithmetic:** `session_body` (`src/main.odin:1090-1092`):
  ```odin
  chrome: i32 = 1 // the column header
  if show_filter { chrome += 1 }
  body := l.main_rows - chrome
  if body < 1 { body = 1 }
  ```
  becomes `chrome = 2` (+filter) + `1` (the new rule) = **3** when a filter is displayed (order: filter, rule, column header, body — so the column header moves down one row too, or the rule is inserted above the header).
- **Phantom-row hazard:** every added row MUST be added to `chrome` / `visible` or a phantom row appears (hazard documented at `src/main.odin:1084-1087`). Same in `picker_body`: `visible := l.main_rows - 1` (`src/main.odin:1123`) → `main_rows - 2`.
- **Tests:** `src/ui_cases.odin` hardcodes the same arithmetic (`body := l.main_rows - 2`, `first = l.main_y + 2`) in several places — all must be re-derived.

### Change 2 — separation line below the edit field in name-local / name-remote

- **Requirement:** a separation line below the single edit field in `.name_local` / `.name_remote_named`.
- **Design decision (planner-made, delegated): the edit-field rule converges with the change-6 spine rework.** In name states MAIN holds one editable row and the spine divider (`rule_bot = main_y + main_rows + FRAME_GAP - 1`) is derived from MAIN's **Grow box**, so it lands far below the edit field rather than immediately under it. The clean expression of "a rule below the edit field" is therefore the **same dedicated 1-row rule element** (C.2 route 1) placed immediately after the edit element inside MAIN — and the spine's top/bottom separators becoming explicit 1-row border elements (change 6) is what makes content-positioned rules coherent at both boundaries.
- **Worker must decide** (and record): rule element directly under the edit field in `edit_body` (`src/main.odin:1098-1103`), with the footer-top separator coming from the new explicit mechanism; nothing in `edit_body` needs a `chrome` row (name states have no table body).

### Change 3 — fat block caret instead of the thin `▏` line caret

- **Requirement:** `CARET_GLYPH :: '▏'` → fat block; `CARET_TEXT :: "▏"` → `CARET_TEXT :: "█"` (or the block-equivalent 1-cell filled glyph).
- **Files:** `src/ui/edit.odin` (`CARET_GLYPH` `:54`, `CARET_TEXT` `:57`, `edit_paint` `:371-390`).
- **Odin sketch:**
  ```odin
  // src/ui/edit.odin — change 3 (+ change 4's pair colours from the new palette)
  CARET_GLYPH :: '█'
  CARET_TEXT :: "█"
  ...
  edit_paint :: proc(e: ^Edit, id: string, width: i32, pal: ^Palette) {
      v := edit_view(e, width)
      if clay.UI(clay.ID(id))({
          layout = clay.LayoutConfig{
              sizing = clay.Sizing{width = clay.SizingGrow(), height = clay.SizingFixed(1)},
              layoutDirection = clay.LayoutDirection.LeftToRight,
          },
          backgroundColor = pal.caret_bg,   // fat block fill (change 4's pair colour)
      }) {
          if len(v.prefix) > 0 {
              clay.Text(v.prefix, clay.TextElementConfig{textColor = pal.fg})
          }
          clay.Text(CARET_TEXT, clay.TextElementConfig{textColor = pal.caret_fg}) // block fg = pair
          if len(v.suffix) > 0 {
              clay.Text(v.suffix, clay.TextElementConfig{textColor = pal.fg})
          }
      }
  }
  ```
- **Clipping:** keep the caret as a Clay `Text` (scissor-obedient, `src/ui/edit.odin:366-368`); the fat glyph is still an ordinary Clay text element, so clipping semantics are unchanged.

### Change 4 — Left/Right arrows move the caret; cell under caret highlighted

- **Requirement:** `KEY_ARROW_LEFT`/`KEY_ARROW_RIGHT` (mapped in `src/input/keymap.odin:100-101`) must move the caret in the edit/filter states; the cell under the caret gets bg + fg highlight like the row-selection highlight.
- **Where the move is missing:** `filter_navigate` (`src/app/state.odin:872-889`) handles `.up/.down/.tab/.shift_tab/.backspace/.character` and **ignores `.left/.right`**; `consume_edit_key` (`src/app/state.odin` ~:744-753, shared by `.name_local` / `.name_remote_named`) likewise has no `.left/.right`.
- **Odin sketch (consume_edit_key gain):**
  ```odin
  consume_edit_key :: proc(a: ^App, k: input.Key) -> Command {
      #partial switch k.kind {
      case .backspace: text_backspace(&a.field)
      case .left:      text_move_left(&a.field)   // NEW: whole-rune step
      case .right:     text_move_right(&a.field) // NEW: whole-rune step
      case .character: …
      }
  }
  ```
  with whole-rune stepping helpers on `app.Text` mirroring `edit_left`/`edit_right` rune-boundary logic (`src/ui/edit.odin:263-293`).
- **Cell under caret (bg + fg):** when the caret is not at end-of-buffer, the character occupying the caret cell is painted with `fg = pal.caret_fg` over the caret block's `bg = pal.caret_bg` (change 3's pair). Implementation site: the suffix `Text` in `edit_paint` — the first rune of the suffix is "under" the caret → paint it with `pal.caret_fg`.
- **Blink:** park the real cursor via `tb_set_cursor(abs_x, abs_y)` in the typing states, `tb_hide_cursor()` on leaving (`src/main.odin:133`, `src/terminal/handoff.odin:181`, `src/main.odin:1335`); one-shot DECSCUSR (`ESC[3 q`) via `tb_send` (`vendor/termbox2-odin/termbox.odin:308`); **no app timer**.

### Change 5 — row selection highlight must stop flattening the session-state colour

- **Requirement:** selected rows keep the running/stopped state colour readable on the accent bar; the highlight must not flatten it.
- **Files:** `src/ui/sessions.odin` (`sess_paint_row`, `state_fg` at `:286-289`).
- **Cost:** LOW + ISOLATED (one condition).
- **Odin fix (minimal, per D-Q/D-M):**
  ```odin
  // src/ui/sessions.odin — sess_paint_row state cell
  state_fg := fg // pal.sel_fg on the accent bar
  if row.running { state_fg = pal.state_hl } else { state_fg = pal.state_hl }
  // i.e. under selection the state cell takes the new `state_hl` role (D-M);
  // off selection it keeps pal.running / pal.stopped.
  ```
  The precise shape (whether `state_hl` is one slot holding the accent-legible state colour, or a per-state pair) is resolved by the palette task; the *behavioural* fix is: **delete the `if !is_sel` guard** so the state cell carries its themed colour under the selection, painting per-cell fg on the row's `pal.accent` bg (`src/ui/sessions.odin:278-291`).
- **Tests:** `src/ui_cases.odin` ui-sessions selection assertions currently read `sel_fg`/`accent` for the whole row → re-express as: device/ts/name cells == `sel_fg` **and** state cell == `running`/`stopped` (now via `state_hl` under selection). Stronger, per D-E.

### Change 6 — remove the empty row between the state text and the rule below it

- **Requirement:** no empty row between the state (header row 2) and the rule below it; fix **symmetrically** (D-L) — also check the footer boundary.
- **Root cause:** Clay centres the betweenChildren rule at `child_top - floor(childGap/2) - floor(betweenChildren/2)` (`clay.h:2861`, `:2877`; gap=2, between=1 ⇒ exactly one row above the following child); with a 2-row header the rule lands on row 3 while header content ends row 1 → **row 2 blank**.
- **Fix:** replace the betweenChildren mechanism with **explicit 1-row rule elements / border sides** (scout D.2 Option 1 recommended: ROOT `childGap = 1` + `betweenChildren = 0` for the top boundary; header becomes `HEADER_ROWS = 3` with row 2 drawn by the header's own `border.width.bottom = 1`; MAIN starts at row 3 — symmetric treatment at the footer boundary).
- **Guard:** never lower `FRAME_GAP` (`src/ui/frame.odin:68` "DO NOT LOWER") — no `(gap, between)` pair fixes it; the fix must not route through GAP.
- **Assertion (D-N):** assert rendered rule rows + positions, re-derive `st.rules` / `st.borders`; `rh_rule_count` (`tests/it/resize_harness.odin:350-358`) is mechanism-independent → follow it.

### Change 7 — footer: key and description get different colours

- **Requirement:** `keys_line` output must be painted two-tone: description muted (`pal.desc_fg`), key brighter (`pal.key_fg`) — AD-1 §2.
- **Design (E.2 Option A — chosen):** spans are the source of truth; `keys_line` is derived from the span list. Add a span-producing function returning `[?]Key_Span{text, is_key}` (or equivalent), and derive the flat string from it so string-level assertions keep their shape.

### Change 8 — AD-1 footer pattern `Description: key` joined by ` | `

- **Requirement:** unit format `"<Description>: <key>"`; units joined by `" | "`.
- **Units rewrite (`src/ui/keyhints.odin`):** e.g. `Key_Hint{"enter", "new local session"}` → unit `"New local session: enter"`; `Key_Hint{"r", "new remote"}` → `"New remote: r"`; `Key_Hint{"s", "named remote"}` → `"New named remote: s"` (AD-2); `Key_Hint{"a", "attach"}` → `"Attach: a"`.
- **Retention:** unit-atomic (already safe per AD-3); atom = `"{}: {}"`; backward fill from exit unchanged; `…` cut marker with new separator arithmetic.

### Change 9 — AD-2 "New named remote"

- **Requirement:** shortcut description text changes to "New named remote" (display string), kept separate from `state_label`'s "Name remote session".

---

## 4. Cross-cutting implementation contracts (the "HOW" that spans changes)

### 4.1 Caret / blink (D-G, D-K, scout §A)
- Shape + pair colour = Clay (fat block, `caret_bg`/`caret_fg`). Blink = terminal cursor via DECSCUSR through `tb_send`; one-shot at paint time; **no app timer** (forbidden — breaks frozen idle floor). Blink not assertable → not a floor component. Test the testable half; record blink as a named limitation.

### 4.2 Overlay blending is a no-op since Phase 2 (D-Q)
- Any blend/tint paints nothing. Per-cell fg is the only working model. Do not attempt blending for the caret highlight or the state-on-accent.

### 4.3 Palette (D-H, D-M) — must land with the footer/caret tasks
- Add to `ui.Palette` (`src/ui/frame.odin:122-140`), `app.Palette` (`src/app/theme.odin:86-100`), `PALETTE_SLOTS 13 → 18` (`src/app/theme.odin:105`), fill all **ten** themes, add fallbacks so an incomplete theme cannot paint undefined colour, no RGB literals in `src/ui/*`.
- New slots: `key_fg`, `desc_fg`, `caret_bg`, `caret_fg`, `state_hl`.

### 4.4 Geometry (D-L) — changes 1/2/6
- Symmetric spine fix; dedicated 1-row rule elements; never lower `FRAME_GAP`; re-derive by position; `rh_rule_count` stays the mechanism-independent proof.

### 4.5 Footer (E.2 Option A, AD-1/AD-3/AD-4) — changes 7/8
- Spans source of truth; `keys_line` derived; per-span colour; unit-atomic truncation; separator ` | `; unit width grows by the colon; re-measure the 8-width sweep.

---

## 5. Task decomposition — todos tagged `ui-paint`

Full bodies: `.pi/plans/2026-10-23-ui-paint-caret-highlights/todos.md` (this directory). Task bodies here are the executor-facing summary; the todos file carries the full per-task bodies with code sketches, anti-patterns and acceptance ISCs.

| Task | Changes | Files touched (product) | Tests touched | Risk | Depends on | Parallelism |
|---|---|---|---|---|---|---|
| `ui-paint-1` | **5** (selection keeps state colour) | `src/ui/sessions.odin`, `src/ui_cases.odin` | `src/ui_cases.odin` (ui-sessions) | **LOW + isolated** (one-condition edit) | — | **solo, first** |
| `ui-paint-2` | **7, 8, AD-1, AD-2, palette (key_fg/desc_fg/caret_bg/caret_fg/state_hl)** | `src/ui/frame.odin`, `src/ui/keyhints.odin`, `src/app/theme.odin`, `src/theme_cases.odin`(smoke) | `tests/unit/keyhints_test.odin`, `tests/unit/theme_set_test.odin`, `tests/unit/theme_colour_wire_test.odin`, `src/ui_cases.odin` (frame/footer) | **MED–HIGH** (palette breadth: 10 themes × new slots; floor-54 re-measure) | `ui-paint-1` | solo (frame.odin is also needed by `ui-paint-4`) |
| `ui-paint-3` | **3, 4** (caret fat block, arrows, cell-under-caret, DECSCUSR) | `src/ui/edit.odin`, `src/app/state.odin`, `src/main.odin`, `src/input/keymap.odin` | `src/ui_cases.odin` (ui-edit), new/updated edit assertions | **MED** | `ui-paint-2` (caret pair slots) | solo (main.odin is also needed by `ui-paint-4`) |
| `ui-paint-4` | **1, 2, 6** (rules / row arithmetic) | `src/ui/frame.odin`, `src/main.odin`, `src/ui/sessions.odin`, `src/ui/list.odin`?, `src/ui_cases.odin`, `tests/it/resize_harness.odin` | `src/ui_cases.odin` (ui-frame/ui-sessions/ui-shrink), `tests/it/resize_*` | **HIGH** (row arithmetic, phantom-row hazard, spine mechanism) | `ui-paint-1`, `ui-paint-2`, `ui-paint-3` | solo (frame.odin + sessions.odin) |

### Ordering (respecting disjoint-files / max-3 / sequential-on-shared

- The product-change tasks are **serial in practice** because of the shared surfaces: `src/ui_cases.odin` (the smoke-cases file every task asserts in) and `src/ui/frame.odin` + `src/main.odin` (geometry/footer/edit-body). The plan therefore prescribes:
  - **Wave 1:** `ui-paint-1` alone (cheap, isolated, green-first confidence anchor).
  - **Wave 2:** `ui-paint-2` alone (after `ui-paint-1`; owns `frame.odin`'s footer surface).
  - **Wave 3:** `ui-paint-3` alone (after `ui-paint-2` — it consumes the new caret-pair palette).
  - **Wave 4:** `ui-paint-4` alone (after `ui-paint-1`/`ui-paint-2`; owns the frame-geometry + sessions-filter surface).
- Max 3 concurrent agents still binds (D-I); at most one product-change worker runs at a time in this lane. The **test-migration tasks** (post-RCH-10) then run later, one lane at a time (D-A).
- A worker never edits `tests/parity.tsv` to make green; it **reports** measured numbers and the **orchestrator** applies parity edits (see §6).

---

## 6. Floor re-derivation & parity policy (D-D, AD-3, D-A)

- **Landed floors touching RCH-10:** `keyhints` **54** (`tests/parity.tsv` keyhints row, task T2, `tests/unit/keyhints_test.odin`); `ui` **168** (`tests/parity.tsv` ui row, task T8, per-case frame 92 / sessions 16 / shrink 12 / edit 20 / list 17 / float 11).
- **Expected deltas (report, then the orchestrator records):**
  - `keyhints`: unit-width + separator-cost change moves the 8-width sweep thresholds → **re-measure**, expect floor change (probably up or down by a few cells' worth of surviving hints); record delta explicitly as a consequence of AD-1/RCH-10.
  - `ui`: footer-hint sweep (~78 assertions) re-derived against new `keys_line`; edit/caret (~20) + list (~17) + sessions (~16) + shrink (~12) + frame rules re-derived; **expect a net movement** in the `ui` floor; the `float` (11) untouched.
- **Policy:** workers only **report** measured numbers; the **orchestrator** applies the `tests/parity.tsv` edits (lanes normally don't touch it). Deltas must be stated as consequences of RCH-10, never silently applied.
- **NOT in scope here:** T8 port, T12 port, T14 fixture lanes (D-A/D-P) — scheduled after RCH-10 merges.

---

## 7. Verification plan (real binary under a pty)

### Build
```sh
# in /tmp/wt-ui-paint (odin dev-2026-10 on PATH via the dev-2026-09 store path)
odin build src -out:/tmp/hs-local -o:speed -vet -extra-linker-flags=-Wl,--library-path,/
./dev/local-build.sh
CASES="ui-frame ui-sessions ui-shrink ui-edit ui-list ui-float" ./dev/ui-smoke.sh
```

### pty-testable half (assert in `src/ui_cases.odin` / `tests/it`)
- Caret: glyph == fat block at the **derived** column; `edit_caret_col` equality; cells consumed == caret column; left-of-caret is last rune.
- Colours via `tb_get_cell` / `render.attr_painted` / palette slots: footer per-span colour; state-on-accent colour; caret pair.
- Geometry: rule rows + positions (D-N), `rh_rule_count`, no content on rule rows, header/footer rows, phantom-row guard (body arithmetic).
- Keys: arrow-left/right move caret (pty-fed keys); footer content per new pattern.

### Eyeball-only half (honest, NOT pty-assertable)
- Actual visual weight of the fat block (glyph-level vs perceived size); blink behaviour (terminal-owned); real terminal colour perception; DECSCUSR acceptance. **List separately in the todos' verification section; do not attempt pty assertions on these.**

### Falsifiability (D-E) — per new assertion
- Caret glyph: fail if `CARET_TEXT` reverts to `"▏"`. Negative control: temporarily revert → suite goes red.
- Caret column: fail if `edit_caret_col` drifts; negative control: byte-offset caret.
- Footer two-tone: fail if both spans paint `pal.dim`; negative control: re-introduce uniform paint.
- State-on-accent: fail if state cell reads `sel_fg` under selection; negative control: re-add `if !is_sel`.
- Rule position: fail if row `rule_top - 1` is blank/content; negative control: restore old betweenChildren geometry.
- **SIGSTOP-style negative control** (as `tests/it/resize_eintr_test.odin:61-69,251`): freeze the app (SIGSTOP), drive the same key, prove the behaviour does not happen when the app cannot run; SIGCONT → prove it does. Use for the arrow-caret and footer/idle behaviours where a timer could fake liveness.

---

## 8. Risk register — cheap vs structurally risky

- **Cheap + isolated:** change 5 (`ui-paint-1`) — one-condition edit; do first as confidence anchor.
- **Structurally risky (row arithmetic / phantom row):** changes 1, 2, 6 (`ui-paint-4`) — touch `chrome`/`visible`, the spine mechanism, `frame_layout`; a missed row count = phantom row.
- **Med:** changes 3/4 (caret + arrows + DECSCUSR) and 7/8 (footer + palette) (`ui-paint-2`, `ui-paint-3`).

**Order workers by risk:** `ui-paint-1` → `ui-paint-2` → `ui-paint-3` → `ui-paint-4`.

---

## 9. NOT in scope (for RCH-10)

- T8 port (ui floor 168) — after RCH-10 merges (D-A/D-P).
- T12 port (tui floor 145, `RE-DERIVE BEFORE PORTING (RCH-10)`) — after RCH-10; source (`dev/tui_drive.py`) stale vs RCH-9, re-derive, don't transcribe.
- T14 fixture lanes — after RCH-10.
- RCH-11 (destroy-session-on-exit) — discovered mid-scout (`scout-rch11-lifecycle.md`); separate work, not part of RCH-10.
- Any deletion under `dev/` (D-J).

---

## 10. Completion criteria for RCH-10

- All nine changes implemented in `/tmp/wt-ui-paint` on `feat/ui-paint-highlights` (rebased on current `main`).
- Branch green incl. its own test adaptation; `main` never red between merge and repair (D-C).
- Floors re-derived per D-D; deltas recorded in `tests/parity.tsv` by the orchestrator.
- Verification: real binary under pty via `./dev/ui-smoke.sh`; pty-testable half asserted; eyeball-only half honestly listed; falsifiability demonstrated.
- Final message to user: what was accomplished.

---

## 11. Final assistant summary (to be emitted when the task completes)

Summarise: nine changes implemented, tasks created tagged `ui-paint`, floors re-derived, verification run, etc.

---

Now let me write the todos file, then the final response.

Actually — one important consideration: the user asked *me* to write plan.md and create todos, then finish with a summary and call subagent_done. The todos should be in the plan dir. Let me write todos.md in the house style.

Let me write it.</think>Now let me create the todos file:<tool_call>write<arg_key>content</arg_key><arg_value># TODOS — `herdr-session`

**Plan artifact:** [`plan.md`](./plan.md) ← **read this first, always**
**Tag:** `ui-paint`
**Repo:** `/home/alexfneves/gits/herdr_session`
**Worktree:** `/tmp/wt-ui-paint` (branch `feat/ui-paint-highlights`, base = current `main` — rebase before working)

> Todos for **RCH-10** (nine UI paint changes) + the sequencing for the remaining test migration.
> Binding decisions: `../2026-10-23-ui-paint-caret-highlights/ORCH-DECISIONS.md` (D-A…D-Q) ·
> `../2026-10-23-ui-paint-caret-highlights/REQUIREMENTS-addendum.md` (AD-1…AD-4) · scout §A–J of
> `../2026-10-23-ui-paint-caret-highlights/scout-context.md` · RCH-9: `../2026-10-18-herdr-session-tui/`.

> **Ground rules for every task in this tag**
> - Odin is `pkgs.odin` (`dev-2026-09`); output flag is `-out:`; `proc "c"` has no Odin context.
> - Renderer decision is B2: `clay.odin` for layout + own Clay→cell renderer on termbox2.
> - Clay `Text` cannot blink (`EndLayout(0)`, no colour-transition); blink = DECSCUSR via `tb_send`. No app timer (breaks frozen idle floor).
> - Overlay blending is a no-op since Phase 2 → per-cell fg is the only working model.
> - Floors re-derived, never silently lowered; deltas recorded in `tests/parity.tsv` as consequences of RCH-10 (orchestrator applies; workers report).
> - Anti-vacuity mandatory on new assertions (D-E); structural assertions preferred (D-F); no literals in `src/ui/*` for new palette roles (D-H).
> - Max 3 concurrent agents (D-I); sequential on shared files; disjoint files per worker where parallel.

---

## Sequencing summary

```
ui-paint-1 (Change 5 — cheap, solo, FIRST)          → green confidence anchor
        │
ui-paint-2 (Changes 7/8/AD-1/AD-2 + palette)      → solo (frame.odin footer surface)
        │
ui-paint-3 (Changes 3/4 — caret + arrows + DECSCUSR) → solo (needs caret-pair palette from ui-paint-2)
        │
ui-paint-4 (Changes 1/2/6 — rules / row arithmetic) → solo (frame.odin + sessions.odin)
        │
        ▼
[ RCH-10 MERGES → orchestrator applies parity.tsv deltas ]
        │
        ▼
test-migration lane (post-RCH-10): T8 (ui) → T12 (tui) → T14 (fixture)   [NOT part of this tag's workers]
```

---

### ui-paint-1 — Change 5: selection must not flatten the session-state colour

- **STATUS:** ⬜ not started (first task — lowest risk, isolated).
- **Changes:** 5.
- **Files:** `src/ui/sessions.odin` (`sess_paint_row`), `src/ui_cases.odin` (ui-sessions list assertions).
- **Edit (minimal, D-Q):** remove the `if !is_sel` flattening so the state cell keeps its themed colour under the selection, painting per-cell fg on the row's `pal.accent` bg.
- **Acceptance:** selected row bg == accent; device/ts/name cells fg == sel_fg; **state cell fg == running/stopped** (via new `pal.state_hl` under selection, D-M). Stronger than the old whole-row-sel_fg assertion.
- **ISC:** ISC-A-1, ISC-A-2, ISC-A-3.

---

### ui-paint-2 — Changes 7, 8, AD-1, AD-2 + palette (`key_fg`, `desc_fg`, `caret_bg`, `caret_fg`, `state_hl`)

- **STATUS:** ⬜ not started.
- **Changes:** 7, 8, AD-1, AD-2, palette.
- **Files:** `src/ui/frame.odin` (Palette + `palette_of` + `DEFAULT_PALETTE` + `keys_line` + `frame_footer`), `src/ui/keyhints.odin` (unit/action strings), `src/app/theme.odin` (app `Palette`, `PALETTE_SLOTS 13→18`, ten themes), `src/theme_cases.odin`, `tests/unit/keyhints_test.odin`, `tests/unit/theme_set_test.odin`, `tests/unit/theme_colour_wire_test.odin`, `src/ui_cases.odin` (frame/footer).
- **Design:** E.2 **Option A** — spans source of truth, `keys_line` derived; per-span colour (`key_fg` bright / `desc_fg` muted); unit format `"<Description>: <key>"`; units joined by `" | "`; unit-atomic truncation; `…` marker arithmetic updated.
- **Acceptance:** green build; `keyhints` floor re-measured (AD-3) and reported; `ui` footer assertions re-derived.

---

### ui-paint-3 — Changes 3, 4 (caret fat block, arrows, cell-under-caret, DECSCUSR)

- **STATUS:** ⬜ not started.
- **Changes:** 3, 4.
- **Files:** `src/ui/edit.odin`, `src/app/state.odin`, `src/main.odin`, `src/input/keymap.odin`.
- **Design:** `CARET_TEXT :: "█"` + element `backgroundColor = pal.caret_bg`, `textColor = pal.caret_fg`; arrows via new whole-rune move helpers in `consume_edit_key` / `filter_navigate`; cell-under-caret painted `fg = pal.caret_fg` over block bg; blink = DECSCUSR via `tb_send`, no app timer, not a floor component.
- **Acceptance:** ui-edit case green against new caret; arrow keys move caret (pty-fed); blink recorded as named limitation.

---

### ui-paint-4 — Changes 1, 2, 6 (separation lines / row arithmetic / empty row)

- **STATUS:** ⬜ not started.
- **Changes:** 1, 2, 6.
- **Files:** `src/ui/frame.odin`, `src/main.odin`, `src/ui/sessions.odin`, `src/ui/list.odin`?, `src/ui_cases.odin`, `tests/it/resize_harness.odin`.
- **Design:** dedicated 1-row rule elements (C.2 route 1); `chrome`/`visible` row arithmetic updated (phantom-row hazard); spine fixed symmetrically via explicit 1-row rule elements / border sides (D-L); never lower `FRAME_GAP`; re-derive assertions by position (D-N).

---

## Verification per task (template)

1. `odin build src -out:/tmp/hs-local -o:speed -vet -extra-linker-flags=-Wl,--library-path,/`
2. `CASES="ui-frame ui-sessions ui-shrink ui-edit ui-list ui-float" ./dev/ui-smoke.sh`
3. Negative controls (D-E) incl. SIGSTOP/SIGCONT where applicable.
4. Report measured floor deltas (do NOT edit `tests/parity.tsv`).

## NOT in scope (this tag)

- T8 / T12 / T14 ports (post-RCH-10 per D-A/D-P).
- RCH-11 (`destroy-session-on-exit`) — separate.
- Any `dev/` deletion (D-J).

---

## Final state after RCH-10

- Nine changes landed on `/tmp/wt-ui-paint` (`feat/ui-paint-highlights`, rebased on current `main`).
- `tests/parity.tsv` deltas applied by the **orchestrator** as consequences of RCH-10.
- Next lane: test migration — T8 (ui) first, then T12 (tui, `RE-DERIVE BEFORE PORTING`), then T14 (fixture).
