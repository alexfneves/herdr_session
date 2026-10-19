# Requirement Changes Post-Planning

Read this **before** touching any UI code. Changes here **override** `docs/requirements.md`
and `plan.md` where they conflict.

---

## RCH-1 — No outer border around the application (user, 2026-10-19) — ✅ APPLIED (D14, commit c087c01)

> *"i want to remove the border around the application. i still want a division between the
> header, main content and footer"*

### What changes

| | Before (per `docs/requirements.md` diagram) | After |
|---|---|---|
| Outer border around the whole TUI | **Present** (all four sides) | **REMOVED** — no left/right/top/bottom box |
| Divider between Header ↔ Main | Present | **KEPT** |
| Divider between Main ↔ Footer | Present | **KEPT** |

Target layout:

```
         Header
────────────────────────
      Main content

────────────────────────
         Footer
```

i.e. the app is bounded only by the terminal edges; the **two horizontal rules between the three
sections remain**. The Header is no longer boxed and the Footer is no longer boxed.

### Implementation notes

- This is exactly the case our renderer already understands: **`BorderWidth.betweenChildren`**
  produces the divider, while the per-side widths (`left/right/top/bottom`) must be **0 / unset**.
- Do **not** set a `border` on the root element with `BorderAll(1)` — that is what draws the outer box.
- The dividers must come from the section container's `betweenChildren`, **not** from hand-painted glyphs
  (that is a forbidden anti-pattern — ISC-A: no hand-painted box glyphs outside Clay's knowledge).
- **`childGap` must stay ≥ 2** — established in Phase 2: at gap 1 the `betweenChildren` rule lands on the
  *following* child's row and paints over its text. Removing the outer border does **not** relax this.
- Removing the outer border **frees 2 columns and 2 rows** of usable space. Any width/height arithmetic
  that subtracted an outer-border allowance must be reviewed so content is not left short by 2.

### Affected acceptance criteria (must be updated when applied)

- **T5.1 acceptance** currently reads *"outer border + a rule between each section"* → becomes
  **"no outer border; a rule between Header/Main and between Main/Footer"**.
- Any UI smoke assertion counting border glyphs on the screen edge must be **inverted**: the first and last
  row/column must contain **no** box-drawing glyphs.
- Positive assertions stay: the two horizontal divider rules exist and sit between the sections.
- **"terminal too small" threshold** (~40×10) should be re-checked — the usable area grew by 2×2.

### Follow-ups when this is applied

1. Fold the change into `plan.md` (Decision Register **D14**) and `todos.md` (T5.1 acceptance text).
2. Re-run the full suite fixture-armed and confirm no regression count drops.
