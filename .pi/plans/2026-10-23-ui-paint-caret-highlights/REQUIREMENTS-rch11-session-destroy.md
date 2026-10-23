# RCH-11 — Destroy the session when the program returns

Requirement (user): **"When the herdr program returns, the session must be destroyed."**

Recorded as its own change group, **separate from RCH-10 (paint)**. A destructive lifecycle change
must not ride inside a cosmetic branch — it needs its own review, its own tests, and its own revert.

## Interpretation (user unavailable; this is the orchestrator's decision)

When `herdr-session` exits, **destroy the session that this run actually CREATED.**
Sessions that merely existed before we ran, or that we attached to, **survive**.

Rationale, in the code's own terms: this product manages long-lived sessions. Making every touched
session die on exit would delete other people's work. "Destroyed when we return" is implemented as
"we clean up what we brought into existence."

## THE DATA-LOSS TRAP — read before implementing

**`launch_argv` is CREATE-OR-ATTACH. There is no `herdr session create`** (`src/app/herdr.odin:655-669`):

```
local : herdr --session <name>
remote: herdr --remote <device> --session <name>
```

The same command both creates a new session and attaches to a pre-existing one, and **the call site
cannot tell which**. A naive "destroy the launched session on exit" therefore **deletes sessions that
existed before we started**. That is user data loss, introduced by a plausible-looking
implementation of a reasonable-sounding requirement.

**Required guard: take a pre-launch snapshot.**

1. Snapshot the session list (`session list --json`, already available as `list_argv`) **before** the
   launch.
2. Record, per launched identity `(device, name)`, whether it was **absent** in that snapshot.
3. On exit, destroy **only** the identities recorded as created-by-us.
4. Never destroy anything not in that created-by-us set — not the pre-existing row with the same name,
   not the other rows on screen, not the current selection.

The tracking must be per-identity `(device, name)`, consistent with how the code already treats
session identity.

## Hard prohibitions (non-negotiable)

1. **NEVER destroy `HERDR_SESSION`** — the herdr session this program runs *inside*. The literal
   reading of "when the herdr program returns, destroy the session" could mean the containing herdr
   session. Doing that kills the user's own session and our own process. Add an explicit assertion
   that the destroy path refuses any name equal to `HERDR_SESSION`, and that it refuses when
   `HERDR_ENV` indicates we are inside a managed session we did not create.
2. **NEVER destroy `default`** — existing rule D12; `delete_session` already refuses it. Do not bypass
   the guard by calling `delete_argv` directly. **All destruction must go through
   `app.delete_session`**, never a hand-built argv.
3. **Respect the remote/local footgun.** A remote row must be destroyed through the remote device path;
   running `herdr session delete <name>` locally against a remote row destroys a *different* session
   that happens to share the name (`herdr.odin:708-712`).
4. **Do not trust `delete`'s answer.** `herdr session delete <never-existed>` returns **exit 0 with
   `{"deleted": true}`** (rule 4). The model decides, not herdr — so the created-by-us ledger is the
   authority on what to destroy, and `delete_session`'s pre-check stays.

## Exit-path coverage — and the honest gap

| exit path | can we destroy? | handling |
|---|---|---|
| `quit` / normal return | yes | `tui_run` teardown already retires children; add the destroy step there |
| Ctrl-C / SIGINT | yes | restore-terminal path must run the destroy too |
| SIGTERM / SIGHUP | yes | same path that restores the terminal (`install_terminal_restore_handlers`) |
| **SIGKILL / crash / OOM** | **NO** | **unfixable in-process. Document it.** |

For the unfixable case, do not pretend. Two-part answer:
- Record the created-by-us ledger to a small state file under the scratch convention so a later run
  can **reconcile orphans** and report them.
- A next-start reconciliation that *reports* orphaned sessions is acceptable; silently deleting on the
  strength of a stale ledger file is **not** — a stale file could name a session someone else is using.
  Report and require an explicit action.

## Testing requirements (this is where it must be proven)

- **The trap must have a test that would catch a naive implementation**: pre-existing session with the
  same name, program launches (attaches), exits → session **still exists**.
- Program creates a session, exits → session **gone** (stopped then deleted, via `delete_session`).
- Program attaches only → nothing destroyed.
- `HERDR_SESSION` and `default` refused on the destroy path.
- Remote identity destroyed via the remote path, and a local same-name session untouched.
- Each destroyed-session test must assert the ledger said "created by us" and that the destroy count
  matches — not just that a delete was attempted. Per D-E, state how each could fail.
- Fixture-tier notes: anything needing a real remote goes to the T14 fixture lane, reported not dropped.

## Sequencing

- **After RCH-10 merge**, own branch. Do not mix with paint.
- Requires the T14 fixture lane for the remote cases; the local create/attach/destroy cases can be
  hermetic.
- `tests/parity.tsv` gets a **new additive row** (this behaviour has no predecessor in the bash
  baseline), applied by the orchestrator, not the lane.

## Open question I am explicitly NOT deciding by guesswork

If the user actually intends "every session shown/used must die on exit, including pre-existing ones",
that is a **different and much more destructive** product, and it contradicts the existing D12 /
create-or-attach / never-trust-delete safety model. This plan implements the **created-by-us**
reading. If the broader reading was intended, it needs an explicit product decision and its own
safety review — it should not be implemented by extending this one.
