# pty screen emulator and UTF-8 / escape-state across a resize

**Status: the byte-loss defect described below is FIXED** (`f9573cd`, folded `pty_screen` 73 → 163).
**Status: a SIBLING defect in the same file is OPEN** — see *Sibling defect* near the bottom.

---

## FIXED — an in-flight UTF-8 sequence was lost across `screen_resize`

**Found by:** the flood lane (`resize_flood` frame check). **Fixed by:** the pty lane, `f9573cd`.
**Was harness-only. No product bug.**

### Symptom (as it read before the fix)

`the surviving frame is the FINAL size, not a stale one — spine widths lo=118 hi=118 want 118
(last request 25x118, rules=1, settled=true)`

The width was **correct**. What was wrong is the rule count: the row held 115 correct `─` glyphs plus
**3 × U+FFFD**, so `rh_is_rule` rejected the row and `rh_rule_count` read 1 where the app drew 2 —
"stale frame" reported about a frame that was fine.

### Mechanism

```
screen_resize(s, rows, cols)  ->  screen_init(s, rows, cols)  ->  s.carry_len = 0
```

`carry` / `carry_len` hold a UTF-8 sequence split across `feed()` calls. A resize arriving mid-glyph
discarded the partial sequence; its continuation bytes then decoded with no lead byte and landed as
`U+FFFD`. A 2-byte split → 1 replacement char, 3-byte → 2, **4-byte astral → 3** (exactly the reported
signature).

### Two loss paths, not one

The brief described only the first. The lane found a **second, independent** instance of the same class
inside `screen_feed`'s 4096-byte working-buffer flush: the flush stashed an unfinished sequence into
`carry` and kept decoding the same feed — but `carry` is only **prepended at the start of a feed**, so
continuation bytes further down the buffer decoded as orphans and `carry` stayed dirty, corrupting the
*next* feed too. A full termbox frame exceeds 4096 bytes, so this fired on **every repaint**.

That is why fixing only the resize path was not enough — measured:

| tree | storms | frame-check failures | rate |
|---|---|---|---|
| pre-fix | 192 | 2 | 1.04% |
| carry/resize fix **only** | 96 | 2 | **2.08% — not sufficient** |
| **both fixes** | 288 (lane) / **64 (orchestrator, post-merge)** | **0** | **0.00%** |

### Why the fix is shaped this way

A partial sequence belongs to the **byte stream**, not to the grid — it has no cell yet, so there is no
reflow rule to invent. Resize blanks the grid (unchanged, python-faithful) and hands the pending bytes
straight back. `screen_init` stays a full reset including `carry`, because it is the **construction**
path: `pty_spawn` (one fresh driver per scenario) and every test-built `Screen`. A carry surviving
between scenarios would be cross-talk between unrelated byte streams.

**The wrong fix, explicitly rejected:** loosening `rh_is_rule` to tolerate `U+FFFD`. That hides a real
emulator defect behind a widened matcher and lets genuinely corrupt rule rows pass. The emulator has to
satisfy the matcher **as-is** — the new spine test ships a byte-exact local mirror of it for that reason.

---

## OPEN — SIBLING DEFECT: a resize mid-ESCAPE resets parser state, so surviving escape bytes paint as text

Found by the same lane while verifying. **Deliberately not changed** — same class, wider blast radius,
one-line extension away (preserve `state` / `csi_buf` / `csi_len` exactly as `carry` now is), but it is a
separate change with its own falsification and should be scheduled rather than tacked on.

| where the resize lands | what the emulator does today |
|---|---|
| mid-ESC | `[2;3HWORLD` painted as literal text → `row0='[2;3HWORLD'` |
| mid-CSI params | `row0='3HAGAIN'` — the parameters paint as text |
| mid-CSI digit | the CUP is destroyed; `Z` lands at col 0 instead of col 3 |
| mid-OSC | **window title leaks onto the grid**: `row0='tle:secret cd'` |
| mid-`ESC (` | `'Bion'` — the exact charset-smear class this emulator exists to prevent |

**Why it matters more than the carry bug:** the carry bug corrupted a glyph. This puts **control-sequence
bytes on the screen as content** — including an OSC payload (window title). Any suite that drives resizes
while the app is mid-escape can read a row that never existed, and a mid-OSC leak could surface a string
in a frame assertion that was never meant to be visible content.

**Probe preserved by the lane:** `/tmp/csi_probe_preserved_for_dispatch.odin` (`csi_probe_preserved_for_report.odin`
in the lane report) — reproduce before scheduling.

**Fix shape:** preserve the escape-parser state across `screen_resize` the same way `carry` is preserved.
Required falsification per row of the table above, plus the control that a resize with no pending escape
still blanks normally.

---

## Invocation note (cost a debugging cycle)

The pty test binary **must** be built with `-define:ODIN_TEST_THREADS=1`. Without it two pre-existing
tests fail — `driver_timing_requires_a_single_threaded_runner` and an fd-leak check — which reads as a
regression introduced by whatever you just changed. With it, the baseline is green.

```sh
odin build ./tests/pty -build-mode:test -define:ODIN_TEST_THREADS=1 \
     -define:ODIN_TEST_JSON_REPORT=/tmp/pty.json -out:/tmp/bin_pty
```
