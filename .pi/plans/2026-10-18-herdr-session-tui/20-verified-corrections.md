# MAIN-SESSION VERIFIED CORRECTIONS

Independently re-tested facts where scout reports were wrong or where the stakes are high.
These **override** the corresponding scout claims. All probes cleaned up (verified at the end).

## C1. ⚠️ CORRECTION — Error JSON lands on **STDERR**, not stdout

`scout-herdr.md` and `scout-remote-flow.md` both said error JSON goes to **stdout**. **That is wrong.**

Verified directly:

```
$ herdr session stop --json hs-nonexistent-zz-99   → exit 1
  STDOUT:  (empty)
  STDERR:  {"error":{"code":"session_stop_failed","message":"session hs-nonexistent-zz-99 is not
            running or cannot be reached at .../herdr.sock: No such file or directory (os error 2)"}}

$ herdr session stop hs-nonexistent-zz-99          → exit 1
  STDOUT:  (empty)
  STDERR:  {"error":{...}}     ← same, even WITHOUT --json
```

**Design consequence:** capture stdout and stderr **separately, never merged**.
- exit 0 → parse **stdout**
- exit ≠ 0 → parse **stderr** for `{"error":{"code","message"}}`
- Merging them (`2>&1`) will corrupt JSON parsing. The panic path also writes Rust panics to stderr.

## C2. CONFIRMED — `delete` lies about non-existent sessions

```
$ herdr session delete --json hs-never-existed-zz-99 → exit 0
  {"deleted":true,"session":{"name":"hs-never-existed-zz-99", ...}}
```
Exit 0 + `deleted:true` for a session that **never existed**. **Never** treat delete success as validation —
check existence against the cached list first, or we will report success for typos.

## C3. 🚨 BLOCKER CONFIRMED — nested herdr blocks ALL launch/attach from inside a herdr pane

Our wrapper **runs inside herdr** (it replaces `herdr-cycle.sh`, the Alacritty shell; currently
`HERDR_ENV=1`, `HERDR_SESSION=2026-08-11-23-37-41-812`).

```
$ env HERDR_ENV=1 herdr --session hs-nestcheck-zz        → exit 1
  error: nested herdr is disabled by default. see configuration if you want to enable it.
$ env HERDR_ENV=1 herdr --remote localhost --session hs-nestcheck2-zz   → exit 1
  (same error) + "error: remote client exited with exit status: 1"
```
⇒ **Without a fix, every create/attach/delete-launch the product performs fails. 100% broken.**

Note the asymmetry: **read-only commands are unaffected** —
`env HERDR_ENV=1 herdr session list --json` → **exit 0, normal output**. Only the *launching* paths
(`herdr --session`, `herdr --remote`, `herdr session attach`) are blocked.

**The fix is confirmed working:**

```
$ env -u HERDR_ENV herdr --session hs-scrubcheck-zz   → exit 101 (ratatui tty panic)
```
Exit 101 = it got **past** the nesting check and died only because this test shell has no tty.
⇒ **Scrub `HERDR_ENV` from every launched child's environment.**

`HERDR_ENV=0` does **not** work as a bypass (same as unset for list; the *presence* of `HERDR_ENV=1` is the
trigger — scrub the var, don't set it to 0).

Alternative (NOT recommended): `experimental.allow_nested = true` in herdr config — the user's
`~/.config/home-manager/herdr/config.toml` contains **no such key** today (only `[keys] [terminal] [theme] [ui]`),
so this would require modifying the user's herdr config. Scrubbing is the portable fix.

## C4. 🚨 ORPHAN TRAP CONFIRMED — a crashing attach still creates a running session

Reproduced in C3's fix test: `env -u HERDR_ENV herdr --session hs-scrubcheck-zz` **panicked on tty init**
(client never drew a frame), yet `~/.config/herdr/sessions/hs-scrubcheck-zz` **was created** and appeared in
the session list. The server spawns *before* terminal init.

**Design consequence (hard requirement): never attach to a name we have not validated against the
currently-loaded session list.** A typo or a stale row silently creates a zombie session.

## C5. Cleanup proof

```
$ ls ~/.config/herdr/sessions/
2026-08-11-23-37-41-812        ← pre-existing (user's live session)
2026-08-30-14-59-10-730        ← pre-existing (running before this task began)

$ herdr session list --json
[('default', False), ('2026-08-11-23-37-41-812', True), ('2026-08-30-14-59-10-730', True)]

$ ls ~/.config/herdr/sessions/hs-*   → no such file (all probes removed)
```
Tests run from `/tmp` so no `identity_cwd` side effects. No `~/.ssh/config` created.

---

## Consolidated exit-code contract (verified across scouts + main session)

| Code | Meaning | Where the message is | Wrapper action |
|---|---|---|---|
| `0` | success | stdout (JSON with `--json`, plain text otherwise) | proceed |
| `1` | herdr error: nesting disabled, config error, delete-on-running, stop-failed | **stderr** JSON `{"error":{code,message}}` | show `message` in `{Error}` |
| `2` | CLI syntax / name validation | stderr + `run 'herdr --help' for usage` | show; shouldn't happen if we pre-validate |
| `101` | terminal-init panic (no tty) | **stderr** (Rust panic, NOT JSON) | show generic "needs a real terminal" |
| `124` | our own `timeout` fired | — | "timed out" |
| `127` | `herdr: command not found` on remote | stderr | distinct "remote has no herdr" state |
| `255` | ssh transport/auth failure | stderr (ssh's own) | "unreachable / auth failed" per-host |

**Rule: never merge stderr into stdout when a `--json` parse follows.**
