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

## AD-3 — Effect on the LANDED `keyhints` floor 54 (corrected after reading the code)

Read `keys_line` at `src/ui/frame.odin:576-600` before designing against this. Two findings that
narrow the risk from what I first assumed:

**Already safe — do not "fix" it.** The existing implementation already **drops whole hints and never
half a hint**, and the retention rule is *table-order based* ("keep the hints nearest the exit, drop
the ones furthest from it"), not format-based. So inverting each unit's internals does **not** break
unit-atomicity, and a `Description:` with no key cannot occur. The exit-visibility contract survives
this change essentially intact.

**What genuinely changes:**
1. **Unit width.** `New remote: r` vs the old `r new remote` adds the colon and shifts every glyph.
   Total line width changes, so the **8-width overflow sweep** (`tests/unit/keyhints_test.odin:149-179`)
   thresholds move: which hint survives at 8 cells, and where `t theme` crosses its own threshold,
   must be re-measured against the new units, not assumed identical.
2. **Where the eye lands.** The key moves from the leading position to the trailing position of each
   unit. Combined with AD-1's two-tone colour this is the real user-visible change.
3. **Separator cost.** ` | ` is 3 cells per join, so N hints cost 3*(N-1) more cells than today.
   At the narrow end this pushes hints out earlier. Verify the never-blank rule and the exit-hint
   survival at the narrowest supported width (40 cols), not just at 100.

Keep the assertions' strength; re-derive their numbers. Per D-D: if the count of checkable
properties changes, record the delta in `tests/parity.tsv` explicitly as a consequence of
AD-1/RCH-10 — never quietly.

## AD-4 — Relationship to the other footer change

Change 7 (key and description get different colours) and AD-1 (new pattern) are the **same
subsystem and must be designed together**, not as separate edits. Two-tone colour plus inverted
order plus a ` | ` separator plus unit-atomic truncation is one coherent change to `keys_line`.
Implementing them as two passes would twice-break the landed 54.
