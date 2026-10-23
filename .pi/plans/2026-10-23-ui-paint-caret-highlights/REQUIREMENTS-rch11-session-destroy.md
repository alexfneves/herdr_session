# RCH-11 — Destroy the session when the program returns

> **AMENDED by the user 2026-10-23. This section supersedes the interpretation below.**

**Applies to BOTH create AND attach.** When we create or attach to a session we know its name; when
herdr returns to us, we delete that session by name using the herdr CLI:

```
herdr session delete <SESSION_NAME>
```

**No signal handling is required, and none should be added.** The natural return point — herdetaching
with `Ctrl+B q`, which hands the terminal back to our program — is the trigger. Do not build signal
handlers, crash-reconciliation ledgers, or orphan sweeps for this feature.

**The user's reasoning, recorded because it is the design rationale:** the user retains both choices.

| what the user does | outcome |
|---|---|
| closes the terminal | herdr keeps running — session preserved |
| `Ctrl+B q` (detach) → returns to our program | our program deletes that session |

**The earlier data-loss objection is explicitly withdrawn.** The user considered it and rejected it:
because "keep it alive" is served by closing the terminal, destroying the session on the
return-to-our-program path is not data loss — it is the other half of the choice. It applies to
attached sessions too, including ones that already existed.

## Still required — the guards that are unrelated to create-vs-attach

The withdrawal of the data-loss objection does **not** remove the wrong-target risks:

1. **Never delete `HERDR_SESSION`** — the session this program runs *inside*. Deleting it kills the
   user's own session and our own process. Refuse explicitly.
2. **Never delete `default`** — existing rule D12.
3. **Correct device.** A remote session must be deleted through its remote device path. Running
   `herdr session delete <name>` locally against a remote row destroys a *different* local session of
   the same name (`src/app/herdr.odin:708-712`).
4. **Go through `app.delete_session`, not a hand-built argv.** This is not a bypass of the user's
   instruction — `delete_session` **is** `herdr session delete --json <name>` under the hood
   (`delete_argv`, `herdr.odin:691-696`), plus: stop-before-delete (herdr refuses to delete a running
   session), name validation, and the model pre-check that stops us logging the `deleted:true` lie for
   a session that never existed (rule 4). Use it as-is.
5. **Track the name we handed off**, per `(device, name)`, from the moment `launch_argv` /
   `attach_argv` is used, so the return path has an unambiguous target rather than re-deriving it
   from whatever is selected on screen.

## The old interpretation — superseded, kept for provenance

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

## Trigger point (NOT signals — per the user's explicit instruction)

**No signal handlers. No crash ledger. No orphan sweep.** The trigger is the **natural return** of the
herdr child:

```
our program --launch/attach--> herdr (takes the terminal)
       ^                              |
       +---- Ctrl+B q detaches -------+
                 |
                 +--> delete the session by the name we handed off
```

`app.execute(cmd, …)` in `tui_run_command` (`src/main.odin:640`) is the choke point where
launch/attach happens. The delete belongs on the path where that handoff **comes back**, using the
`(device, name)` recorded at handoff time.

**Terminal close is intentionally NOT a trigger.** If the user closes the terminal, herdr keeps running
and the session is preserved — that is the other half of the user's choice and must not be broken by
adding cleanup where it was not asked for.

## Testing requirements

- Create a session, detach back → session **gone** (stop then delete, via `delete_session`).
- Attach to an existing session, detach back → session **gone**. *(This is the amended behaviour — the
  earlier "attach survives" test is withdrawn.)*
- `HERDR_SESSION` refused on the destroy path — and asserted, because getting this wrong kills the
  user's own session.
- `default` refused (D12).
- Remote session deleted via its **remote** device path; a local session sharing that name is
  **untouched**.
- Each test asserts the **actual session state after** the run (re-list and check absence), not merely
  that a delete command was issued. Per D-E: state how each could fail.
- Closing-the-terminal / no-return case must NOT destroy — worth a test so a future contributor does not
  "helpfully" add cleanup at exit.
- Anything needing a real remote belongs to the **T14 fixture lane** — reported, not dropped.

## Sequencing

- **After RCH-10 merge**, its own branch. Do not mix with paint.
- Local create/attach/destroy cases can be hermetic; remote cases need the T14 fixture lane.
- `tests/parity.tsv` gets a **new additive row** — this behaviour has no predecessor in the bash
  baseline. Applied by the orchestrator, not the lane.

## Superseded concern (kept for provenance)

An earlier draft of this document objected that destroying attached sessions risks deleting pre-existing
work, and proposed a created-by-us snapshot. **The user reviewed and explicitly overrode it:** closing
the terminal is how you keep herdr running, so the return path is free to destroy. Do not re-introduce
the snapshot as a hedge.
