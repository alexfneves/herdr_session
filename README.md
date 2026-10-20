# herdr-session

A keyboard-driven terminal UI for [herdr](https://github.com/owenthereal/herdr) sessions.
It replaces the `herdr-cycle` shell script: one screen listing every session on this
machine and on each configured remote, with attach, create, delete and theme
switching driven entirely by the keyboard.

Written in **Odin**, laid out with **Clay**, rendered through **termbox2**. No
threads, no web frontend, no TOML. A single static binary that talks to the `herdr`
CLI you already have.

```
                                 herdr-session
──────────────────────────────────────────────────────────────────────────
filter: ▏
device      timestamp               state    name
local       2026-10-20 08:42:00.459 running  default
build-box   2026-10-19 21:14:07.221 running  api
deploy     2026-10-18 09:03:55.104 stopped  worker
──────────────────────────────────────────────────────────────────────────
mode_selection  ·  local ok 1  build-box ok 1  deploy timeout 0
```

There is deliberately **no outer border** — the header and footer dividers are
Clay `betweenChildren` rules, so the screen uses every column it was given. The
two rules you see are the header/footer separators, not a box.

---

## Build and run

```sh
nix build .     # result/bin/herdr-session
nix run .       # runs the TUI directly
```

**A real TTY is required.** The TUI renders through termbox2 and refuses to run
when stdin and stdout are not both a terminal — piping it into a file or a pipe
exits with code `3` and the message
`herdr-session: needs a real terminal: stdin and stdout must both be a tty.`
instead of emitting a screenful of escape codes.

The Nix build is fully pinned and builds `termbox2` from source; it downloads no
prebuilt binaries, and links only glibc (`libc`/`libm`).

---

## Key bindings

The app has seven states. Every state can be left with `Esc`, and every state quits
with `Ctrl-C`.

### 1. Mode selection (the landing screen)

| Key | Action |
|-----|--------|
| `Enter` | new local session (auto-generated name) |
| `n` | new **named** local session |
| `r` | new remote session (auto-generated name) |
| `s` | new **named** remote session |
| `a` | **attach** to the selected session |
| `d` | **delete** the selected session |
| `t` | switch theme |
| `Esc` | quit |

Arrow keys move the selection; typing narrows the list in the states that have a
filter line.

### 2. Attach (`a`)

| Key | Action |
|-----|--------|
| `↑ / ↓` | select |
| type | filter |
| `Enter` | attach (existing sessions only) |
| `Esc` | back |
| `Ctrl-C` | quit |

`Enter` attaches only to a session that exists. It will not create one — creation
is the `Enter`/`n`/`r`/`s` keys on the landing screen, so a stray `Enter` in this
list can never make a session.

### 3. Delete (`d`)

| Key | Action |
|-----|--------|
| `↑ / ↓` | select |
| type | filter |
| `Enter` | stop + delete |
| `Esc` | back |
| `Ctrl-C` | quit |

### 4 / 5. Name a local or remote session (`n`, `s`)

| Key | Action |
|-----|--------|
| type | `A-Z a-z 0-9 . _ -` |
| `Enter` | create |
| `Esc` | back |
| `Ctrl-C` | quit |

Anything outside that character set is rejected with a message rather than being
silently stripped — herdr's own name grammar is narrower than most shells'.

### 6. Pick a remote (`r`, `s`)

| Key | Action |
|-----|--------|
| `↑ / ↓` | select |
| type | filter |
| `Enter` | choose |
| `Esc` | back |
| `Ctrl-C` | quit |

### 7. Theme (`t`)

| Key | Action |
|-----|--------|
| `↑ / ↓` | select |
| type | filter |
| `Enter` | apply theme (and save it to the config) |
| `Esc` | back |
| `Ctrl-C` | quit |

### Error state

| Key | Action |
|-----|--------|
| `Enter` / `Esc` | dismiss |
| `Ctrl-C` | quit |

**Terminal too small.** Below 40 columns or 10 rows the list is replaced by a
single line saying so (with the size you have and the size you need). Enlarge the
window and the normal UI comes back on the next frame — nothing to reset.

---

## Configuration

`~/.config/herdr_session.json` (or `$XDG_CONFIG_HOME/herdr_session.json` if that
variable is set). The file is optional — with no file at all the app runs on
defaults.

Three keys are ours. **Everything else in the file is preserved untouched on save**,
so you can keep your own keys next to ours.

```json
{
  "theme": "gruvbox-dark",
  "remotes": [
    "build-box",
    "deploy@10.0.0.7",
    { "target": "gpu-box", "label": "GPU box" }
  ],
  "cleanup_policy": "never"
}
```

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `theme` | string | `"gruvbox-dark"` | Colour theme. See [Themes](#themes). |
| `remotes` | array | `[]` | SSH targets. See [Adding a remote](#adding-a-remote). |
| `cleanup_policy` | string | `"never"` | What happens to a session after you detach. See [Cleanup policy](#cleanup-policy). |

### Bad config is shown, not thrown

The file is hand-editable at 2am, so a broken config never stops the app. Each
problem becomes defaults plus **one warning line in the footer**:

| Situation | Result |
|-----------|--------|
| File does not parse | defaults, warning `config <path> is not valid JSON (…) - defaults in use` |
| Unknown theme name | `gruvbox-dark`, warning names what was available |
| Key of the wrong type | that key ignored, warning names it |
| Unknown extra key | **silently ignored and preserved on save** (it's your key, not ours) |

The one thing that is *not* preserved: if the file cannot be parsed, the first save
writes a document containing only our three keys. The warning already told you the
file was invalid before that happened.

---

## Adding a remote

A remote is an **SSH target**, and the string you write is used **verbatim** — for
`ssh -T <target>`, for `herdr --remote <target>`, and as the identity key that
groups its sessions. Nothing is normalised: no lower-casing, no stripping the user,
no alias resolution. That is deliberate. Rewriting `deploy@10.0.0.7` into
`10.0.0.7` would attach you to a different machine than the one you configured.

Two forms, both accepted in the same array:

```json
"remotes": [
  "build-box",
  { "target": "gpu-box", "label": "GPU box" }
]
```

- A bare string is the SSH target; the display label is the target itself.
- An object takes `target` plus an optional `label` shown in the device column.

Use your `~/.ssh/config` host aliases as targets — they work, because the string is
passed to `ssh` unchanged.

### Merging with herdr 0.9's `machine` registry

herdr 0.9.x added a machine registry, readable with `herdr machine list --json`.
`herdr-session` reads it at startup **and adds your configured remotes to it**.
The result is the **union**, de-duplicated on the verbatim device string:

| Registry | `remotes` in config | What you see |
|----------|--------------------|--------------|
| empty (`[]`) | 3 hosts | your 3 hosts |
| 2 machines | empty | those 2 machines |
| 2 machines | 3 hosts | all of them (deduped) |
| not available (herdr 0.8.x) | 3 hosts | your 3 hosts |

The registry is never allowed to win by *replacing* your list. An empty registry is
a true answer about herdr's saved machines, not a statement about what you wanted,
and treating it as authority is exactly how a hand-written host list silently
vanishes. The footer reports where the list came from.

Two details worth knowing:

- **The gate is a JSON-shape check, not an exit-code check.** On herdr 0.8.2
  `machine list` doesn't exist and prints `unknown command: machine` on stdout.
  Both that and a genuinely broken registry answer non-zero, so availability is
  decided by whether the payload parses as a registry (`[...]` or
  `{"machines": [...]}`), not by the exit code.
- **Session listing is always our own `ssh`.** `herdr --remote X session list` is
  rejected by herdr itself (`--remote can only be used with the default launch
  command`), so the registry can tell us *which* hosts exist but never list them.

---

## Themes

The default is **`gruvbox-dark`** (`D4`). **`catppuccin-latte`** also ships and is
selectable.

Switch with `t` — pick from the list, `Enter` applies it and writes it to
`~/.config/herdr_session.json`. The name resolves leniently: `latte`,
`catppuccin` and `catppuccin-latte` all land on the same theme, and an unknown
name falls back to the default with a warning rather than failing.

Add a theme by adding one entry to the theme table in `src/app/theme.odin`; every
colour is a named field on a palette, not an inline hex.

---

## Cleanup policy

> ### ⚠️ `cleanup_policy = "never"` — sessions are NOT destroyed when you detach
>
> This is the **shipped default**, and it is a deliberate behavioural change from
> the `herdr-cycle` script this replaces.
>
> The old `herdr-cycle` **stopped and deleted** the session when you left it
> (destroy-on-detach). `herdr-session` **leaves it running**.
>
> Why: `herdr`'s own `prefix+q` only *detaches* — the server and its panes keep
> running. Silently destroying a session someone merely peeked at is data loss, and
> the exact detach semantics of the herdr build on your machine are not something
> this app wants to guess about. This is plan decision **D2**, and D2 is *parked*.
>
> **What this means in practice:** attach to a session, press `Ctrl-C` / leave, and
> that session is still there in the list when you come back. Deletion is only ever
> what you explicitly asked for with `d` → `Enter`.
>
> If you want the old behaviour back, set `"cleanup_policy": "always"`.

Three accepted values:

| Value | Behaviour on detach |
|-------|--------------------|
| `"never"` | **(default)** leave the session running. Deletion is always an explicit user action. |
| `"only_created"` | stop + delete sessions *this app created*; leave sessions you created elsewhere alone. |
| `"always"` | stop + delete after every detach — the old `herdr-cycle` behaviour. |

Two invariants that outrank every policy:

- **`default` is never destroyed** by any policy, under any circumstance.
- An unrecognised value (e.g. `"on"`) falls back to `"never"` and puts a warning
  in the footer, so you are never silently in a *more* destructive mode than you
  asked for.

The policy check lives in exactly one function
(`cleanup_should_run` in `src/app/herdr.odin`) and the detach path calls it every
time, so when D2 is eventually decided the change is one constant rather than a
hunt through the code.

---

## Replacing `herdr-cycle`

In `~/.config/home-manager/modules/editors/alacritty.nix`, the current setting
is:

```nix
terminal.shell = {
  program = "${config.home.homeDirectory}/.local/bin/herdr-cycle";
};
```

Point it at `herdr-session` instead:

```nix
terminal.shell = {
  program = "${config.home.homeDirectory}/.local/bin/herdr-session";
};
```

Then get the binary onto that path and rebuild. Two ways:

**a) Install the Nix package and symlink it** (keeps the path you already have):

```sh
nix profile install /path/to/herdr_session
ln -sf "$(readlink -f ~/.nix-profile/bin/herdr-session)" ~/.local/bin/herdr-session
```

**b) Copy the built result** (simpler, but nothing updates it automatically):

```sh
nix build /path/to/herdr_session
cp result/bin/herdr-session ~/.local/bin/herdr-session
chmod +x ~/.local/bin/herdr-session
```

Then:

```sh
home-manager switch
```

Notes:

- `herdr` itself must still be on `PATH` — this app shells out to it (`herdr
  session list --json`, `herdr attach`, `ssh`) and does not replace it.
- Read the **[Cleanup policy](#cleanup-policy)** section before switching: leaving
  a session no longer destroys it.
- To roll back, restore the `herdr-cycle` line and `home-manager switch` again.
  Nothing here mutates your session data.

---

## Development

### Layout

| Path | What's in it |
|------|--------------|
| `src/main.odin` | the TUI: poll loop, event handling, states |
| `src/app/` | the domain: state machine, config, herdr CLI, fetch, remotes, cleanup |
| `src/ui/` | the Clay frame, the session table, the notice screen |
| `src/render/` | Clay commands → termbox cells |
| `src/terminal/` | terminal handoff, resize policy |
| `src/input/` | key decoding |
| `nix/` | pinned build: package, termbox2, clay |
| `dev/` | the smoke suites (below) |

### Running the test suites

Every suite runs the real binary; the ones that need a terminal create a real pty.
None of them touch your real `~/.config` (they point `XDG_CONFIG_HOME` at a temp
directory) and each one proves the herdr session list is byte-identical after the
run.

```sh
dev/local-build.sh                     # -> /tmp/hs-local
export BIN=/tmp/hs-local

# Dev-only fixture: a reachable "remote" that is just this machine, so the
# remote code paths can be exercised without a second box. See dev/test-remote.md.
export HERDR_SESSION_TEST_REMOTE=localhost
export HERDR_SESSION_TEST_REMOTE_ALIAS=127.0.0.1
export HERDR_SESSION_TEST_UNREACHABLE=192.0.2.201   # TEST-NET-1, blackholes

./dev/state-smoke.sh    # the 7-state machine, offline + live
./dev/render-smoke.sh   # Clay -> cell rendering
./dev/ui-smoke.sh       # UI cases inside a real pty (frame, table, edit, shrink)
./dev/theme-smoke.sh    # config load/save, theme resolution, write-back rules
./dev/tui-smoke.sh      # the real TUI under a pty: boot, keys, attach, SIGTERM
./dev/resize-smoke.sh   # resize coalescing, "too small", recovery, EINTR
./dev/handoff-smoke.sh  # termbox handoff to a child and back
```

Each script prints `PASS`/`FAIL` per assertion and a total. They are independent —
run one, or run them all.

**The fixture environment variables are for development only.** The product binary
contains no loopback addresses: `localhost`/`127.0.0.1` appearing anywhere in
`src/` is a build-time failure condition, and the suites inject those hosts from
the outside precisely so that stays true.

### `dev/test-remote.md` is developer-only documentation

`dev/test-remote.md` explains how the loopback fixture is set up so remote code
paths can be tested against one machine. **It is a development note and can be
deleted.** `herdr-session` itself is generic: any SSH target works, and nothing in
the product depends on that file, its fixture, or a loopback address.

### Design constraints worth knowing before you change things

- **No threads.** One `poll()` over the tty fd, termbox's resize fd and the
  children's pipes. `core:thread` must not appear in `src/`.
- **The terminal is the source of truth about size.** The resize gate and the
  layout are re-evaluated from the current terminal size on every frame; there is
  no stored "too small mode" to get stuck in.
- **JSON only.** Config and `herdr --json` output are parsed with `core:encoding/json`.
  No TOML parser anywhere.
- **Verbatim SSH targets.** Never normalise a device string. See
  [Adding a remote](#adding-a-remote).
- **Selection is by identity, not by index.** Re-merging a refreshed table into
  the visible list re-clamps the selection, which is what keeps a resize or a
  refresh from jumping your cursor to a different session.

---

## License

MIT. Vendored dependencies: [Clay](https://github.com/nicbclay/clay-odin) and
[termbox2](https://github.com/termbox/termbox2), both built from pinned source.
