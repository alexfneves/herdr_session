# DISPATCH — UIP-4: fat block caret, arrow-key caret, real terminal cursor (WRITE-FIRST)

**Workspace:** `/tmp/wt-ui-paint` (opened herdr worktree) on `feat/ui-paint-highlights`, HEAD `330d4f2`
(just rebased onto `main` = `47b83e4`; `./dev/local-build.sh` verified clean in 7.3 s, deps staged).
**Task:** UIP-4 = RCH-10 changes 3 + 4. **Budget:** 1 of 3 concurrent agents.

## Read this before you read any code

A previous agent was dispatched for this exact task, spent **~1.8 h reading and wrote nothing** —
it was killed seconds before starting its edits. **Its map is below. Start from it instead of
re-deriving it.** The rule for this dispatch: **produce your first commit inside ~15 minutes.**
Step 0 below is a two-character change that is already a real product improvement. Make it, build
it, commit it, then go back for the rest.

**Commit-first discipline is the whole reason this dispatch exists.** Four of six agents in this
migration died with hours of unwritten work sitting only in their context window.

## Step 0 — commit the glyph change first (do this now)

`src/ui/edit.odin:52-56` — `CARET_GLYPH :: '▏'` → `'█'` and `CARET_TEXT` to match.

```sh
cd /tmp/wt-ui-paint
git status --porcelain -uall          # must be clean; if not, STOP and report
# edit the glyph
export PATH=/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/bin:$PATH
./dev/local-build.sh                 # ~7.3 s, must be clean
git add src/ui/edit.odin && git commit -m "feat(ui): fat block caret glyph (RCH-10 change 3, part 1)"
```

Then continue. Each numbered step below ends in **its own commit**.

## Verified map (from the killed agent's session — trust these, they were read this session)

**Caret painting** — `src/ui/edit.odin`
- `CARET_GLYPH` / `CARET_TEXT` at `:52-56`; `edit_paint` at `:371-391`.
- The caret is a real Clay `Text` **on purpose** — that is what keeps it clipped by the enclosing
  scissor (`src/ui/edit.odin:33-37`). Do not replace it with `tb_set_cell`; that smears the
  Clay→render.paint frame rule.
- Give the caret **its own Clay ID** (e.g. `hs.edit.<field>.caret`) so the caller can read its
  absolute box back after layout with `clay.GetElementData(clay.ID(...))` (`clay-odin/clay.odin:493`).
- Caret column rule already exists at `edit.odin:300` — the caret column == display width of the
  prefix. Reuse it; do not recompute.
- `edit_left` (`:266`) and `edit_right` (`:281`) **already exist**, move one whole rune, and are
  **currently called by nothing**. Wiring them is the feature.

**Key routing** — `src/app/state.odin`
- `consume_edit_key` around `:742`; the name-field write shape to copy is `:746-751`
  (`text_backspace(&a.field)` / `if a.field.len >= NAME_PREFIX_MAX { return }` / `text_append(&a.field, k.r)`).
- `filter_navigate` around `:873`; the filter write shape is `:883-886`
  (`if text_backspace(&a.filter) { rebuild_shown(a) }` / `if a.filter.len >= FILTER_MAX { return }`).
- Add `case .left:` / `case .right:` to **both** procs, following the existing `case .backspace:` in each.
- Key kinds already arrive decoded: `KEY_ARROW_LEFT → .left`, `KEY_ARROW_RIGHT → .right`
  (`src/input/keymap.odin:100-101`). No new input plumbing is needed.
- Text helpers (`state.odin`): `text_clear :296`, `text_append :300` (**one whole rune**),
  `text_backspace :312` (removes the whole rune — never a byte).

**Terminal cursor** — `src/main.odin` paint tail `ui.frame_close` → `tb_present` at `:1070-1074`.
```odin
tb.tb_set_cursor(caret_cx, caret_cy)              // emits ESC[<cy+1>;<cx+1>H
buf := []u8{0x1b, '[', '3', ' ', 'q'}            // DECSCUSR = blinking block
tb.tb_send(raw_data(buf), c.size_t(len(buf)))
```
Any state with **no** visible caret: `tb.tb_hide_cursor()` (`termbox.odin:282`).

**Measured FFI gotcha:** `tb.tb_send` will **not** accept a string literal —
`Error: Cannot convert '"\x1b[3 q"' to 'rawptr'`. Use the explicit `[]u8` + `raw_data()` form above.

**Emission order:** emit **after** `tb_present()`. If measurement shows termbox's own sequence
overrides it, move it before — and **record which order you landed on and why you measured it that way.**

**ONE-SHOT AT PAINT TIME. NO APP TIMER.** A blink timer breaks the frozen
`idle ≤ 2 ticks / 5 s` floor (D-K). Emit once per frame, driven by paint, not by a clock.

## Test harness you must use (already read — go straight to these)

`tests/unit/render_harness.odin`:
`wire_lock :244` · `wire_open :298` · `wire_capture :371` · `wire_bytes :419` ·
`render_escape :424` · `render_clay_start :453` · `render_session :503` · `render_cols :509` ·
**`render_cell_at :540`** (returns the exact `{ch, fg, bg}` from termbox's **back buffer**) ·
`render_glyph_at :551` · `render_dump_rows :566` · `render_and_present :611`.

**Copy the shape of `tests/unit/sessions_sel_state_test.odin`** (UIP-3, landed in this branch).
It is the closest existing pattern: a two-row fixture (`alpha-…` running / `beta-…` stopped), a
frame struct holding the painted command stream plus the per-cell back-buffer reads, and a header
comment documenting *how the test was falsified four ways*. Match that standard.

**Wire locking is mandatory and load-bearing:** `wire_lock` is registered first so cleanups run
last; a cleanup that promises an unlock must actually unlock (measured failure: the next test blocked
forever inside `wire_lock` → 5-minute hang with no failure line).

## Assertions required (machine-testable half — write ALL of them)

1. Caret cell glyph is the block `█`, not `▏`, at the **derived** column, via `render_cell_at`.
2. Caret cell `fg == caret_fg` **AND** `bg == caret_bg` — the requirement is both, not either.
3. Derived caret column == display width of the text prefix (`edit.odin:300` rule).
4. Right then Left returns the caret to the same derived column — whole-rune stepping, tested with
   ASCII, a CJK rune, and an astral rune (`a世b😀c` is the existing `ui-edit` input; reuse it).
5. The wire contains `ESC[<cy+1>;<cx+1>H` **for the caret cell specifically**.
6. The wire contains `ESC[3 q`.

**Anti-vacuity (do not skip):** asserting "some CUP appeared on the wire" is worthless — termbox
emits CUP for every painted cell. **Pin the caret's coordinates.** Same discipline as check 5.

**Eyeball-only — record as named limitations, do NOT encode as assertions:** that it actually
blinks, that the block reads as "fat" to a human, perceived contrast. Do **not** try to assert
blink through the pty emulator — measured: after a full stream the emulator's `cx/cy` reads `0,0`
because termbox's shutdown escapes move it, and it parses-and-ignores DECSCUSR (`dropped=0`).

## Hard constraints

- **Files owned:** `src/ui/edit.odin`, `src/app/state.odin`, `src/main.odin` (paint tail only),
  `src/ui_cases.odin` (`ui-edit` cases), new `tests/unit/*caret*.odin`. Nothing else.
- **Do NOT touch `tests/parity.tsv`** — report numbers, the orchestrator folds them (D-D).
- **No hex colour literals anywhere in `src/ui/*`** (D-H). Colours come from `caret_fg` / `caret_bg`,
  which already exist (UIP-2 landed the 19-role palette in this branch).
- **Odin only. No Python / awk / sed / jq, including scratch analysis scripts** (project requirement,
  `docs/requirements.md` / commit `0964357`). Escalate instead of writing one.
- **Never `git add -A`** — stage only your own paths.
- Live herdr sessions `2026-10-20-19-16-08-614` / `2026-10-20-21-07-27-640` are off-limits;
  scratch `hs-t-*` only. Report `md5sum ~/.config/herdr_session.json` before/after —
  must stay `0cce060b885d2796d87ef1f4fd8d98b5`.
- **Odin gotcha:** `for a, b in slice` yields **(value, index)**.

## Verify after EVERY step (all four, every time)

```sh
export PATH=/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/bin:$PATH
cd /tmp/wt-ui-paint
./dev/local-build.sh
BIN=/tmp/hs-local CASES="ui-frame" ./dev/ui-smoke.sh     # RCH-1 proof set
BIN=/tmp/hs-local ./dev/ui-smoke.sh                      # all 6: expect 94/16/12/20/17/11
odin build ./tests/unit -build-mode:test -define:ODIN_TEST_THREADS=1 \
     -define:ODIN_TEST_JSON_REPORT=/tmp/unit.json -out:/tmp/bin_unit && /tmp/bin_unit
```
Hermetic rows that must never drop below their landed value: `theme 157 · keyhints 54 · render 70 ·
app 446 · state 270 · diag 10 · selstate 16`. Report **every delta**, with the reason.

## Acceptance

`ui-edit` ≥ 20 **with the new caret assertions on top**; wire-level CUP + DECSCUSR pinned to the
caret; arrow keys move the caret in **both** the name field and the filter; no app timer; no hex
literals; eyeball-only items recorded as limitations. *ISC-4, ISC-5, ISC-6.*

## Report

Per-step commit hashes · the four verify-block numbers at each step · the wire evidence for checks 5
and 6 (escape-escaped, with coordinates) · which emission order you landed on and why · every
delta to the landed hermetic rows · the named non-testable limitations · config md5 before/after.
