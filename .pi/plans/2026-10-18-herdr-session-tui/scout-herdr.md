# Scout: herdr interface facts (verified on this machine)

Target: `herdr-session` TUI (Odin + Clay) that lists / creates / attaches / deletes herdr
sessions locally and over SSH, replacing `herdr-cycle`.

Environment actually probed:
- `herdr` binary: `/nix/store/fkm84xws43ayg977x569lciad2qcmk0b-herdr-0.8.2/bin/herdr`
  (on PATH via `~/.nix-profile/bin/herdr`), version **0.8.2**, socket protocol **20**.
- Installed from home-manager `unstablePkgs.herdr` (`modules/packages.nix:55`).
- **0.9.5 is available upstream** (`herdr-server.log`: "auto-update check: 0.9.5 available,
  waiting for explicit install"). 0.9.x adds a `herdr machine ...` subcommand that **0.8.2
  does NOT have** (verified: `herdr completion bash | grep -c machine` → `0`; unknown
  subcommands fall through to the generic help banner, exit 0 — do not rely on `machine`).
- All commands below were actually run from inside a live herdr pane
  (`HERDR_ENV=1`, `HERDR_SESSION=2026-08-11-23-37-41-812`).
- Docs cross-checked: https://herdr.dev/llms.txt → `persistence-remote.mdx`,
  `how-to-work.mdx`, `cli-reference.mdx`, `socket-api.mdx` (v0.9.5 rev).

---

## (a) Verified command table

Everything was executed here. "Format" = what stdout actually contains.

| Command | Exact syntax | Format | Notes / exit codes |
|---|---|---|---|
| list sessions | `herdr session list` | plain text, columns `name status directory socket` | exit 0. Columns are NOT padded consistently (status column overflows, see raw output below) — do **not** parse by column offsets, use `--json`. |
| list sessions JSON | `herdr session list --json` | single-line JSON object `{"sessions":[...]}` | exit 0. ~3 ms locally. Fields: `name, default, running, session_dir, socket_path` — **no timestamp field**. |
| create-or-attach (named) | `herdr session attach <NAME>` | TUI (alt screen) on stdout | **Creates the session if it does not exist** (this is how `herdr-cycle` creates sessions). Spawns the server first, then attaches. Requires a real controlling terminal, see (c). Empty name → `error: usage: herdr session attach <name>` + `run 'herdr --help' for usage`, exit **2**. |
| create-or-attach (flag form) | `herdr --session <NAME>` | same as above | Verified equivalent: `herdr --session zz-probe-flag` created `sessions/zz-probe-flag` and started a server. Name validation happens first: `error: session name may only contain ASCII letters, numbers, '.', '_' and '-'` + `run 'herdr --help' for usage`, exit **2**. |
| stop | `herdr session stop <NAME> [--json]` | JSON with `--json`: `{"session":{...},"stopped":true}`; plain: `stopped session <name>` | exit 0 on success. Failure: `{"error":{"code":"session_stop_failed","message":"session X is not running or cannot be reached at /home/…/sessions/X/herdr.sock: No such file or directory (os error 2)"}}`, exit **1**. |
| delete | `herdr session delete <NAME> [--json]` | JSON `{"deleted":true,"session":{...}}`; plain: `deleted session <name>` | exit 0. **Refuses running**: `{"error":{"code":"session_delete_failed","message":"session X is running; stop it before deleting"}}` exit **1**. **Refuses default**: `{"error":{"code":"session_delete_failed","message":"deleting the default session is not supported"}}` exit **1**. **Idempotent on missing**: deleting a non-existent session returns `deleted:true`, exit **0** (no existence check). |
| status (all) | `herdr status [--json]` | key/value text / JSON with `client`, `server`, `update` | exit 0 even when the server is not running. |
| status server | `herdr status server [--json]` | `{"status":"not_running","running":false,...,"socket":"...","session":"...","restart_needed":false}` | **exit 0 even when not running** (do not use exit code for liveness). Plain: `status: not running`. |
| status client | `herdr status client [--json]` | `version`, `channel`, `protocol`, `binary`, `session` | exit 0 |
| live snapshot | `herdr api snapshot` | JSON `{"id":"cli:api:snapshot","result":{"snapshot":{agents,focused_pane_id,focused_tab_id,focused_workspace_id,layouts,panes,protocol,tabs,version,workspaces}}}` (~22 KB here) | Targets the socket from `HERDR_SOCKET_PATH`. Overridable: `HERDR_SOCKET_PATH=/…/sessions/<other>/herdr.sock herdr api snapshot` returned the **other** session's data — verified. Useful for richer rows (agents/workspaces per session). |
| API schema | `herdr api schema [--json \| --output PATH]` | summary text; `--json` full JSON Schema (255 KB); `--output <path>` writes it | `--json` and `--output` are mutually exclusive (`usage: herdr api schema [--json \| --output PATH]` if both given). Schema saved during scouting at `/tmp/herdr-api-schema.json`. |
| remote attach | `herdr --remote <ssh-target> [--session <name>]` | TUI over ssh | Only valid as the *default* launch command. `herdr --remote host session list` → `error: --remote can only be used with the default launch command` + `run 'herdr --help' for usage`, exit **2**. |
| server stop | `herdr server stop` | — | Kills the server reachable via `HERDR_SOCKET_PATH`. Skill doc warns: never from an active session unless intended. |

### Real output samples

`herdr session list`:

```
name                 status   directory                                        socket
default              stopped  /home/alexfneves/.config/herdr                   /home/alexfneves/.config/herdr/herdr.sock
2026-08-11-23-37-41-812 running  /home/alexfneves/.config/herdr/sessions/2026-08-11-23-37-41-812 /home/alexfneves/.config/herdr/sessions/2026-08-11-23-37-41-812/herdr.sock
2026-08-30-14-59-10-730 running  /home/alexfneves/.config/herdr/sessions/2026-08-30-14-59-10-730 /home/alexfneves/.config/herdr/sessions/2026-08-30-14-59-10-730/herdr.sock
```

`herdr session list --json` (pretty-printed here; the CLI emits it on ONE line):

```json
{"sessions":[
  {"default":true,"name":"default","running":false,"session_dir":"/home/alexfneves/.config/herdr","socket_path":"/home/alexfneves/.config/herdr/herdr.sock"},
  {"default":false,"name":"2026-08-11-23-37-41-812","running":true,"session_dir":"/home/alexfneves/.config/herdr/sessions/2026-08-11-23-37-41-812","socket_path":"/home/alexfneves/.config/herdr/sessions/2026-08-11-23-37-41-812/herdr.sock"}
]}
```

`herdr status --json`:

```json
{"client":{"version":"0.8.2","channel":"stable","protocol":20,"binary":"/nix/store/.../bin/herdr","session":"2026-08-11-23-37-41-812"},
 "server":{"status":"running","running":true,"version":"0.8.2","protocol":20,
   "capabilities":{"live_handoff":true,"detached_server_daemon":true},"compatible":true,
   "socket":"/home/alexfneves/.config/herdr/sessions/2026-08-11-23-37-41-812/herdr.sock",
   "session":"2026-08-11-23-37-41-812","restart_needed":false},
 "update":{"restart_needed":false}}
```

Global exit-code convention (from `herdr --skill`, verbatim):
> "CLI server errors are JSON on stderr with exit status 1. CLI syntax errors exit with status 2."

Verified: `--json` errors go to **stderr** as JSON; success JSON goes to **stdout**.
So a JSON parser must read stdout and, on non-zero exit, parse stderr for `{"error":{"code","message"}}`
and surface `message` in the TUI's `{Error}` state.

### Session name rules (verified strings + live tests)

- Allowed: `[A-Za-z0-9._-]` — "session name may only contain ASCII letters, numbers, '.', '_' and '-'".
- "session name cannot be empty", "session name cannot be . or ..".
- Violations exit 2 before anything is created (verified with `--session 'bad name'`: nothing written).
- Docs add: names are case-sensitive; on case-insensitive filesystems `delete foo` refuses `Foo`.

---

## (b) Session data model + on-disk layout

Config/state root: **`~/.config/herdr/`** (`HERDR_CONFIG_PATH` overrides the *config file*
only — verified: `HERDR_CONFIG_PATH=/tmp/x.toml herdr session list` still listed the normal
sessions, and created nothing under `/tmp`). `XDG_STATE_HOME` is referenced by the binary for
other state (`~/.local/state/herdr/` holds agent-detection manifests + `status.toml`, not sessions).

```
~/.config/herdr/
├── config.toml -> ~/.config/home-manager/herdr/config.toml   (symlink from activation.nix)
├── session.json              # the DEFAULT session's persisted shape (dir == config root)
├── herdr.log / herdr-client.log / herdr-server.log   # default-session logs
├── release-notes.json
├── .plugins.lock
└── sessions/
    ├── <session-name>/            # one dir per named session; dir name == session name
    │   ├── session.json           # persisted workspace/tab/pane shape (schema version 3)
    │   ├── herdr.sock             # SERVER/API socket — present <=> server reachable
    │   ├── herdr-client.sock      # client bridge socket (used by remote attach)
    │   ├── herdr-server.log
    │   └── herdr-client.log
    ├── 2026-08-11-23-37-41-812/ # timestamp-created session (herdr-cycle naming)
    └── 2026-08-30-14-59-10-730/
```

Key facts:

- **`name` is the identity and the directory name.** There is no separate UUID. The
  "default" session is special: its `session_dir` is the config root itself
  (`~/.config/herdr`) and its socket is `~/.config/herdr/herdr.sock`; it can never be deleted.
- **Running vs stopped** (verified by creating, stopping, and deleting probe sessions):
  - *running*: server process alive (`herdr server`), `herdr.sock` present **and accepting**,
    `session.json` rewritten periodically (mtime moves).
  - *stopped*: `herdr.sock` and `herdr-client.sock` are **removed**; `session.json` + logs stay.
  - `session list --json`'s `running` is a **live connect probe**, not a file check: I dropped a
    plain (non-socket) file named `sessions/zz-probe-stale/herdr.sock` and `running` came back
    `false`; `herdr session stop` on it reported `Connection refused (os error 111)`.
  - **Use `running` from `--json`; nothing else is reliable.**
- **Timestamps: there is NO timestamp in the CLI output or `session.json`.** `session.json`
  top-level keys are exactly `version, workspaces, active, selected, sidebar_width,
  sidebar_section_split, collapsed_space_keys`. For the TUI's "timestamp" column use the
  filesystem: birth time is available (`stat -c %w` → e.g. `2026-08-11 23:37:41.834 +0200`,
  `2026-10-18 20:42:38.012 +0200`), `mtime` of `session.json` tracks last save.
  For `herdr-cycle`-created sessions the name itself encodes creation time
  (`YYYY-MM-DD-HH-MM-SS-mmm`), but arbitrary named sessions don't.
- Env vars herdr injects into panes (relevant to *our* program if it is launched inside herdr):
  `HERDR_ENV=1`, `HERDR_SESSION`, `HERDR_SOCKET_PATH`, `HERDR_CLIENT_SOCKET_PATH`,
  `HERDR_BIN_PATH`, `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID`.
  **`herdr session list` ignores these** (it lists all sessions from the config root), but
  `herdr status`/`herdr api snapshot` DO resolve their target from `HERDR_SOCKET_PATH`.
- `--no-session` = monolith escape hatch (no server/client). Not needed by us.

---

## (c) Terminal handoff (attach / create from a parent process)

Verified by running attach/`--session` with no controlling terminal (this agent's shell has none):

```
$ herdr session attach zz-probe-tmp < /dev/null
(stdout) ESC[?1006l ESC[?1016l ESC[?1015l ESC[?1005l ESC[?1003l ESC[?1002l ESC[?1000l ESC[?1049l
(stderr) thread 'main' panicked at .../ratatui-0.30.0/src/init.rs:299:16:
         failed to initialize terminal: Os { code: 6, kind: Uncategorized, message: "No such device or address" }
exit code: 101
```

and with `strace`:

```
openat(AT_FDCWD, "/dev/tty", O_RDONLY|O_CLOEXEC) = -1 ENXIO (No such device or address)
```

Facts and consequences for the wrapper:

1. **The herdr client needs a real controlling terminal** (`/dev/tty`); it panics (exit **101**)
   when there is none. Our TUI *will* have one, so a child herdr inherits it and works.
2. **Output goes to stdout** (the escapes above landed in a redirected stdout file), **raw mode
   comes from `/dev/tty`**. ⇒ Do **not** pipe the child's stdout/stderr; inherit them
   (`Stdio::inherit()`), otherwise the user sees nothing / escapes go nowhere.
3. **The server is spawned before the TUI init.** Even the failed attach left the session
   *running*. So "client exited" ≠ "session ended": **detaching in herdr (`prefix+q`) returns
   control to us but leaves the session running**. `herdr-cycle` compensates by explicitly
   `stop` + `delete`-ing after attach returns. Our `{Mode selection}` return must decide the
   same policy (see (e)).
4. herdr uses the **alternate screen** (`ESC[?1049h`) plus mouse tracking
   (`1000/1002/1003/1005/1006/1015`), focus reporting, bracketed paste and kitty-protocol
   keyboard enhancement; on exit it disables them and leaves 1049 (visible in the sample above).
   There is only ONE alternate buffer: when the child leaves it, the parent's alt-screen content
   is gone. Required sequence for "TUI disappears, then reappears":
   - stop rendering, drain/drop our input modes;
   - **leave our alt screen and disable mouse/focus/paste** (`ESC[?1049l`, `ESC[?1003l ESC[?1002l ESC[?1000l`, etc.) so the child starts clean;
   - `fork/exec` the child with inherited stdio in the **same foreground process group** (do not
     `setsid` — it needs our ctty);
   - block in `waitpid` (do NOT `SIGSTOP` ourself: a self-stopped process is not resumed by
     `SIGCHLD`; it needs `SIGCONT`, so simple wait is the robust choice);
   - after the child exits: **re-enter alt screen, clear (`ESC[2J ESC[H`), re-init raw mode/mouse,
     and do a FULL repaint** (assume nothing on screen).
5. **Signal hygiene during handoff**: the child shares our foreground process group, so Ctrl-C
   (`SIGINT`) and Ctrl-Z (`SIGTSTP`) reach *both* processes. Our TUI must block/ignore
   `SIGINT`/`SIGQUIT` while waiting for the child (herdr manages its own Ctrl+C inside panes),
   or we die mid-session. `SIGWINCH` will also arrive — ignore our own layout work while the
   child owns the screen; recompute after resume.
6. **Working directory matters**: the created session's initial workspace `identity_cwd` =
   the cwd of the herdr process (probe from `/tmp` produced `identity_cwd: "/tmp"`).
   Set the child's cwd explicitly (e.g. `$HOME`) before spawn.
7. **Exit code of a *successful* detach: UNVERIFIED** (no TTY available in this agent).
   Known codes: 101 = terminal-init panic, 2 = syntax/validation, 1 = server error. Assume
   "child exited, repaint and continue" and treat codes as informational only.

---

## (d) Remote / SSH — facts and unknowns

**Facts:**

- Only form supported: `herdr --remote <ssh-target> [--session <name>]`. There is **no**
  `herdr --remote <host> session list` (exit 2, "must be used with the default launch command").
  The default answer for listing is therefore: **run the CLI on the remote over plain ssh.**
  Verified end-to-end against `localhost`:
  ```
  ssh -o BatchMode=yes localhost 'herdr session list --json'   # exit 0, same JSON shape
  ```
  Remote `herdr` is on PATH for non-login shells here (`/home/alexfneves/.nix-profile/bin/herdr`).
- **Remote sessions are addressed exactly like local ones** — they live in the *remote user's*
  `~/.config/herdr/sessions/<name>`. The SSH target selects the machine; the session name
  selects the session on it. Nothing in the local CLI keeps a remote session registry (0.8.2).
- Unreachable host behaviour (verified):
  ```
  herdr --remote no-such-host-xyz
  stderr: error: remote platform detection failed: ssh: Could not resolve hostname no-such-host-xyz: Name or service not known
  exit 1
  ```
  (`ssh` itself exits 255; herdr wraps it into exit 1 with a one-line `error:` message. The
  message is NOT JSON, so the TUI must show raw text for remote failures.)
- SSH internals herdr uses (from binary strings + docs):
  `-F <generated config>` that `Include`s `~/.ssh/config` first, `-S <control socket>`
  ("ctl"), `-o ControlMaster=auto -o ControlPersist=yes`, `-o BatchMode=yes` for
  non-interactive probes, fallback `-o ServerAliveInterval 15 -o ServerAliveCountMax 4`,
  `-T ... /bin/sh -s` for the install bootstrap, `-C` (compression) in 0.9.x.
  `[remote] manage_ssh_config = true` (default) enables the generated config;
  `false` = plain ssh with the user's config unchanged.
  Since herdr shells out to the system `ssh`, **ProxyJump / ProxyCommand / ssh-agent /
  `~/.ssh/config` all work for `herdr --remote`**.
- **Non-interactive safety**: prompts like "continue installing the remote herdr binary? [y/N]",
  "stop the remote server and continue attaching? [Y/n]" abort when stdin is not interactive;
  docs: "non-interactive runs fail instead of modifying the host", default answer is No.
  This is important — our TUI is a non-interactive stdin parent, so a `--remote` run that would
  need to install/replace/restart something on the host **fails** rather than doing it.
- 0.9.x "saved SSH machines" (`herdr machine add/list/status/reconnect`, `--machine <label>`
  routing) is a **0.9-only feature; absent in the installed 0.8.2**. Do not depend on it.

**Unknowns (explicit):**

- **Where the user's "known remotes" come from.** There is **no `~/.ssh/config` on this machine
  at all** (`ls ~/.ssh` → `authorized_keys`, `id_ed25519[.pub]`, `known_hosts*` only).
  Only hostnames ever seen: `192.168.0.45`, `localhost`, `github.com` (from `known_hosts`).
  The home-manager zsh alias `mount` greps `~/.ssh/config` for hosts, so the *intended* source
  is `~/.ssh/config`, but the file is currently missing. ⇒ `~/.config/herdr_session.toml`
  almost certainly must own the remote list (with optional parsing of `~/.ssh/config` Host
  stanzas when present). **Decision left to planner.**
- Exact `--remote` handshake/exit codes on real (interactive) success, and behaviour on
  mid-session SSH drop (`lost connection to remote Herdr:`, `HERDR_REATTACH_COMMAND`,
  "If the remote server survived the SSH or network drop, its panes may still be running") —
  **not tested** (see Gotcha #6: testing `--remote localhost` here risks restarting the very
  server our own session runs in).
- Whether the remote host in this user's setup even has herdr installed (only `localhost`
  proven). Our TUI must handle "remote `herdr: command not found" in the ssh listing path.

---

## (e) `herdr-cycle.sh` — behavior to replace, and home-manager wiring

Files:
- `/home/alexfneves/.config/home-manager/herdr/herdr-cycle.sh` (executable, 7.6 KB)
- `/home/alexfneves/.config/home-manager/herdr/test-herdr-cycle.sh` (E2E tests, stubs `herdr`+`fzf`)
- symlinked to `~/.local/bin/herdr-cycle` by `home.activation.linkHerdrCycle`

### Behavior contract of herdr-cycle (from reading the whole script)

- Session listing: `herdr session list --json` filtered in Python, **dropping `default`**
  (`if s.get("default"): continue`), printing `"<name> (running|stopped)"`.
  The persistent `default` session is **never** part of the cycle.
- New session naming: `date +%Y-%m-%d-%H-%M-%S-%3N` (dash format because herdr forbids colons),
  regenerated in a loop if the name already exists.
- Named new session: prompt via bash `read -e`, validated against `^[A-Za-z0-9._-]+$`,
  final name = `"<typed>-<timestamp>"` (note: the timestamp suffix is appended, always).
- Creation = `herdr session attach "<n>"` (creates it) — the script never uses `herdr --session`.
- **Cleanup after every use**: `cleanup_session()` = `herdr session stop N || true` then
  `herdr session delete N || true`. Because a herdr session *outlives* the client, the cycle
  destroys the session when the user detaches.
- Flow:
  - no disposable sessions → create immediately (no menu), then cleanup, then **exit** (terminal closes).
  - otherwise fzf menu: `New session` / `New session with name` / `Attach to session (N)` /
    `Delete session (N)`; Enter selects, Ctrl-C on the main menu **closes the terminal**,
    Ctrl-C in submenus returns to the main menu.
  - Delete mode loops the picker until only ≤1 session remains, then exits; running sessions are
    `stop`ped before `delete`.
  - After every attach/create: if `session_count == 0` → exit; else return to the main menu.
- Exit code: always 0 in practice (`set -euo pipefail`, but all fzf/stop/delete failures are
  `|| true`-guarded or `case`-caught).
- Deps it declares: `herdr, fzf, python3, date`.

### Integration points in home-manager (`~/.config/home-manager`)

- `modules/activation.nix`
  - `linkHerdrConfig`: `ln -sfn ~/.config/home-manager/herdr/config.toml ~/.config/herdr/config.toml`
  - `linkHerdrCycle`: `mkdir -p ~/.local/bin; ln -sfn ~/.config/home-manager/herdr/herdr-cycle.sh ~/.local/bin/herdr-cycle`
    ⇒ **our program replaces this symlink target** (or, better, a new name and we repoint the
    Alacritty shell) so the same "editable, not-store-path" pattern is kept.
- `modules/editors/alacritty.nix` — the only launcher:
  ```nix
  terminal.shell = { program = "${config.home.homeDirectory}/.local/bin/herdr-cycle"; };
  ```
  i.e. **every new Alacritty window runs herdr-cycle**. Same program is bypassed elsewhere by
  `-e` (see spotatui). Alacritty starts maximized; catppuccin-latte palette; JetBrainsMono Nerd Font Mono.
  ⇒ Replacement = change this one `terminal.shell.program` line to our binary (absolute path or a
  `~/.local/bin/<name>` symlink), which is the drop-in "replace herdr-cycle" hook.
- `modules/packages.nix:55` — `unstablePkgs.herdr` (plus `fzf` at line ~25, needed by the old
  script only; our program removes the fzf dependency).
- `modules/spotatui.nix` — launches spotatui with `alacritty -o ... -e spotatui`, explicitly
  bypassing the `terminal.shell` override. Confirms the pattern: any launcher that must not show
  our TUI passes `-e`.
- `hosts/gmktec.nix` (`hostname = "gmktec"`), `hosts/work-notebook.nix` (`hostname = "afn"`):
  two home-manager hosts; the alacritty/activation modules are shared, so our replacement applies
  to both. `hostConfig.useNixGL` gates the nixGL wrap (irrelevant to us, but the TUI must not
  assume GPU-less vs GPU differences).

**Minimum behavior our program must reproduce:** open Alacritty → our TUI → let the user create / attach / delete sessions → hand the terminal to herdr → when herdr returns, come back → keep
the terminal window's "close when nothing to do" semantics optional (the old script exits when no
sessions remain). Whether our program auto-`stop`+`delete`s after detach is a **planner decision**:
`herdr-cycle` always does; the spec ("Once the herdr session ends ... the TUI appears in the Mode
selection") implies the same destroy-on-detach behavior for created sessions.

---

## (f) Not possible with the CLI (needs raw socket API, ssh, or files)

1. **Timestamps for sessions** — `herdr session list --json` has none. Must read filesystem
   stat (birth/`%w`, or `session.json` mtime) — locally, and over ssh (`ssh host stat ...`) for
   remote rows. Or accept name-derived timestamps for cycle-style sessions only.
2. **Listing remote sessions** — no `--remote` list mode. Must `ssh <target> herdr session list
   --json` ourselves (with a timeout, BatchMode, and `command -v herdr` preflight), and merge.
3. **Renaming a session** — no CLI command (`session` only has list/attach/stop/delete).
   Renaming means moving `sessions/<old>` → `<new>` by hand, which is **unsafe while the server
   runs** (the server holds the socket path). Not recommended; plan around it.
4. **Deleting a running session in one step** — must be `stop` then `delete` (two calls; delete
   refuses running). Also `delete` silently succeeds for unknown names, so we cannot detect typos.
5. **Liveness of the default session** — `herdr status server` exits 0 when not running; must
   parse `running`/`status`, not the exit code.
6. **Per-session rich state** (workspaces/agents/panes of *another* session) — the CLI targets
   `$HERDR_SOCKET_PATH` implicitly. Only possible by setting `HERDR_SOCKET_PATH=<session>/herdr.sock`
   per invocation (`herdr api snapshot`). Verified to work.
7. **Session names are the only handle** — no IDs, no labels, no per-session metadata. Anything
   richer (e.g. remembering "this session is remote hs on host X") must live in our own
   `~/.config/herdr_session.toml`.
8. **No event subscription through the CLI** — live updates (session started/stopped by someone
   else) require the raw socket API (`events.subscribe`, `events.wait` per the schema) or
   polling `herdr session list --json` (cheap: ~3 ms locally, but ssh-listing is expensive →
   throttle remote refreshes).
9. **`herdr machine …` / `--machine` remote registry is 0.9.x only** — unavailable on the
   installed 0.8.2; anything built on it breaks today.

---

## Gotchas

1. **Do not parse plain `herdr session list`** — the status column breaks alignment on long
   names (see sample). Use `--json` everywhere.
2. **`delete` is a no-op-success for non-existent sessions** — never treat it as validation.
3. **`stop` on the `default` session** hits `~/.config/herdr/herdr.sock`; if the default
   server isn't running you get exit 1. Never expose "delete default" (herdr refuses anyway).
4. **A session survives detach.** If our TUI's spec assumes "herdr exited ⇒ session gone",
   it must call `stop`+`delete` itself (that's exactly what `herdr-cycle.cleanup_session` does,
   with errors swallowed so leftovers stay visible in the picker).
5. **Full repaint is mandatory** after handoff (single shared alternate buffer).
6. **Do not test `herdr --remote localhost` casually from inside a herdr session**: same user +
   same `~/.config/herdr` means the "remote" server can be the very server hosting the current
   agent/session, and a restart/approval path exists in the code. (We deliberately did not test
   it.)
7. **Sessions are live, shared state** — parallel scouts created probe sessions
   (`hs-scout-probe-1`, `hs-scout-ghost-1`) during this investigation; both are gone again
   by the end. All my own probes (`zz-probe-tmp`, `zz-probe-stale`, `zz-probe-stream`,
   `zz-probe-flag`) were explicitly `stop` + `delete`-d. Never test create/stop/delete
   against anything but an obviously-scratch name, and always clean up afterwards.
8. **Version drift**: local 0.8.2 vs upstream 0.9.5. Session CLI is identical per docs, but
   `machine`/`--machine` are new in 0.9; also remote "endpoint generation" compatibility is a
   0.9 concept. Pin behavior to 0.8.2 and treat newer as additive.
9. **`--json` errors are on stderr**, success on stdout. A wrapper reading only stdout will see
   an empty body and must use the exit code + stderr parse.
10. **No `~/.ssh/config` exists on this host** — anything in the design that "lists remotes
    from ssh config" will produce an empty list today.
