# Scout context — RCH-10 (seven paint changes)

Scout pass over `herdr-session` for the seven UI changes. Read-only. Citations are
`file:line`. Companion files in this directory: `ORCH-DECISIONS.md` (D-A…D-J) and
`REQUIREMENTS-addendum.md` (AD-1…AD-4). Every finding below is marked
**[BLOCKED]**, **[COST]** or **[FREE]** relative to what the current architecture
can express without a new mechanism.

---

## A. The caret today — and whether it can blink

### A.1 What exists

`src/ui/edit.odin` is the only caret implementation.

- `CARET_GLYPH :: '▏'` — `src/ui/edit.odin:54`; `CARET_TEXT :: "▏"` — `:57`.
  A **one-cell thin bar drawn as ordinary Clay text**, coloured `pal.caret`
  (`src/ui/edit.odin:385`). It is not the terminal cursor. The app *hides* the
  real cursor at boot: `termbox2.tb_hide_cursor()` — `src/main.odin:133`, and
  again after every handoff reacquire `src/main.odin:1335`,
  `src/terminal/handoff.odin:181`.
- The caret is **never a byte offset**. `edit_caret_col()` returns the *display
  column* = `text_cols(buf[0:caret])` — `src/ui/edit.odin:298-303`. Whole
  invariant of the file (`:13`): "the caret's SCREEN position is always DERIVED".
- `edit_view(e, width)` — `src/ui/edit.odin:319-364` — computes
  `{prefix, suffix, caret_x, scroll}`:
  - `caret_x` = caret column **within the scrolled window**, `:358`.
  - scrolling guarantees `caret_x ∈ [0, width-1]` (`:329-346`) — the caret is
    **always inside its own window** by construction. This matters for A.3.
  - `prefix`/`suffix` are cut with `window_cols(...)` to display columns
    (`:359-363`), so the caret is at a known cell inside the row even when the
    text is clipped.
- `edit_paint(e, id, width, pal)` — `src/ui/edit.odin:366-390` — one Clay row
  (height 1, LeftToRight, `SizingGrow` width) containing
  `[prefix text][CARET_TEXT][suffix text]`. Comment at `:366-368`: *"All three
  are ordinary Clay text elements, so the caret obeys whatever scissor the
  enclosing section is under."* That scissor-obedience is the property the
  blinking change threatens.

Callers of `edit_paint` / `edit_caret_col`:

| site | what it paints |
|---|---|
| `src/ui/sessions.odin:212` | the filter line inside the sessions table |
| `src/main.odin` `edit_body()` | the name-entry field (`name_local` / `name_remote_named`) |
| `src/main.odin` `picker_body()` | the picker's filter field |
| `src/ui_cases.odin` (many) | static UI smoke asserts on `edit_caret_col` + `CARET_GLYPH` |

### A.2 Can a Clay `Text` element blink? **No.** [BLOCKED]

Three independent reasons, all verified:

1. **Clay has no clock.** Animation in Clay is `TransitionElementConfig`
   (`clay-odin/clay.odin:208`, attached at `:445`) and is advanced *only* by
   the `deltaTime` argument of `EndLayout`. This app calls `clay.EndLayout(0)` —
   `src/ui/frame.odin:543`. Delta time is a literal zero, so transitions never
   advance. There is no timer anywhere in the paint path.
2. **Clay transitions cannot animate text colour anyway.** The transition
   property set is backgroundColor / overlay / border colour+width / x / y /
   width / height. There is no text-colour transition property. The caret is a
   *text* glyph.
3. **The renderer ignores transitions.** `src/render/renderer.odin` consumes
   the final render-command colours; it has no notion of an in-flight
   transition.

So "blinking" has exactly two possible sources: the **real terminal cursor**, or
an **app-driven repaint timer**.

### A.3 Terminal-cursor blink — available, and the only free one

- FFI is present and complete: `tb_set_cursor :: proc(cx, cy: i32) -> i32` and
  `tb_hide_cursor :: proc() -> i32` — `vendor/termbox2-odin/termbox.odin:281-282`.
  Raw escape injection also exists: `tb_send :: proc(buf: rawptr, nbuf: c.size_t)` —
  `:308`.
- termbox2 has **no cursor-style cap**. There is no DECSCUSR (`ESC[<n> q`)
  support anywhere in termbox2 — the caps table knows `cnorm`/`civis` and the
  SGR `blink=\E[5m` attribute, nothing for block/bar/underline *style*.
- **Gotcha, verified against this machine's terminfo** (`infocmp xterm-256color`):
  `cnorm=\E[?12l\E[?25h`. The `\E[?12l` explicitly **disables** cursor blink
  on the xterm family. So a plain `tb_set_cursor()` gives a **steady** block on
  xterm/VTE, not a blinking one. To get a blinking *block* the app must send
  DECSCUSR itself (`\E[1 q`) through `tb_send`, which is outside termbox's
  terminfo gating: honoured by xterm/VTE/kitty, silently ignored elsewhere.
  Blink therefore becomes **terminal-owned and unguaranteed** — the user's
  terminal can be configured "blink never" and the app cannot know.
- **Testability, and this is decisive for D-E/D-F:** the pty harness's screen
  emulator *ignores* DECSET/private-mode sequences and all colour/SGR —
  `tests/pty/screen.odin` header, "WHAT IS NOT IMPLEMENTED, ON PURPOSE:
  Colours, attributes, wrap-around, scrolling, alternate screen" (`:33-38`),
  and the parser drops private CSI (`if private || final == 'm'`). A real
  terminal cursor therefore paints **no cell** and is **invisible to every
  screen-scraping assertion**. The emulator does track `s.cx/s.cy`
  (`tests/pty/screen.odin:63-64`) from CUP sequences, so the cursor's
  *position* is assertible in-process; its *appearance*, *size* and *blink*
  are not assertible at any tier.

### A.4 The decomposition that resolves D-G

D-G says: if terminal-driven blink cannot coexist with Clay-clipped painting,
deliver the fat block and record blink as a named limitation. The scout finds
they **can** coexist, because the two halves of "fat blinking caret" are
different mechanisms and only one of them needs the terminal:

- **The fat block + its colours = Clay.** Changes 3's *shape* and change 4's
  *"the cell under the caret gets highlighted, background AND character colour,
  like the row-selection highlight"* are **impossible** with a real terminal
  cursor: the terminal draws the cursor in reverse video of whatever is under
  it; you cannot choose the pair. They must be app-painted — a 1-cell highlighted
  box (bg + fg) at the caret's column. Keep doing it in Clay and it stays
  clipped, stays in the back buffer, and stays **assertible in-process** via
  `tb_get_cell` the way the existing UI smoke suite already reads cells.
- **The blink = the terminal cursor, parked on the same cell.** The app can
  call `tb_set_cursor(abs_x, abs_y)` in the typing states only, and
  `tb_hide_cursor()` on leaving them.
- **Why clipping is not lost:** the caret's cell is guaranteed to be inside its
  own window by `edit_view`'s scroll contract (`src/ui/edit.odin:329-346`),
  and both caret hosts (name field, filter line) are **non-scrolled rows**, so
  the cell the cursor sits on is on-screen whenever the row is. The scissor
  guarantee comes from `edit_view`, not from Clay — which is exactly why the
  real cursor is safe here and would *not* be safe inside the scrolled session
  list.
- **Getting the absolute column.** Today the caret has no Clay id of its own, so
  its absolute position is not queryable. Two routes: (a) wrap the caret in an
  identified element and read `clay.GetElementData(clay.ID("…")).boundingBox`
  after `EndLayout` — the API exists (`clay-odin/clay.odin:485-489`,
  `ElementData{boundingBox, found}`) and is already used for `MAIN` in the
  frame test; note the bbox is **layout-space, not clip-adjusted**, so it does
  *not* tell you whether the cell was clipped away (see the scissor caveat in
  `clay.h:774`, `:2783`). (b) compute `main_x + prefix_cols` from the same
  numbers `edit_view` already returns, which is what the caller already knows
  (label widths etc.).
- **The app-timer alternative is the bad one.** A ~500 ms blink timer would
  break the FROZEN idle assertion in `tests/parity.tsv` (`idle <= 2 clock ticks
  over 5 s`) — ~10 forced repaints per 5 s window, each waking a loop that
  currently sleeps with `timeout = -1` when nothing is in flight
  (`src/main.odin:825`) — and would violate the "nothing repaints without a key"
  property that T12's liveness checks rest on. **[BLOCKED — do not do this.]**

**Net for A:** shape+colour must be Clay-painted (and are testable in-process);
blink can only come from the terminal, is terminfo-blocked by `cnorm` unless
DECSCUSR is hand-sent, is untestable at every tier, and is optional in the sense
that the Clay block remains fully visible without it.

---

## B. Row selection highlight — it flattens state colour *deliberately*

`src/ui/sessions.odin`, `sess_paint_row` (`:259-293`):

```
bg := clay.Color{}      // alpha 0 = paint nothing, frame bg shows through  (:260)
fg := pal.fg                                                (:261)
if is_sel { bg = pal.accent; fg = pal.sel_fg }              (:263-266)
```

and, verbatim at `:282-289`:

```
// The state column is themed, not hardcoded: `running` / `stopped` are
// palette roles (T6.2 "no gaps"). Selected rows keep the selection
// foreground, because a themed green on the accent bar is how the two
// encodings would otherwise collide.
state_fg := fg
if !is_sel {
    if row.running { state_fg = pal.running } else { state_fg = pal.stopped }
}
```

**[THE FLATTENING IS EXPLICIT, NOT AN ACCIDENT.]** `if !is_sel` is the line
that makes a selected row lose its running/stopped colour: on selection every
cell in the row becomes `pal.sel_fg` on `pal.accent`. Change 5 = delete that
`!is_sel` guard so `state_fg` stays `pal.running`/`pal.stopped` under the
accent bar. Everything else in the row can stay as-is. It is a **one-condition
change in one proc.** [FREE as an edit; the cost is elsewhere — see B.2.]

Supporting facts:

- Selection is **identity-based, not index-based**: `is_sel` compares
  `row.device`/`row.name` against `v.sel` (`:254`), and
  `sessions_selected_index` (`:159-171`) resolves the held identity against
  the visible rows (`-1` = nothing selected / not visible). The cancel/delete
  rule "if it is still there, keep it selected" is documented at `:32-37`.
- The header comment `:32-37` is the important architectural statement:
  the highlight is *"an explicit backgroundColor the view chose (pal.accent)
  with its matching foreground (pal.sel_fg). The renderer is NOT asked to
  blend a tint — Phase 2 left **overlay blending as a no-op**, so a highlight
  that relied on it would silently paint nothing."*
  ⇒ **Any plan that tries to get "state colour visible over the highlight" by
  using Clay's `backgroundColor`+overlay/blend trick will paint NOTHING.**
  The only working model is per-cell explicit fg/bg.
- Cell painting is `paint_cell(text, w, fg)` (`:295-…`) — one fixed-width Clay
  box per column, content pre-cut by `ellipsize`, `childGap = SESS_COL_GAP`
  (`:276`). Background lives on the **row** element (`:278`), foreground on
  each **cell**'s `TextElementConfig`. So per-cell fg is already the grain of
  the code; changing the state cell's fg while the row keeps `pal.accent` bg
  needs no new mechanism.
- **Contrast is the design question, not the mechanism.** `pal.running`
  (green) and `pal.stopped` on `pal.accent` (gruvbox: bright yellow accent,
  `sel_fg = dark0_hard`, see `src/app/theme.odin` gruvbox-dark block) is the
  collision the original author explicitly designed around. Per D-H the answer
  must be palette roles, not literals — see G.3 for the role options.

### B.2 What change 5 costs

Landed/unlanded assertions that key off "selected row is uniform `sel_fg`":
`src/ui_cases.odin` sessions checks read cells back from the termbox buffer and
compare against `pal.sel_fg`/`pal.accent`. Any assertion of the form "every
cell of the selected row has fg == sel_fg" goes red by design and must be
re-expressed as "device/ts/name cells == sel_fg AND state cell == running|stopped".
That is *stronger*, which D-E wants.

---

## C. `frame_layout` row arithmetic as it now stands

Constants — `src/ui/frame.odin:65-75`:

```
FRAME_PAD   :: 0   // RCH-1: no outer border, so nothing to keep clear of
FRAME_GAP   :: 2   // childGap. "DO NOT LOWER" (:68)
HEADER_ROWS :: 2   // row 0 title, row 1 state (state moved UP out of footer)
FOOTER_ROWS :: 1
```

`frame_layout` — `:96-110`:

```
l.cols      = cols - 2*FRAME_PAD                             (:98)
l.header_y  = FRAME_PAD                                      (:99)
l.rule_top  = FRAME_PAD + HEADER_ROWS + FRAME_GAP - 1         (:100)
l.main_y    = FRAME_PAD + HEADER_ROWS + FRAME_GAP             (:101)
l.main_rows = rows - (PAD + HEADER + GAP + GAP + FOOTER + PAD) (:102)
l.rule_bot  = main_y + main_rows + FRAME_GAP - 1              (:103)
l.footer_y  = rows - FRAME_PAD - FOOTER_ROWS                  (:104)
l.main_rows clamped at 0                                      (:108-110)
```

Concrete numbers for a 24×80 terminal (PAD=0, HEADER=2, GAP=2, FOOTER=1):

| row | content |
|---|---|
| 0 | header title |
| 1 | header line 2 = the **state phrase** (moved up by RCH-9) |
| **2** | **EMPTY — see D** |
| 3 | `rule_top` — Header\|Main spine |
| 4…20 | MAIN (`main_y=4`, `main_rows=17`) |
| 21 | `rule_bot` — Main\|Footer spine |
| 22 | footer (keys line) |
| 23 | — (`footer_y = rows-1 = 23`; with rows=24 footer is row 23, `rule_bot=22`) |

(24 rows: `main_rows = 24 - (0+2+2+2+1+0) = 17`, `main_y=4` → MAIN spans
4..20; `rule_bot = 4+17+2-1 = 22`; `footer_y = 24-0-1 = 23`.)

### C.1 Rules are Clay geometry, not hand-painted glyphs

- ROOT layout config: `padding = clay.PaddingAll(FRAME_PAD)`,
  `childGap = FRAME_GAP` — `src/ui/frame.odin:481-482`.
- The spine comes from ROOT's `border.width.betweenChildren = 1`. Verified in
  `clay.h`: the between-children rule rectangle is emitted at
  `y = child_top - floor(childGap/2) - floor(betweenChildren/2)`
  (`clay.h:2861`, `:2877`; with gap=2, between=1 ⇒ **exactly one row above
  the following child**). This is the formula the frame comment at `:27`
  paraphrases as the "`childGap` must stay ≥ 2" invariant.
- The renderer turns a thin rectangle in the border colour into ruled glyphs:
  `draw_rule` in `src/render/renderer.odin` picks the horizontal rule glyph
  by border weight (`─` for weight 1) and **preserves the background** so the
  rule reads as a line rather than a stripe. Rule detection is by
  "thin rect whose colour was registered as a rule source" — that registration
  happens **only** for `betweenChildren` borders.
- Consequence worth knowing: `st.rules` counts `draw_rule` calls (the
  betweenChildren path) and `st.borders` counts `render_border` calls. They
  are **different counters for different mechanisms**, and the old UI-frame
  assertions distinguish them ("exactly one border call, registered as the
  divider source (RCH-1)" is a `st.borders` assertion; "the two dividers came
  from Clay's command stream" is a `st.rules` assertion).

### C.2 How a caller adds a horizontal rule below an arbitrary element **[COST: 1 row each]**

There is **no** existing "rule below X" API. Four candidate mechanisms, ranked:

1. **Dedicated 1-row rule element** — an empty Clay element,
   `height = SizingFixed(1)`, with `border = {color: pal.border, width: {bottom: 1}}`.
   `render_border` draws only the bottom side ⇒ a clean `─` row, no corners,
   no vertical strokes. Fully Clay-laid-out, correctly clipped, caller places
   it wherever it wants. **This is the recommended route.** Caveats: it counts
   as a `borders` call, not a `rules` call; it consumes **one row of MAIN's
   budget**, so every caller that computes body height must add 1 per rule
   (`session_body`'s `chrome`, `picker_body`'s `visible`, and the hardcoded
   `l.main_rows - 2` / `first = l.main_y + 2` in `src/ui_cases.odin`).
2. **Parent `betweenChildren` on the containing container** — works, but the
   rule is always positioned relative to the *following* sibling
   (`clay.h:2861`), so it drags the gap with it and cannot hug the element it
   belongs under. With `childGap=1` the rule lands **on** the next child's
   first row (the documented reason GAP is pinned at 2). Not usable for
   "immediately below the filter".
3. **Bottom border on the element itself** — `border.width.bottom = 1` on a
   1-row element paints the rule **over** that element's own text (Clay borders
   are inset into the element's box). Only usable if the element is made
   2 rows with a spare bottom row.
4. **Post-layout hand-painted rule** (app writes cells after `EndLayout`) —
   escapes Clay entirely, breaks the "Clay is the geometry authority" rule the
   frame test enforces, and would have to duplicate clipping. **Avoid.**

---

## D. Exactly which row is the empty line, and what creates it

**Row 2** — the row between the state phrase (row 1, `HEADER_ROWS=2`) and
`rule_top` (row 3). Created by the interaction of two facts:

1. The header is `SizingFixed(HEADER_ROWS)` = 2 rows, and its two text lines
   are adjacent rows (`src/ui/frame.odin:500-510`) — so header content ends
   at row 1.
2. The spine is ROOT's `betweenChildren` rule, which Clay positions at
   `child_top - floor(childGap/2) - floor(betweenChildren/2)` (`clay.h:2861`).
   With `FRAME_GAP=2`, `between=1` that is `main_y - 1 - 0 = 3`, and
   `main_y = 4`. Rows 2 and 3 are the two gap rows; the rule occupies the
   **lower** one, leaving **row 2 blank**.

`frame_layout` states it without comment: `rule_top = PAD + HEADER + GAP - 1 = 3`
(`:100`) while the header's content stops at 1. The README also pins it
("the blank row between the header and the table's top rule").

The same blank exists symmetrically above the footer spine: MAIN ends at row 20,
`rule_bot = 22`, so **row 21** is blank there too. Change 6 as written ("the
empty line between the state text and the separation line below it") names the
top one, but the mechanism is shared — fixing only the top leaves the bottom
looking inconsistent.

### D.1 The gap cannot simply be lowered [BLOCKED via betweenChildren]

| childGap | between | main_y | rule lands on | blank rows |
|---|---|---|---|---|
| 2 | 1 | 4 | 3 | row 2 ← today |
| 1 | 1 | 3 | **3 = MAIN's first row** | none, but the rule paints over content |
| 3 | 1 | 5 | 4 | rows 2,3 — worse |
| 1 | 2 | 3 | 1–2 (2-row rect) | paints over the state row |

Clay centres the rule in the gap with integer halves, so with a 2-row header
there is **no (gap, between) pair** that puts the rule at row 2 and MAIN at
row 3. That is the exact breakage `FRAME_GAP`'s "DO NOT LOWER" comment
(`src/ui/frame.odin:68`) exists to prevent.

### D.2 What *does* work for change 6

Move the top rule out of ROOT's `betweenChildren` and make it belong to the
header:

- **Option 1 (recommended):** ROOT gets `childGap = 1` and
  `betweenChildren = 0` for the top boundary; the header becomes
  `HEADER_ROWS = 3` where row 2 is drawn by the header's own
  `border.width.bottom = 1` — a rule row that is *inside* the header's box,
  so it hugs the state with no blank row, and MAIN starts at row 3.
- **Option 2:** keep ROOT's geometry and insert a dedicated 1-row rule
  element (C.2 route 1) immediately after the header, with the gap collapsed
  to 0 for that boundary.
- Either way: **the same treatment should be applied at the footer boundary**
  (footer gets `border.width.top = 1`, `FOOTER_ROWS` gains the rule row) or
  the two halves of the spine stop matching.
- **Cost, and it is a counting cost not a code cost:** with
  `betweenChildren = 0` the top spine is no longer a `draw_rule` call — it
  becomes a `render_border` call. `st.rules` drops (potentially to 1 or 0)
  and `st.borders` rises (to 2 or 3). The unported frame assertions
  "`st.rules >= 2`" and "`st.borders == 1` (RCH-1: exactly one border call,
  registered as the divider source)" are **both invalidated by the mechanism
  change and both must be re-derived, not deleted**. The LANDED resize tests
  are safe here because `rh_rule_count` counts *rendered rows of `─`* on the
  screen (`tests/it/resize_harness.odin:350-358`), not render commands —
  a border-drawn rule still fills the row with `─` and still counts.

---

## E. Footer: `keys_line`, and the two-tone + inverted-order redesign

### E.1 What the code actually is

Type: `Key_Hint{key, action}` — defined in `src/ui/frame.odin`, consumed by
`src/ui/keyhints.odin`. Tables (`src/ui/keyhints.odin:29-…`):
`KEYS_MODE : [8]`, `KEYS_ATTACH : [5]`, `KEYS_DELETE : [5]`, `KEYS_NAME : [4]`,
`KEYS_PICK : [5]`, `KEYS_THEME : [5]`, each ending with the exit hints
(`t theme`, `esc quit` / `ctrl-c quit`).

Rendering is **two steps that must be understood separately**:

1. **`keys_line(keys, max)` — a pure string function**
   (`src/ui/frame.odin:576-627`). Its contract:
   - Renders `"j move  k quit  enter open"` — key first, space, action, units
     joined by `SEP :: "  "` (`src/ui/frame.odin:629`, **two spaces**).
   - `max <= 0` or no keys ⇒ `""` (`:577-579`).
   - **Exit-hint gate** (`:582-586`): the *last* hint is formatted first; if
     even it doesn't fit, the return value is `ellipsize(last, max)` — the exit
     hint is never dropped, only shortened.
   - **Backward fill from the exit** (`:588-600`): walk `i` from
     `len-2` down, prepending whole hints while
     `used + len(SEP) + cols(hint) + marker <= max`, where
     `marker = cols("…") + len(SEP)` only when `i > 0` — i.e. the `…` is
     reserved *in advance* whenever a cut is still coming.
   - **Never half a hint.** The unit is the atom. Retention rule (P3-12,
     `:560-575`): "keep the hints nearest the exit, drop the ones furthest
     from it", and the cut is marked `…`.
   - Returns **one flat string** today. **This is the coupling that matters:
     there is no colour information in this function's output at all.**
2. **`frame_footer` paints that whole string in ONE colour**
   (`src/ui/frame.odin:570-572`):
   `clay.Text(keys_line(f.keys, room), clay.TextElementConfig{textColor = pal.dim})`.
   The footer row itself (`:551-573`): `SizingFixed(FOOTER_ROWS)`,
   LeftToRight, `childGap = 1`; first child is `f.rest` (the driver's report
   line, `pal.accent`), then `room = inner - rest_w - 1` and the keys line.

### E.2 Design options for the two-tone (change 7 + AD-1)

**[FREE] Option A — keep `keys_line` a string function; make the *spans* a
parallel output.** Add a function that returns the same truncation decisions
but as a list of `{text, role}` (or `{key_part, desc_part, join}`), and paint
each as its own Clay `Text` element with `textColor = pal.key_fg` /
`pal.desc_fg`. `keys_line` can then be **derived** from the span function
(concatenate), so every existing string-level assertion keeps working
unchanged and the colour assertion gets a real per-span target.
Best fit for **D-F** ("assert per-span colour, not that the text contains the
key") and for **D-D** (the landed floor 54 keeps counting the same things).

**[COST — do not choose] Option B — inline colour protocol** (embed SGR-like
markers in the returned string and parse at paint). This breaks the unit
model: `text_cols` would count the markers, `ellipsize` would cut through
them, and the never-half-a-hint contract becomes a parser-correctness proof
instead of a loop invariant. Fails D-F and endangers the landed 54.

**[COST] Option C — one Clay element per hint, colour by element.** Loses the
per-unit key/desc distinction unless each hint becomes a nested pair container.
Half-way between A and B; no advantage over A.

**Recommendation: Option A**, with the span list as the single source of truth
and `keys_line` as its rendering.

### E.3 The truncation/order contract as it actually is (AD-1/AD-3 cross-check)

AD-3's claim — that inverting each unit to `Description: key` does **not**
break unit-atomicity — **holds against the code**: the loop's atom is
`fmt.tprintf("{} {}", …)` (soon `"{}: {}"`) and the fit test operates on the
whole formatted unit (`:599`). Nothing in the retention logic is format-based.
What genuinely moves:

- **Unit widths change.** `New remote: r` = 13 cells vs `r new remote` = 12.
  Every unit grows by ≥1 (the colon), so at fixed `max` the *marginal* hint
  is dropped one cell earlier.
- **Separator cost grows.** `  ` (2 cells) → ` | ` (3 cells): `3*(N-1)`
  extra cells. For `KEYS_MODE`'s 8 hints that is **+7 cells** on top of the
  per-unit colon growth (+8). Roughly **+15 cells of footer budget at the wide
  end** — which is exactly where hints are dropped, so the 8-width sweep in
  `tests/unit/keyhints_test.odin:149-179` must be re-measured, not scaled.
- **The `…` marker arithmetic is unchanged in shape** (`:596-598`) but its
  absolute thresholds move with `SEP`.
- **Never-blank rule and exit survival at 40 cols** must be re-verified
  (AD-3 §3), because `KEYS_MODE`'s exit hint `esc quit` (8) plus
  `t theme` (7) plus ` | ` (3) = 18 cells minimum for two hints.
- **AD-2 terminology**: shortcut description strings are a **separate display
  concern** from RCH-9's `state_label`. Do not derive one from the other;
  `s` must read "New named remote" in the footer while `state_label` for
  `name_remote_named` stays whatever RCH-9 set it to.
- **AD-1 hierarchy**: the key must remain the visually dominant token, i.e.
  `key_fg` brighter than `desc_fg` — the *opposite* of today, where the whole
  line is uniformly `pal.dim` (`src/ui/frame.odin:572`) and only the key's
  leading position gives it prominence. After AD-1 the key moves to the
  *trailing* position of each unit, so colour is the only thing carrying it.

---

## F. Which states show the filter line vs the edit field

Three separate predicates in `src/app/state.odin`, deliberately not merged:

| predicate | line | set | answers |
|---|---|---|---|
| `state_is_filter_view` | `:151-153` | `.remote_server, .attach, .delete_session, .theme` | **is the filter LINE drawn** |
| `state_filter_is_editable` | `:168-171` | the same four states | **does typing go into it** |
| `state_is_edit_view` | `:174-176` | `.name_local, .name_remote_named` | **main content is one editable line** |

Header comments worth reading before touching either (`:140-156`, `:155-167`):
`{Mode selection}` is in **neither** set as of RCH-9 — the landing screen is a
mode menu and a filter above it "invited typing into a state that does not
accept it". The two predicates are documented as answering *different
questions* and "deliberately not merged" — **do not collapse them** even though
their current bodies are identical; the mode-selection comment is why they must
stay separately editable.

`session_body` is the only consumer of the display predicate
(`src/main.odin:1079-1096`):

```
show_filter := app.state_is_filter_view(tui.machine.state)   (:1088)
tui.sess.show_filter = show_filter                          (:1089)
chrome: i32 = 1                     // the column header    (:1090)
if show_filter { chrome += 1 }                              (:1091)
body := l.main_rows - chrome                                (:1092)
if body < 1 { body = 1 }                                    (:1093)
```

**[THE PHANTOM-ROW COUPLING.]** The comment at `:1084-1087` is the change-1
hazard in one sentence: *"a table that assumes a filter line it never painted
loses a row to a phantom."* **Every new separation row added by changes 1/2/6
must be added to `chrome` here**, or the table will be laid out for a body
that has one fewer row than `sessions_paint` is given and the last row will
be clipped or the list will under-fill. Same in:
- `picker_body` — `visible := l.main_rows - 1` (`src/main.odin:1123`) must
  become `- 2` if the picker's filter gets its own rule row.
- `src/ui_cases.odin` hardcodes the same arithmetic as
  `l.main_rows - 2` and `first = l.main_y + 2` in several places.

Name-entry states are **not a separate UI file**. `edit_body`
(`src/main.odin:1098-1103`) paints the name field as one
`ui.edit_paint(&tui.name_ed, "hs.tui.name.edit", w, &tui.pal)` at
`w = l.cols - 2` (floor 8) inside MAIN, dispatched from
`src/main.odin:1058-1066`:

```
1058: session_body(l)        // list states
1060: edit_body(l)           // .name_local / .name_remote_named
1063: picker_body(l, tui.remote_rows[:])
1066: picker_body(l, tui.theme_rows[:])
```

So **change 2 ("rule below the edit field in name-local / name-remote")** has
one place to live: `edit_body`, plus its `chrome` counterpart. Note the
filter field in `picker_body` (`:1112`) is painted by the *same*
`edit_paint`, under a different Clay id — so a rule "below the edit field"
is a pattern applied at two call sites (`hs.tui.name.edit`,
`hs.tui.pick.filter`) plus the sessions-table filter line at
`src/ui/sessions.odin:212` (which is change 1). **Three rule sites total**,
one helper.

---

## G. Palette / theme — adding semantic roles is mechanical but wide

- `Palette :: struct` — `src/app/theme.odin:86-100`, **13 slots**, all `u32`
  0xRRGGBB:
  `bg :87`, `fg :88`, `dim :89`, `border :90`, `header_fg :91`,
  `accent :92`, `sel_fg :93`, `caret :94`, `float_bg :95`, `float_fg :96`,
  `err_fg :97`, `running :98`, `stopped :99`.
- `PALETTE_SLOTS :: 13` — `:105`, with the comment: *"Adding a slot to
  `Palette` without bumping this makes that check fail, which is the point:
  the view layer must never be left without a colour."*
- `THEMES : [10]Theme` — `:169`. Each `Theme{name, aliases, pal}`
  (`:130-134`). Every one of the ten fills all 13 slots; the slot-filling
  test asserts exactly that, so **a new slot unfilled in any theme = red**,
  and `theme` is a LANDED floor (171) — meaning the breakage would be
  against an already-protected number.
- Resolution: `theme_resolve(requested) -> (Theme, Resolve_Kind)` at
  `:475` with kinds `explicit / defaulted / fell_back` (`:139-148`),
  `THEME_DEFAULT_NAME = "gruvbox-dark"` (`:137`). The view layer receives a
  `^Palette` and never names a hex.
- Per **D-H** new roles must be palette entries, not literals. Candidate new
  roles for these seven changes:

| role | needed by | note |
|---|---|---|
| `key_fg` | change 7 / AD-1 §2 | bright, the token the eye lands on |
| `desc_fg` | change 7 / AD-1 §2 | muted; may equal `dim` per theme |
| `caret_bg` + `caret_fg` | change 4 | the block's pair; `caret` alone is a fg for a glyph, not a pair |
| `state_running_hl` / `state_stopped_hl` | change 5 | running/stopped *as readable on the accent bar* |

- **[COST]** Adding slots is a **5-place edit × 10 themes**: `Palette`
  struct, `PALETTE_SLOTS`, each theme literal, the slot-name arrays in
  `tests/unit/theme_set_test.odin`, and any smoke assertion that enumerates
  slots. Adding *two* roles (key_fg + desc_fg) plus a caret pair plus two
  highlight variants is up to **7 new slots = 70 literal values** that must
  each be chosen per theme with contrast reasoning.
- **[OPTION that keeps the floor intact]** For change 5, prefer
  **reusing `running`/`stopped` and choosing an `accent` per theme that keeps
  them legible** over inventing `*_hl` variants — that is a *value* change in
  10 themes, not a *slot* change, and keeps `PALETTE_SLOTS` at 13. Same for
  the caret: `caret_bg` can be `caret` and `caret_fg` can be `bg` in most
  themes. Minimum viable: `key_fg`, `desc_fg`, `caret_bg`, `caret_fg` =
  13 → 17 slots.

---

## H. Test-migration context — what is behind these numbers

From `tests/parity.tsv` + `.pi/plans/2026-10-20-odin-test-migration/baseline-measurement.md`
(corrected measured baseline, total **1544**):

| lane | measured | landed? |
|---|---|---|
| `state` | 259 | landed |
| `app+disc` | 532 | landed |
| `theme` | 171 | landed |
| `resize` | 138 | landed (165 pass_after in the post-RCH-9 re-measure) |
| `handoff` | 35 | landed |
| **`ui` (T8)** | **168** | **UNLANDED** |
| **`tui` (T12)** | **145 floor** | **UNLANDED** |

### H.1 What `ui` 168 consists of (per-case, from the baseline artifact)

| case | count | touched by |
|---|---|---|
| `frame` | **92** | **~78 of them are the 8-width footer-hint sweep** → changes 6, 7, AD-1 directly; plus 6 rule/divider assertions, 2 geometry (predicted==Clay) assertions, 4 header/footer text assertions |
| `edit` | 20 | caret glyph, `edit_caret_col`, `edit_view` scroll → changes 3, 4 directly |
| `list` | 17 | selection fg/bg model → change 5 |
| `sessions` | 16 | selection + state colour + filter row → changes 1, 5 |
| `shrink` | 12 | row geometry → changes 1, 2, 6 |
| `float` | 11 | untouched |

**The single most important number in this file: ~78 of 92 `frame` assertions
(≈46% of the whole `ui` floor) are footer hint-line checks driven by
`keys_line`'s string contract.** Under AD-1 (inverted order, ` | `
separator, "New named remote") every one of those 78 changes its *numbers*
while keeping its *shape*. This is why **E.2 Option A is not a style
preference**: keeping `keys_line(string)` as a derivable surface means those
78 assertions keep their form and only their thresholds are re-derived; Option
B would require rewriting all 78 against a parser.

### H.2 `tui` 145 (T12)

Floor 145 per `tests/parity.tsv`; per-case detail was **not** fully read in
this pass (flag: the planner should read the T12 artifact before setting the
re-derived floor). What is known and relevant:
- The old driver `dev/tui_drive.py` still encodes the requirement behind the
  floor (D-J: do not delete).
- **It is already stale against RCH-9**: e.g. the `refresh-key` scenario's
  footer list-age token was removed from the footer entirely by RCH-9
  (`src/ui/frame.odin:547-550` — "the list-age token is gone from this line
  entirely"), and `NORMAL_UI_MARK :: "filter:"` no longer exists in
  mode-selection. Any T12 assertion keyed on those tokens is dead-on-arrival
  today.
- T12 is where the typing/blink/idle properties live, i.e. it is the lane
  that would notice an app-driven blink timer (see A.4).

### H.3 How many unported assertions touch the seven things

D-A's number is **313** across `ui` (168) + `tui` (145). The scout
corroborates it as the right order of magnitude: `ui` alone has ~78 (footer
sweep) + 20 (edit/caret) + 17 (list selection) + 16 (sessions) + 12
(shrink geometry) + ~6 (frame rules) = **149 of 168** touching at least one
of the seven dimensions. Only `float` (11) is untouched.

---

## I. RCH-9 churn — the failure mode to design against

RCH-9 was a display-only change (state phrase footer→header, filter line
removed from `{Mode selection}`, footer content changed, visible row geometry
changed) that broke **already-landed** floors. The recorded pattern:

1. **Display tokens used as liveness proxies.** `NORMAL_UI_MARK :: "filter:"`
   simply stopped existing in mode-selection; every check keyed on it went red
   for a reason that had nothing to do with what it was testing.
2. **A repaint test saw `bytes = 0`** because the UI no longer repainted on
   the key the test assumed caused a repaint.
3. **A two-binary control proved 12 resize failures were caused by the UI
   change, not flakiness.** (The method worth repeating for RCH-10: run the
   pre-change binary and the post-change binary against the same suite before
   blaming the harness.)

**Lessons that bind these seven changes.** Any check keyed on any of the
following is fragile by construction and must be replaced with a composite
structural marker:

| fragile key | invalidated by |
|---|---|
| "there is a filter line here" | change 1 changes what's *under* it; row index moves |
| "footer contains the state / age token" | already dead since RCH-9; change 7 rewrites the footer line |
| exact blank-row counts | changes 1, 2, 6 move every row below them |
| `caret == '▏'` | change 3 replaces the glyph (or removes it for a real cursor) |
| "selected row's cells are all `sel_fg`" | change 5 by design |
| rule row indices (`rule_top == 3`) | change 6 changes the mechanism and the row |

**Per D-F, each of the seven needs a structural assertion with its negative
half stated** — e.g. for change 6: "the rule occupies row N **and** row N-1
is the state row **and** the row that used to be blank is no longer blank",
asserted against `frame_layout`'s own derived numbers rather than literals.

---

## J. Open questions the planner must settle (scout cannot decide)

1. **Blink**: send DECSCUSR (`\E[1 q`) via `tb_send` and accept
   "blink is the terminal's, may be configured off, invisible to all tests",
   or ship the fat Clay block only and record blink as a named limitation
   per D-G? Scout: both halves are cheap; the honest cost is that blink can
   never be asserted, so it must not be a *requirement* in a floor.
2. **Change 6 scope**: top rule only, or both spine boundaries symmetrically?
   Leaving the bottom blank-row makes the two halves of the same spine look
   different.
3. **Palette width vs contrast**: add `*_hl` roles for
   running/stopped-under-accent, or re-tune `accent` per theme so the
   existing `running`/`stopped` stay legible (keeps `PALETTE_SLOTS` = 13)?
4. **`st.rules` / `st.borders` re-derivation**: with the top rule moving from
   `betweenChildren` to a border, what is the new honest assertion for "the
   dividers come from Clay"? (D-D: re-derive, never lower silently.)
5. **T12 per-case inventory** was not read this pass; the re-derived
   `tui` floor cannot be set without it.
