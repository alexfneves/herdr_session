# DISPATCH — UIP-5: the footer as coloured `Description: key` spans (ONE PASS)

**Workspace:** `/tmp/wt-ui-paint` on `feat/ui-paint-highlights`, HEAD `4a0f9ce`
**Task:** RCH-10 changes 7 + 8(AD-1) + 9(AD-2). **Depends on:** UIP-2 palette (landed — `key_fg`, `desc_fg` exist).
**Commit-first discipline applies:** smallest correct change → build → commit → iterate. Do not read for an hour first.

> **Line numbers below are current as of `4a0f9ce`, i.e. AFTER UIP-4 landed and shifted things.**
> Locate by **symbol name**, not by the number in `plan.md` — the plan's refs are stale by ~30 lines in these files.

## What is there right now (read this code, it was verified this session)

`src/ui/frame.odin`
- `Key_Hint :: struct` — `:235`
- `frame_footer :: proc(f: ^Frame, pal: ^Palette)` — `:583`. Renders `rest` in `pal.accent`, then
  **one single-hue `clay.Text(keys_line(f.keys, room), … textColor = pal.dim)`** — that call is the
  thing you are replacing with per-kind colour.
- `keys_line :: proc(keys: []Key_Hint, max: i32) -> string` — `:622`. Emits `"{} {}"` = **`key action`**,
  joined by `SEP`. **Retention rule (P3-12): cuts from the FRONT and marks the cut with `…` + SEP**, so
  the exit hint (always last in every `KEYS_*` table) survives and optional verbs are shed first.
- `SEP :: "  "` — `:660` (**two spaces**).
- `cat :: proc(a, b, c: string)` — right below `SEP`. **Use this, not format strings, to join user text.**
  It exists specifically to make the `%!(EXTRA …)` class of bug unreachable. Every new join goes through it.
- `keys_joined :: proc(keys, max)` — `:674`. Renders every hint untruncated.
- `ellipsize` and `text_cols` are the existing width helpers — keep using them.

`src/ui/keyhints.odin` — the single source of truth for the tables:
`KEYS_MODE :29 [8]` · `KEYS_ATTACH :40 [5]` · `KEYS_DELETE :48 [5]` · `KEYS_NAME :56 [4]` ·
`KEYS_PICK :63 [5]` · `KEYS_THEME :71 [5]`. `main`'s `KEYS_*` are **references** to these, not copies.

`src/main.odin` — `tui_keys :: proc() -> []ui.Key_Hint` at `:1224`.

`tests/unit/keyhints_test.odin` — `keyhints_mode_table_survives_the_width_sweep` at `:153`,
`widths: [8]int = {120, 100, 80, 60, 40, 30, 20, 10}`. **Floor for this row is 54.**

## The change (AD-1 — a format INVERSION, not a restyling)

Today: `r new remote` (key first). Required: **`New remote: r`** — description first, key second,
units joined by **` | `**.

**Two-tone:** `desc_fg` on the description, `key_fg` on the key. **The key must stay the visually
dominant token** (AD-1.2) — the user scans for an action and reads the key off the footer. Colour the
key so it catches the eye more than its description; do not let the description win.

**Spans become the source of truth so colour and text can never disagree:**
```odin
Footer_Span_Kind :: enum { .desc, .key, .sep }
Footer_Span      :: struct { text: string, kind: Footer_Span_Kind }

footer_spans :: proc(keys: []Key_Hint, max: i32) -> [dynamic]Footer_Span
keys_line     :: proc(keys: []Key_Hint, max: i32) -> string   // join(footer_spans(...))
```
`frame_footer` then renders **per-kind colour** instead of one `pal.dim` Text.
Keep `keys_line` working (the legacy bash suites and existing tests call it) — it becomes the plain-text
projection of the same spans, never an independently maintained string.

## AD-2 — the shortcut labels are NEW and SEPARATE

Do **not** derive a shortcut label from RCH-9's `state_label` (which returns "Name remote session" etc.).
Every shortcut gets its own display string — **leave none on the old pattern**:

| key | shortcut description | state |
|---|---|---|
| `r` | New remote | `remote_server` |
| `s` | **New named remote** | `name_remote_named` |
| `a` | Attach | `attach` |

Extend this to **every** hint in all six `KEYS_*` tables. Report any hint you could not give a sane
`Description: key` reading rather than leaving it in `key action` order.

## What genuinely changes and MUST be re-measured (AD-3) — do not assume

1. **Unit width.** `New remote: r` ≠ `r new remote`. The 8-width sweep moves: which hint survives at
   10/20/30 and where each hint crosses its own threshold must be **re-derived** against the new units.
2. **Separator cost.** ` | ` is **3 cells** per join vs today's `SEP` = 2 cells → **N hints cost N-1
   more cells.** Re-verify the never-blank rule and exit-hint survival at **40 columns**
   (`MIN_COLS`, `src/terminal/resize.odin:56`), not just at 100.
3. **Where the eye lands** — the key moves from leading to trailing inside each unit.

**What you must NOT "fix" (AD-3):** `keys_line` **already** drops whole hints and never half a hint,
and its retention rule is table-order-based ("keep the hints nearest the exit"), not format-based.
Inverting each unit's internals preserves that contract. Do not rewrite the retention policy.

## ONE PASS, not two (AD-4)

Colour and format land in the **same** pass. Two passes would break the landed 54 twice and make the
delta impossible to attribute.

## Falsifiability — rewrite the truncation predicate for the new atom

The existing `no_half_hint` predicate splits on the old separator; under ` | ` it would mis-slice.
The new predicate must split on `" | "` and require **every** visible piece to contain `": "`, so a
`"Attach:"` with no key, or a bare key, fails:
```odin
// how this fails: if truncation ever emits "Attach: " with no key, or a bare "a",
// a piece without ": " appears and partial > 0.
parts := strings.split_to_line(line, " | ")
partial := 0
for p in parts { if p == "" || p == "…" { continue }   // the front-cut marker stays legal
                 if !strings.contains(p, ": ") { partial += 1 } }
```
State explicitly in your report how the `…` front-cut marker interacts with the new split, and prove
the predicate still fails on a hand-fed half-unit.

## Hard constraints

- **Files owned:** `src/ui/keyhints.odin`, `src/ui/frame.odin`, `tests/unit/keyhints_test.odin`,
  `src/main.odin` (`tui_keys` only). Nothing else. **Do not touch `src/ui/edit.odin`,
  `tests/unit/caret_*` or `src/app/state.odin`** — those just landed and are not yours.
- **Do NOT touch `tests/parity.tsv`** — report numbers, the orchestrator folds them (D-D).
- **No hex colour literals in `src/ui/*`** (D-H). Use `key_fg` / `desc_fg` from the landed palette.
- **Join with `cat`, not format strings**, so no `%!(EXTRA …)` can ever appear in footer output.
  (There is a live, known gate failure of exactly this class in another suite — do not add a second one.
  Verify your own output contains no `%!` at all.)
- **Odin only. No Python / awk / sed / jq, including scratch analysis** (project requirement,
  `docs/requirements.md`, commit `0964357`). Escalate instead.
- **Never `git add -A`** — stage only your own paths.
- Live herdr sessions `2026-10-20-19-16-08-614` / `2026-10-20-21-07-27-640` off-limits; scratch
  `hs-t-*` only. Report `md5sum ~/.config/herdr_session.json` before/after — must stay
  `0cce060b885d2796d87ef1f4fd8d98b5`.
- **Odin gotcha:** `for a, b in slice` yields **(value, index)**.

## Verify after EVERY step

```sh
export PATH=/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/bin:$PATH
cd /tmp/wt-ui-paint
./dev/local-build.sh                                        # ~7-10 s, must be clean
BIN=/tmp/hs-local CASES="ui-frame" ./dev/ui-smoke.sh        # RCH-1 proof set
BIN=/tmp/hs-local ./dev/ui-smoke.sh                         # was 94/16/12/28/17/11
odin build ./tests/unit -build-mode:test -define:ODIN_TEST_THREADS=1 \
     -define:ODIN_TEST_JSON_REPORT=/tmp/unit.json -out:/tmp/bin_unit && /tmp/bin_unit
```
Hermetic rows that must not drop below landed values: `theme 157 · keyhints 54 · render 70 · app 446 ·
state 270 · diag 10 · selstate 16 · caret 90`. (`ui-edit` is currently **28** — UIP-4 raised it from 20.)
Report **every** delta with its cause.

## Acceptance

`keyhints` ≥ **54** with the numbers **re-derived** (report the delta and reason it as the AD-1
unit-width change), every width green **including 40**, no half unit, exit hint present at every width
the atom can fit, every hint on a `Description: key` string, key dominant over description.
*ISC-7, ISC-8, ISC-9.*

## Report

Per-step commit hashes · the new unit width per hint and the new survive/cut points at each of the 8
widths · how `…` front-cut interacts with the `" | "` split and the falsification you ran ·
every delta to the landed hermetic rows · the `%!`-free proof of the footer output ·
config md5 before/after · any hint you could not give a compliant description.
