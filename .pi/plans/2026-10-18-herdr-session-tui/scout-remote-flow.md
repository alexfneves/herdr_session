# Scout report — `ssh -t` tty mechanics + remote herdr session flow

**Date:** 2026-10-18 (all timestamps local, host `gmktec`, Linux x86_64)
**herdr:** 0.8.2 (`/home/alexfneves/.nix-profile/bin/herdr`), protocol 20, `default` channel
**Fixture remote:** `ssh localhost` (passwordless, BatchMode-clean)
**Everything I created was deleted — see §(g) Cleanup proof.** No leftovers, no `hs-scout-*` sessions, `~/.ssh/known_hosts` byte-identical before/after (mtime + size unchanged), `~/.config/herdr/config.toml` untouched.

**Harness note:** this scout's shell has *no* controlling terminal, so every "interactive" test was run under a real
pty allocated with `script -q -e -c "stty rows 40 cols 120; <cmd>" /dev/null` (util-linux 2.42.2), which is a
faithful stand-in for "our wrapper TUI running inside alacritty". Where that is not sufficient proof, the item is
listed in §(h) as needing manual interactive verification. "pty" below means the wrapper is on a real terminal.

---

## (a) `-t` / tty mechanics

| # | Command | Local tty | Remote `tty` | Remote `$TERM` | Remote `stty size` | Exit | Wall |
|---|---|---|---|---|---|---|---|
| 1 | `ssh -t localhost 'echo hi'` | yes | allocated | xterm-256color | — | 0 | ~150ms |
| 2 | `ssh -t localhost 'stty size; tty; echo $TERM'` | yes (40x120) | `/dev/pts/26` | `xterm-256color` | `40 120` | 0 | 153ms |
| 3 | `ssh localhost 'stty size; tty; echo $TERM'` (**no -t**) | yes | `not a tty` | **empty** | `stty: 'standard input': Inappropriate ioctl for device` | 0 | 151ms |
| 4 | `ssh -tt localhost 'stty size; tty; echo $TERM'` | yes (40x120) | `/dev/pts/26` | `xterm-256color` | `40 120` | 0 | 161ms |
| 5 | `ssh -t localhost '...'` with **stdin not a tty** (`< /dev/null`) | **no** | **NOT allocated** | empty | ioctl fails | 0 | ~150ms |
| 6 | `ssh -tt localhost '...'` with stdin not a tty | **no** | `/dev/pts/26` (**forced**) | `xterm-256color` | `0 0` | 0 | ~150ms |

Observed stderr for case 5 (the silent-degradation trap):

```
Pseudo-terminal will not be allocated because stdin is not a terminal.
stty: 'standard input': Inappropriate ioctl for device
not a tty
TERM=
```

**Facts:**

1. `-t` allocates a remote pty, forwards `$TERM`, and propagates the *local* window size (`40 120` → remote `40 120`).
2. Without `-t` the remote command gets **no tty and no `$TERM` at all**. Full-screen TUIs cannot run (confirmed in §c: herdr panics).
3. `-tt` == `-t` when a local tty exists; it is the *only* variant that forces remote allocation when there is no local tty.
4. Plain `-t` **fails open**: if stdin is not a tty it silently downgrades to a no-pty session and still exits 0. Never rely on `-t` alone if stdin might be redirected; use `-tt`.
5. `-tt` with no local tty yields winsize `0 0`. herdr then reports the client as `cols=1 rows=1`. **Our wrapper must be running on a real, correctly sized terminal** (it will be — it *is* the TUI), or explicitly `TIOCSWINSZ` the pty it creates.
6. **Exit codes propagate** through the pty: `ssh -t localhost 'exit 7'` → 7.
7. **ssh's own chatter goes to stderr, not stdout.** `Connection to localhost closed.` never pollutes stdout, so `ssh -T host 'herdr session list --json' | parse` is safe.
8. `herdr --remote` **requires the local side to have a tty** regardless of ssh: run it with `stdin=/dev/null` and the local client dies with a Rust panic (see §c, A1). So the wrapper must be launched from a terminal, never detached.
9. Is `-t` required for the *interactive* remote attach path? Yes for raw `ssh`-driven attach (`ssh -t host 'herdr session attach N'` works, plain `ssh` panics). It is **not needed for the list/fetch path** — use `ssh -T` there (cleaner + ~20ms faster, see §d).

---

## (b) Observed remote create / list / attach / stop / delete transcript

### Command surface (from `herdr --help`, `herdr session --help`)

```
herdr                                # launch/attach the persistent session
herdr --session <name>               # use OR CREATE a named session
herdr --remote <ssh-target> [--session <name>]   # attach through SSH to a remote herdr server
herdr session list [--json]
herdr session attach <name>          # ⚠ create-or-attach, see gotcha G1
herdr session stop   <name> [--json]
herdr session delete <name> [--json] # refuses to delete a RUNNING session
herdr server stop / herdr status / herdr api snapshot
```

There is **no `herdr session create`**. Creation is a side effect of launching (`--session`/`--remote`).

### b.1 List — the parse target

```
$ herdr session list            # no tty needed, exit 0, 3 ms local
name                 status   directory                                        socket
default              stopped  /home/alexfneves/.config/herdr                   /home/alexfneves/.config/herdr/herdr.sock
2026-08-11-23-37-41-812 running  /home/alexfneves/.config/herdr/sessions/2026-08-11-23-37-41-812 .../herdr.sock
2026-08-30-14-59-10-730 running  ...
```
> Note the plain format is **misaligned** (fixed-width headers vs. variable-width rows) — do not parse it. Use `--json`.

```
$ herdr session list --json        # exit 0
{"sessions":[
  {"default":true, "name":"default","running":false,"session_dir":"/home/alexfneves/.config/herdr","socket_path":".../herdr.sock"},
  {"default":false,"name":"2026-08-11-23-37-41-812","running":true,"session_dir":".../sessions/2026-08-11-23-37-41-812","socket_path":".../herdr.sock"},
  ...]}
```
**Fields available:** `default`, `name`, `running`, `session_dir`, `socket_path`.
**Fields NOT available: timestamp, hostname/device, cwd.** Those must be synthesized by the wrapper (§e, §f).

### b.2 Create + attach, remote, through `ssh -t` (pty 40x120)

```
$ script -q -e -c "timeout -k 3 15 ssh -t localhost 'herdr --session hs-scout-probe-1'" /dev/null
  -> entered alt screen, painted full herdr UI (sidebar "spaces", tab "1", status line
     "alexfneves in 🌌 gmktec in ~ ..."), then killed by timeout
  exit=124  wall=15.02s
$ herdr session list --json
  [..., {"name":"hs-scout-probe-1","running":true}]      # SESSION SURVIVED THE KILL
```
Remote server log for that session:
```
18:42:38.014 api server listening path=.../sessions/hs-scout-probe-1/herdr.sock
18:42:38.041 spawning pane terminal ... rows=40 cols=120      <-- local winsize propagated
18:42:38.237 client connected client_id=2 cols=120 rows=40 render_encoding=SemanticFrame
18:42:52.881 client detached client_id=2                      <-- SIGTERM to client == detach
```

### b.3 Attach to existing remote session, **clean detach via `prefix+q`**

```
$ { sleep 6; printf '\002'; sleep 1; printf 'q'; sleep 6; } | \
    script -q -e -c "env -i PATH=... TERM=xterm-256color HOME=$HOME herdr --remote localhost --session hs-scout-probe-1" /dev/null

  stdout tail: "herdr: detached from remote server"
               "Run `herdr --remote localhost --session hs-scout-probe-1` to reattach"
  exit = 0        wall = 13.0s (12s of it was our own sleep)
$ herdr session list --json -> hs-scout-probe-1 running = TRUE
server log: "client detach requested via keybind client_id=10" / "client disconnected"
```

> ⚠ **This contradicts `docs/requirements.md`.** The requirement text says *"CTRL+B q in herdr to exit while
> destroying the session"*. Observed: **`prefix+q` DETACHES; the server and its panes keep running.**
> Default config confirms: `# detach = "prefix+q"` under `[keys]`. If the product wants the session gone after
> the user leaves it, **herdr-session must explicitly run `herdr session stop` + `herdr session delete`**
> after the child exits (this is exactly what the current `herdr-cycle.sh` does via `cleanup_session()`).

### b.4 Fresh "new remote session" end-to-end (create → attach → clean detach)

```
$ script ... env -i ... herdr --remote localhost --session hs-scout-probe-3   (prefix+q at t+7s)
  exit = 0
  server born 19:00:09.242Z ; client connected 19:00:09.450Z   (~210ms server-start→attach)
  afterwards: hs-scout-probe-3 running=true
```
So a "create new remote session" is one command, costs ≈ ssh handshake (150ms) + ≈60ms server spawn, and
the user's terminal is taken over by herdr's own client. **We do not need to hand-roll the remote wire protocol.**

### b.5 stop / delete formats

```
$ herdr session stop   hs-scout-probe-1            -> "stopped session hs-scout-probe-1"      exit 0
$ herdr session stop --json hs-scout-probe-3       -> {"session":{...},"stopped":true}        exit 0
$ herdr session stop   hs-scout-ghost-1 (already stopped / gone)
                                                   -> {"error":{"code":"session_stop_failed",
                                                      "message":"session X is not running or cannot
                                                       be reached at .../herdr.sock: ENOENT"}} exit 1
$ herdr session delete hs-scout-probe-1 (stopped)  -> "deleted session hs-scout-probe-1"      exit 0
$ herdr session delete --json X (stopped)          -> {"deleted":true,"session":{...}}        exit 0
$ herdr session delete hs-scout-probe-N (STILL RUNNING)
                                                   -> {"error":{"code":"session_delete_failed",
                                                      "message":"session X is running; stop it before deleting"}} exit 1
$ herdr session delete hs-scout-never-x9 (NEVER EXISTED)
                                                   -> "deleted session hs-scout-never-x9"     exit 0   ⚠ lies
```
**Success = plain text, failure = JSON, both on stdout.** A wrapper must branch on exit code, not on shape.

---

## (c) Failure modes (measured)

| # | Command | Exit | Wall clock | Output (trimmed) |
|---|---|---|---|---|
| F1 | `ssh -o ConnectTimeout=5 -t nonexistent.invalid 'true'` | **255** | 189 ms | `ssh: Could not resolve hostname nonexistent.invalid: Name or service not known` |
| F2 | `ssh -o ConnectTimeout=5 10.255.255.1 true` (packet-dropping black hole) | **255** | **5 014 ms** | `ssh: connect to host 10.255.255.1 port 22: Connection timed out` |
| F3 | `ssh 10.255.255.1 true` — **no `ConnectTimeout`** | **255** | **133 510 ms** | same message, after 2m13s of nothing |
| F4 | `ssh -o BatchMode=yes -o ConnectTimeout=5 nosuchuser@localhost 'true'` | **255** | 119 ms | `nosuchuser@localhost: Permission denied (publickey,password,keyboard-interactive).` (no prompt, fails fast) |
| F5 | `ssh localhost 'env -i /bin/sh -lc "command -v herdr \|\| echo NOT_FOUND"'` | 0 | 150 ms | `NOT_FOUND` — `PATH=/run/wrappers/bin:/.nix-profile/bin:...:/run/current-system/sw/bin` (HOME empty ⇒ `$HOME`-derived nix paths collapse to `/.nix-profile/bin`) |
| F6 | `ssh localhost 'command -v herdr'` (non-interactive, default sshd env) | 0 | 155 ms | `/home/alexfneves/.nix-profile/bin/herdr` — **found here**, `PATH=/home/alexfneves/.npm-global/bin:/run/wrappers/bin:/home/alexfneves/.nix-profile/bin:...` |
| F7 | `ssh localhost 'bash -lc "command -v herdr"'` | 0 | 150 ms | `/home/alexfneves/.nix-profile/bin/herdr` |
| N1 | `ssh localhost 'herdr session attach hs-scout-ghost-1'` (no tty) | **101** | 394 ms | `thread 'main' panicked at .../ratatui-0.30.0/src/init.rs:299: failed to initialize terminal: Os { code: 6, ... "No such device or address" }` — **AND the session was created and left RUNNING** |
| N2 | `ssh localhost 'herdr session delete <running session>; echo rc=$?'` | 0 outer / **1 inner** | 148 ms | `{"error":{"code":"session_delete_failed","message":"session ... is running; stop it before deleting"}}` |
| N3 | `ssh -T localhost 'herdr --session hs-scout-probe-2'` (remote create with **no pty**) | **101** | 372 ms | same ratatui panic — **and `hs-scout-probe-2` still ended up RUNNING** |
| A1 | `herdr --remote localhost --session hs-scout-probe-1 < /dev/null` (local has no tty) | **1** | 494 ms | ratatui panic, then `error: remote client exited with exit status: 101` |
| G0 | **nesting** — any `herdr` launch with `HERDR_ENV=1` in the environment | **1** | 22–260 ms | `error: nested herdr is disabled by default.` / `see configuration if you want to enable it.` (fails *before* ssh is spawned). Verified with `env -i ... HERDR_ENV=1 herdr --remote ...` ⇒ same error; with `HERDR_ENV` removed and `HERDR_SOCKET_PATH` kept ⇒ **works**. `HERDR_ENV` alone is the trigger. |

**Panic goes to stderr; stdout stays nearly clean** (only a couple of stray CSI sequences). Verified:
`ssh -T localhost 'herdr session attach X' 2>/dev/null` produced *no* JSON and no message; the panic appeared
only with `2>&1 >/dev/null`. Never merge stderr into stdout when parsing `--json`.

### The two traps that will actually bite

* **F3 — 133-second hang.** Any remote fetch without `ConnectTimeout` can freeze the UI for over two minutes. **Always** pass `-o ConnectTimeout=5` (and `-o BatchMode=yes` so it can never block on a password/OTP prompt — F4 proves that path fails in 119 ms).
* **N1/N3 — attach-to-nonexistent creates a live orphan.** `herdr session attach NAME` is *create-or-attach*. Even when the attach then **crashes on tty init**, the headless server for that name has already been spawned and shows `running:true`. A typo'd or stale name silently produces a zombie session the user never asked for. **Validate the name against the cached list before attaching.**

---

## (d) Latency measurements (round trips, 3 runs each)

| Path | min | median | max | exit |
|---|---|---|---|---|
| local `herdr session list --json` | **3 ms** | 3 ms | 3 ms | 0 |
| `ssh -T localhost 'herdr session list --json'` (no pty) | **144 ms** | **150 ms** | 150 ms | 0 |
| `ssh -t localhost 'herdr session list --json'` (pty) | 161 ms | 169 ms | 172 ms | 0 |
| `ssh -T localhost 'list --json + stat loop over all session dirs'` (single round trip) | — | 163 ms | — | 0 |
| server spawn → client attached, fresh remote session | — | ~210 ms | — | 0 |
| clean `prefix+q` detach (after attach) | — | ~30 ms | — | 0 |

**Budget conclusion:** on a LAN/loopback box a remote list is **~150 ms**, i.e. 50× a local list. The
requirement "show local immediately, fetch remotes in parallel" is therefore not just nice-to-have — it is
the difference between a 3 ms first paint and a ~150 ms × N-host serial stall. With `ConnectTimeout=5`
the worst case per host is bounded at **~5.0 s**; without it, **133 s**. Recommend: per-host timeout 5–8 s,
parallel fan-out, per-row "…" → "unreachable" inline state, and a cached last-good list.
Adding the `stat` side-channel for timestamps is free (same round trip: 163 vs 150 ms).

`-T` beats `-t` for fetching by ~20 ms and by not emitting `Connection to localhost closed.` — use `-T` for
reads and reserve `-tt` for the interactive attach.

---

## (e) Session identity & scoping — what the "device" column must contain

**Storage model (observed):** every session lives in the *invoking user's own* config dir on *its* host:

```
~/.config/herdr/sessions/<name>/{herdr.sock, herdr-client.sock, herdr-client.log, herdr-server.log, session.json}
```

1. **Names are scoped per (host, unix-user), not globally.** `herdr session list` output contains **no host field**. Two different hosts can each have `foo`, and they are two unrelated sessions. A local `foo` and a remote `foo` are indistinguishable in the JSON — only the *queried host* tells them apart.
2. **⇒ The wrapper's primary key must be the tuple `(device, name)`, never `name` alone.** Attach/stop/delete must carry the device too.
3. **`device` column must contain, verbatim:**
   * `local` for sessions obtained from the local `herdr session list --json` (with local `HERDR_*` scrubbed — see G0), and
   * for remotes, **the exact ssh target string the user configured/typed** (a `~/.ssh/config` `Host` alias, `user@host`, or plain hostname) — because that exact string is what we must hand back on attach: `herdr --remote <that-string> --session <name>`. Normalising/aliasing it (e.g. resolving to a canonical FQDN, or to `hostname`) would break the return path.
4. **Do not use the machine hostname as the device id.** Nothing observed ties a session back to a hostname; `hostname` on the remote is only cosmetic (it appears in herdr's status line, not in any machine-readable output). The ssh target string is the only handle we control.
5. `HERDR_CONFIG_PATH` did **not** relocate the session namespace in testing (pointed it at `/tmp/fakehost-herdr`, `session list` still reported `~/.config/herdr/sessions/...`). Do not use it as a multi-host namespacing trick.
6. **`default`** always appears with `default:true` and normally `running:false`. The product must decide whether to hide it (the existing `herdr-cycle.sh` hides it).
7. **Fixture caveat (from `00-user-constraints.md`):** here local and remote are literally the *same* install, so a bug that ignores the `device` field still passes every loopback test. A discriminating check needs either two real hosts or two unix-users/boxes. The plan should carry this as an explicit acceptance test that cannot be satisfied by the loopback fixture.

### Timestamps (a required column that `herdr` does not provide)

`herdr session list --json` returns **no timestamp**. Options actually verified on this box:

| Source | Works? | Notes |
|---|---|---|
| `stat -c %W <session_dir>` (birth time) | ✅ `birth=1792348958` | Best available "created at". Available over the same ssh round trip. Filesystem-dependent — `%W` may be 0 on some fs. |
| `stat -c %Y <session_dir>` (mtime) | ✅ but misleading | Changes as herdr creates/removes sockets → it is "last mutated", not created and not last-active. |
| Session-name convention `YYYY-MM-DD-HH-MM-SS-mmm` | ✅ for sessions created by `herdr-cycle.sh` | Not guaranteed for arbitrary user-typed names. Parse-then-fallback. |
| `herdr api snapshot` | ✗ | Rich live state (agents, panes, workspaces) but no session creation timestamp; also requires a socket to a *specific* session. |

Suggested: `name-regex → else stat -c %W → else "unknown"`, cached per `(host, name)` so it's captured the first time we see a session.

---

## (f) Implications for the wrapper process design

1. **Two ssh shapes, deliberately:**
   * **Fetch (non-interactive, parallel):** `ssh -T -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new <host> 'herdr session list --json'`. No tty, stdout is pure JSON, stdout-only parsing, bounded at ~5 s.
   * **Attach/create (interactive, exclusive tty):** `ssh -tt -o BatchMode=yes -o ConnectTimeout=10 <host> 'herdr --session <name>'` — or simply `herdr --remote <host> --session <name>` and let herdr own the ssh/multiplexing/keepalive. Use `-tt`, not `-t`, so a redirected stdin can never silently downgrade us to a no-pty run (§a.4).
2. **Prefer `herdr --remote <host> --session <name>` over hand-rolled `ssh -t host 'herdr session attach name'`.** Evidence: it does the whole create-or-attach + terminal takeover in one command, exits 0 on a clean `prefix+q`, survives the connection drop with a helpful re-attach message, and herdr manages its own ssh config (`[remote] manage_ssh_config = true`: generates a config that *includes `~/.ssh/config` first*, adds `ServerAliveInterval`/`ServerAliveCountMax`, and uses a private per-attach OpenSSH control socket). Caveat of the same feature: **`herdr` gives no way to pass a custom `-F <sshconfig>`**, so the `device` string must be resolvable by the *default* `~/.ssh/config` path or be a plain `user@host`.
3. **Env scrubbing is mandatory.** `HERDR_ENV=1` in the child environment makes *every* herdr invocation fail fast with "nested herdr is disabled by default" (§c G0). Since the wrapper will very plausibly be launched from inside a herdr pane (that's where `herdr-cycle.sh` runs today), the launcher **must remove `HERDR_ENV` (and, defensively, `HERDR_BIN_PATH`, `HERDR_SOCKET_PATH`, `HERDR_SESSION`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`) from every child's env** — or set `experimental.allow_nested = true` in herdr config. The scrub is the more portable fix; the config flag requires touching the user's herdr config.
4. **Never blind-attach.** Validate the target name exists in the currently-loaded list before invoking attach; otherwise a stale row or typo creates a phantom running session that even a crashing client leaves behind (§c N1/N3).
5. **Detach ≠ destroy.** If the product keeps the "leave the terminal after using a disposable session" behaviour of `herdr-cycle.sh`, the wrapper must run `stop` → `delete` itself after the child returns. `prefix+q` will not do it.
6. **Terminal handoff must be explicit and reversible.** The child writes `?1049h` (alt screen), mouse-tracking (`?1000/2/3`, `?1006`), bracketed paste (`?2004`), focus reporting (`?1004`), keyboard-protocol queries (`>7u`) and hides the cursor. On child exit the wrapper must: read the child's exit status, then **re-enter its own alt screen, re-assert raw mode, re-show/hide cursor as needed, and force a full repaint** — do not assume the inherited screen state. In the observed SIGTERM case the alt screen *was* left (`?1049l`) but the wrapper cannot rely on that for all paths (panic path leaves fewer resets).
7. **Process model:** run the attach child in its own process group / session with a controlling tty handed to it, and **block our own input while the child owns the tty** (do not let our key handler race the child). Resume our event loop on child-exit only.
8. **Exit-code contract to handle:** `0` ok · `1` herdr config/nesting/`delete`-on-running (message on stdout) · `101` terminal-init panic (needs tty) · `124` our own timeout · `255` ssh transport/auth failure · `127` command-not-found (§c F5 style). Map each to a distinct `{Error}` pane string per the state machine.
9. **Error text extraction:** on failure herdr emits a one-line JSON `{"error":{"code":..,"message":..}}` on **stdout**; on the panic path Rust writes to **stderr**. Capture both separately and prefer the JSON code for branching.
10. **First-paint / parallel fetch plan:** paint local immediately (3 ms), fan out remote fetches concurrently (150 ms each on LAN), merge rows as they arrive, sort `local` first then by timestamp. Mark each host `pending → ok/error(timeout|unreachable|no-herdr)`. A host-level error must degrade the row group, never the app.
11. **`herdr` may not exist on the remote** and may not be on the *non-interactive* PATH. F6 shows this particular box happens to work; F5 shows how an `env -i` invocation silently loses the nix profile. Treat `command -v herdr` failure as a first-class, distinct error state (`code 127` / `sh: herdr: command not found`) rather than a generic "ssh failed".
12. **Color fidelity (inferred, low confidence):** the first attach (inherited env, with `COLORTERM=truecolor`) negotiated `render_encoding=SemanticFrame`; the `env -i … TERM=… only` attaches negotiated `render_encoding=TerminalAnsi` at the same 120×40. If we scrub the env we should keep passing `TERM` and `COLORTERM` through.
13. **Config:** the wrapper's own theme/state lives in `~/.config/herdr_session.toml` (per requirements) and must never be conflated with `~/.config/herdr/config.toml` (which on this box is a symlink into home-manager).
14. **Fixture isolation:** `localhost` must arrive via `HERDR_SESSION_TEST_REMOTE` / a labelled test file, never a literal (§ user constraints). All the commands above take `<host>` as a parameter, so nothing here forces a literal into the product.

---

## (g) Cleanup proof

All probe sessions stopped and deleted:

```
hs-scout-probe-1   : stop(exit=0) 'stopped session hs-scout-probe-1'   | delete(exit=0) 'deleted session hs-scout-probe-1'
hs-scout-probe-2   : stop(exit=0) 'stopped session hs-scout-probe-2'   | delete(exit=0) 'deleted session hs-scout-probe-2'
hs-scout-probe-3   : stop(exit=0) 'stopped session hs-scout-probe-3'   | delete(exit=0) 'deleted session hs-scout-probe-3'
hs-scout-panicchk  : stop(exit=0)                                      | delete(exit=0) 'deleted session hs-scout-panicchk'
hs-scout-ghost-1/2/3, hs-scout-never-x9 : already removed earlier      | delete(exit=0)
```

Final state — **no `hs-scout-*` leftovers**; only the three pre-existing entries:

```
$ herdr session list
name                    status   directory                                             socket
default                 stopped  /home/alexfneves/.config/herdr                        /home/alexfneves/.config/herdr/herdr.sock
2026-08-11-23-37-41-812 running  /home/alexfneves/.config/herdr/sessions/2026-08-11-23-37-41-812 .../herdr.sock
2026-08-30-14-59-10-730 running  /home/alexfneves/.config/herdr/sessions/2026-08-30-14-59-10-730 .../herdr.sock

$ herdr session list --json
[('default', False), ('2026-08-11-23-37-41-812', True), ('2026-08-30-14-59-10-730', True)]

$ ls ~/.config/herdr/sessions/
2026-08-11-23-37-41-812
2026-08-30-14-59-10-730

$ ps -ef | grep -E 'herdr --(session|remote)|hs-scout' | grep -v grep
(no output)
```

Also verified untouched: `~/.ssh/known_hosts` (size 1751, mtime 2026-10-18 20:31:51 — unchanged from before the tests,
zero entries added for `10.255.255.1`); `~/.config/herdr/config.toml` (still the home-manager symlink, unmodified);
no `~/.ssh/config` was created. `/tmp/fakehost-herdr` (throwaway) was removed. The two remaining running sessions are
the user's own (`2026-08-11-23-37-41-812` is the live session this scout is running inside; `2026-08-30-14-59-10-730`
was already running at 20:09, before this task started).

**Nothing could not be cleaned.**

---

## (h) Unknowns — require manual interactive verification

1. **Real alacritty handoff.** Whether our Clay TUI's alt-screen + raw mode restores pixel-perfectly after a child
   herdr client exits (all evidence here is from a `script` pty with no terminal emulator, no scrollback and no
   compositor). Specifically: leftover cursor shape (`[0 q` seen in output), scrollback pollution, and whether the
   wrapper's first repaint after child-exit covers the whole screen.
2. **Window resize (`SIGWINCH`) during a remote attach**, and resize-after-detach. Untested.
3. **True network remote (different physical host).** Every measurement is loopback. Real WAN latency, keepalive
   behaviour (`ServerAliveInterval` from herdr's generated ssh config), and reconnect semantics after a network drop
   are unverified. The `"lost connection to remote Herdr: server closed connection"` message was only ever produced
   by us SIGTERM-ing the local side.
4. **`--remote-keybindings local|server`** — two modes exist in `--help`; neither tested. Matters because our
   wrapper's prefix handling and the remote herdr's prefix handling can collide.
5. **`--handoff`** (documented for "update or remote attach") — not tested at all. Likely relevant to handing the
   terminal from one herdr to another, but no evidence gathered.
6. **`experimental.allow_nested = true`** — not tested. Would change finding G0 (currently: hard block on any nested
   launch). Needs one real interactive run before the plan can rely on or reject it.
7. **Concurrent attaches** to the same session from two terminals (local + remote) — is it supported, mirrored, or
   conflicting? Untested.
8. **The real "destroy the session" keybinding.** We only proved `prefix+q` = detach. Whether herdr has a
   quit-and-destroy action (as `docs/requirements.md` assumes) was not found in `[keys]` and must be confirmed by a
   human in the UI before the wrapper decides whether to auto `stop`+`delete` on child exit.
9. **Password/OTP and host-key-prompt UX** — only the BatchMode fast-fail path was tested (F4). What the user sees if
   the wrapper intentionally lets ssh prompt is untested (deliberately avoided: `BatchMode=yes` is the recommended
   non-blocking setting and `known_hosts` for `localhost` was already present).
10. **Whether the wrapper can safely multiplex** herdr's per-attach control socket across several concurrent
    list/attach calls to the same host (ControlMaster contention). Not exercised.
