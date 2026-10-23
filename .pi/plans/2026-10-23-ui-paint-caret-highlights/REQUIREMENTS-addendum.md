# RCH-10 requirement addendum — footer pattern + terminology

Recorded by the orchestrator when the user added these mid-scout. Binding.

## AD-1 — Footer shortcut pattern

Target format (sample, not exhaustive):

```
New remote: r | Named remote: s | Attach: a
```

Decomposed: **`<Description>: <key>`**, units joined by ` | `.

This **inverts the order** of the current pattern. Today `keys_line` renders
`"j move  k quit  enter open"` — key first, description second, space-separated.
The new pattern is description first, colon, then the key.

Decisions made (user unavailable; these are mine, apply uniformly):

1. **Separator is ` | `** — one space, a vertical bar, one space. Not `|`, not `  |  `.
2. **The key stays the visually dominant token.** Per change 7 the key and description get
   different colours: description in the muted role, key in the brighter `key_fg` role.
   Rationale: the user scans for an action and reads off the key; the key must catch the eye.
3. **Truncation must become unit-atomic.** This is the important consequence, see AD-3.

## AD-2 — Terminology

**"Named remote" becomes "New named remote".**

Shortcut description labels are NEW display strings, distinct from the state labels introduced in
RCH-9 (`state_label` returns "Name remote session" etc.). Do not derive one from the other
implicitly; keep them as separate display concerns so renaming a state does not silently rename a
shortcut, or vice versa.

Known mapping so far (extend for every shortcut, don't leave any on the old pattern):

| key | shortcut description | state |
|---|---|---|
| `r` | New remote | `remote_server` |
| `s` | **New named remote** | `name_remote_named` |
| `a` | Attach | `attach` |

## AD-3 — The collision this creates with a LANDED floor

`keyhints` is **already merged with floor 54** and its tests assert two things this change breaks:

1. **The ORDER contract.** The note at `src/keyhints.odin:22` records that every table's LAST hint
   is an exit/back/dismiss action, *because `keys_line` fills from the exit side and cuts from the
   front*. With the description now leading each unit, cutting "from the front" cuts
   **descriptions**, not keys. The reason the old contract existed no longer holds, so the contract
   itself must be re-derived rather than preserved verbatim.

2. **The 8-width overflow sweep** (`tests/unit/keyhints_test.odin:149-179`): asserts the exit hint
   survives, `t theme` survives above its own width threshold, nothing overflows, **no hint is cut in
   half**, and the line is never blank. Under the inverted format "cut in half" now has a new
   meaning — `New named remote: ` with the key missing is a half-cut that the old test could not
   express.

Required resolution: **a hint unit is kept whole or dropped whole.** A visible `Description:` with no
key, or a `: k` with no description, is always a bug. The exit/back/dismiss hint must still survive
to the narrowest supported width, and the never-blank rule still holds.

Do NOT satisfy the old test by keeping the old order. Re-derive the assertions for the new format and
keep their strength. Per D-D: record the floor delta in `tests/parity.tsv` explicitly as a
consequence of RCH-10/AD-1 if the count of checkable properties changes — never quietly.

## AD-4 — Relationship to the other footer change

Change 7 (key and description get different colours) and AD-1 (new pattern) are the **same
subsystem and must be designed together**, not as separate edits. Two-tone colour plus inverted
order plus a ` | ` separator plus unit-atomic truncation is one coherent change to `keys_line`.
Implementing them as two passes would twice-break the landed 54.
