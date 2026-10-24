# pty screen emulator and UTF-8 / escape-state across a resize

**Status: the byte-loss defect described below is FIXED** (`f9573cd`, folded `pty_screen` 73 → 163).
**Status: the SIBLING defect is ALSO FIXED** (`97d63b4`, folded into the same row → `pty_screen` 218).

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

## FIXED — SIBLING DEFECT: a resize mid-ESCAPE reset the parser, painting control bytes as text

**Fixed by:** the follow-on lane, `97d63b4` (+55 assertions, all in `screen_test`).

Found by the `f9573cd` lane while verifying. Reproduced pre-fix against `37acc76` with the preserved probe:

| where the resize lands | pre-fix behaviour (probe output) |
|---|---|
| mid-ESC | `post[state=NORMAL]`, `row0='[2;3HWORLD'` |
| mid-CSI params | `post[csi_len=0]`, `row0='3HAGAIN'` |
| mid-CSI digit | CUP destroyed — `Z` landed at `(0,1)` instead of `(2,3)` |
| mid-OSC | **window title on the grid**: `row0='tle:secretcd'` |
| mid-`ESC (` | `row0='Bion'` — the exact charset smear this emulator exists to prevent |

All five now falsified: each test **fails against pre-fix code and passes after**, with controls that a
resize with nothing pending still blanks normally, that a resize after a COMPLETE sequence preserves
nothing, and that `screen_init` remains a full reset.

### Design decision — preserve (a), not void-and-swallow (b)

A resize changes the **grid**, not what the next byte **means**. In a real terminal the parser lives in
the input layer (xterm's state machine, VTE's parser) and the grid is the terminal object; `SIGWINCH`
reshapes the grid and never touches the parser, so a straddling sequence continues and is evaluated
against the **new** geometry — the same argument that carried the `carry` fix.

**(b) was rejected on a concrete failure mode, not a preference:** voiding-but-swallowing does stop the
smear, but it drops a **positioning verb the app actually sent** — the cursor stays where it was while
the app believes it moved. Every subsequent write in that frame lands one cursor-jump off: a positional
desync that is **invisible to the very "no literal escape bytes on the grid" check that voiding exists to
satisfy**, corrupting the *next* frame instead of this one.

### Out-of-bounds CUP after resize (thought about, not sidestepped)

Completing the sequence makes this reachable, so it is proven on **both axes**:
- **Row** (CUP `9;4` on a 3-row grid): sequence still completes, nothing paints, **`dropped == 4`** —
  counted, not silent — and the next in-bounds CUP renders normally.
- **Column** (CUP `1;18` on a 10-col grid): `cx=17` out of range → **`dropped == 4`**, grid blank,
  recovers. **This path was silently discarding glyphs before** — the row guard counted, the column guard
  did not — so `screen_put_cursor` was made to count it. Slightly beyond the literal brief, entirely
  inside `screen.odin`, required by "no silent data loss".
- Coordinates valid for **both** sizes are unaffected.

`dropped` itself now **survives resize**: it is a stream-level audit counter, and wiping it on resize
would delete the evidence the counter exists to provide. Nothing else in the repo reads it.

### Post-fix verification

`pty_width 67 · pty_ffi 27 · pty_screen 218 · pty_driver 52` — no floor dropped, 364 pass / 0 fail.
5 fresh `resize_flood` runs (40 storms) with **0 failures**, `rules=2` read consistently where the flake
read `rules=1`.

---

## Invocation note (cost a debugging cycle)

The pty test binary **must** be built with `-define:ODIN_TEST_THREADS=1`. Without it two pre-existing
tests fail — `driver_timing_requires_a_single_threaded_runner` and an fd-leak check — which reads as a
regression introduced by whatever you just changed. With it, the baseline is green.

```sh
odin build ./tests/pty -build-mode:test -define:ODIN_TEST_THREADS=1 \
     -define:ODIN_TEST_JSON_REPORT=/tmp/pty.json -out:/tmp/bin_pty
```
