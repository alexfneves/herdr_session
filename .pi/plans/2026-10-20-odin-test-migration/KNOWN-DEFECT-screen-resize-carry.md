# KNOWN DEFECT — pty screen emulator drops an in-flight UTF-8 sequence on resize

**Found by:** the flood lane (`resize_flood` frame check), reported in its final report, corroborated by the orchestrator.
**Location:** `tests/pty/screen.odin` — `screen_resize` → `screen_init`, `carry_len = 0` (`:98`).
**Severity:** harness-only. Causes a ~2% flake in any suite that resizes while the app is mid-glyph. **No product bug.**

## Symptom

`the surviving frame is the FINAL size, not a stale one — spine widths lo=118 hi=118 want 118
(last request 25x118, rules=1, settled=true)`

The width is **correct**. What is wrong is the rule count: the row holds 115 correct `─` glyphs plus
**3 × U+FFFD**, so `rh_is_rule` rejects the row and `rules` reads 1 instead of 2. The check therefore
reports "stale frame" when the frame is fine and the *emulator* lost bytes.

## Mechanism (verified in code)

```
screen_resize(s, rows, cols)  ->  screen_init(s, rows, cols)  ->  s.carry_len = 0
```

`carry` holds a UTF-8 sequence split across `feed()` calls (`screen.odin:78-81`). A resize arriving in
the middle of a multi-byte glyph discards the partial sequence. The continuation bytes that arrive next
are then decoded without their lead byte and land in the grid as `U+FFFD`.

The lane's isolation test: whole glyph → clean · split glyph, **no** resize → clean ·
split glyph **+** resize → `"\ufffd\ufffdCD"`.

**The app is exonerated directly:** in real failing reps the driver's `raw` byte stream contained
**0 orphan continuation bytes** — the app wrote well-formed UTF-8 and the emulator lost it.

## Rate (measured, pre-existing)

| binary | failing storms | rate |
|---|---|---|
| pre-change (`792a350` era) | 3 / 120 | 2.5% |
| post-change (d.1 merged) | 7 / 320 | 2.2% |

Same rate before and after the flood reformulation. The check text itself is byte-identical to the
pre-change version (md5 `ac988a…`), so this is **not** a consequence of the invariant work — the
flood lane just ran enough storms to see it.

## Fix

Preserve `carry` (and `carry_len`) across `screen_resize` — the partial sequence belongs to the byte
stream, not to the screen geometry, so a resize must not consume it. Grid contents legitimately reset
(no reflow rule invented); the carry buffer must not.

**Do not** "fix" it by making `rh_is_rule` tolerate U+FFFD — that hides a real emulator defect behind
a widened matcher and would let genuinely corrupt rule rows pass.

## Falsifiable test required with the fix

Feed a multi-byte glyph split across a `screen_resize` boundary and assert the glyph is intact in the
grid afterwards — and that the same split **without** a resize still works (control). State how the
test fails against the current code.

## Why this matters beyond one flake

Every suite that resizes during paint (resize tier, and anything driving a drag) inherits this. At ~2%
per storm, a lane running 8-storm sets will hit it roughly once every 6 runs, which is exactly the kind
of low-rate noise that gets a real check widened or disabled by the next person who hits it.
