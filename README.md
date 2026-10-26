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
                             Mode selection

──────────────────────────────────────────────────────────────────────────
device       timestamp               state    name
local        2026-10-20 08:42:00.459 running  api
build-box    2026-10-19 21:14:07.221 running  worker
deploy       2026-10-18 09:03:55.104 stopped  bench
──────────────────────────────────────────────────────────────────────────
local ok 1  build-box ok 1  deploy timeout 0  …  esc quit
```

Rendered from the real column widths (`device` 12, `timestamp` 23, `state` 8,
one-column gaps, `name` takes the rest) at 74 columns, so the alignment above is
what the app actually draws — including the blank row between the header and the
table's top rule, and the blank rows under a short list. There is **no filter
line** in this, the landing screen, and no state in the footer.

The header carries the program title and, on the line below it, the state you are
in — `Mode selection`, `Attach session`, `Delete session`. The footer is for
what the machine *sees*: the per-host verdict and where the host list came from,
followed by the keys that work right now. {Mode selection} shows no filter line;
the states that actually filter (Attach, Delete, the remote picker, the theme
picker) do.

`default` never appears in the list. It is herdr's own persistent workspace, not a
session you created, and D12 forbids the app from touching it — the filter is applied
at the parse boundary (`parse_session_list`), so it cannot reappear through any code
path that reads a session list. The sample above therefore shows only real sessions.

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

The app has seven states. Every state can be left with `Esc`, every state quits
with `Ctrl-C`, and **`Ctrl-L` re-reads the session list from every state** (see
[How fresh is the list?](#how-fresh-is-the-list)).

**Typing only edits the filter in four states** — `r` (pick a remote host), `a`
(attach), `d` (delete) and `t` (theme). The landing screen binds exactly the keys
in its own table below; an unclaimed letter there does nothing, so you can never
accidentally type into a filter you are not aiming at. See [Where you can type](#where-you-can-type).

### 1. Mode selection (the landing screen)

| Key | Action |
|-----|--------|
| `Enter` | **new** local session (auto-generated name) |
| `n` | new **named** local session |
| `r` | new remote session (auto-generated name) |
| `s` | new **named** remote session |
| `a` | open the **attach** picker |
| `d` | open the **delete** picker |
| `t` | switch theme |
| `Esc` | quit |

That list is **complete**: `Enter n r s a d t Esc Ctrl-C`. There are **no
`Up`/`Down` bindings here and nothing is highlighted** — this state has no cursor,
because its `Enter` creates a session rather than acting on a listed row (see
[The highlighted row *is* the row `Enter` acts on`](#the-highlighted-row-is-the-row-enter-acts-on)).
Typing does **not** filter here either, and there is nothing to type *into*:
{Mode selection} draws **no filter line at all** (RCH-9). The row it used to
occupy is given back to the table, which is why the landing screen shows one more
session row than the filter states do. A filter you cannot edit is decoration
that costs a row, so it is gone rather than drawn empty.

### 2. Attach (`a`)

| Key | Action |
|-----|--------|
| `↑ / ↓` | select |
| type | filter |
| `Enter` | attach (existing sessions only) |
| `Esc` | back |
| `Ctrl-L` | re-read the list before you choose |
| `Ctrl-C` | quit |

Entering this state re-reads the list first: a row you point at must be as current
as we can make it, because attaching to a name that no longer exists would
**create** one.

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

### Where you can type

Typing edits the filter in **exactly four states**:

| State | Reached with | The filter narrows |
|-------|--------------|--------------------|
| Pick a remote host | `r`, `s` | the configured remote hosts |
| Attach | `a` | the session list |
| Delete | `d` | the session list |
| Theme | `t` | the theme names |

Everywhere else — the landing screen above all — the typed character is not bound
to the filter and does nothing. The binding list for Mode selection is
`Enter n r s a d t Esc Ctrl-C`, full stop. And on the landing screen there is
nothing to type into in the first place: {Mode selection} **does not draw a
filter line** (RCH-9). Only the four states above draw one, because only those
four accept typing. The layout therefore does differ between the landing screen
and the filter states — by exactly the height of the line that is drawn only
where it can be used — and `session_body` derives the table's height from the
same `app.state_is_filter_view` predicate that decides whether to paint the line,
so the table never reserves a row for a line that was never drawn.

**`Del` and `Backspace` both remove the last character.** `Delete` (and
`fn+Delete` on a Mac keyboard) is mapped to the same remove-last-rune action as
`Backspace`, because this app always edits at the end of the line — there is no
caret in the middle for the two keys to disagree about. Deletion is rune-wise, not
byte-wise: a multi-byte character (an accented letter, a CJK rune, an emoji) goes
as one whole unit, never as a dangling continuation byte.

Keys this app deliberately does **not** bind, rather than dropping silently:
`Insert` (there is no overwrite mode), `Home` / `End` (there is no caret-in-the-middle
to move) and `PgUp` / `PgDn` (the list scrolls with the arrows; there is no paging
model). They are no-ops by decision, and the decision is recorded in
`src/input/keymap.odin`.

### The highlighted row *is* the row `Enter` acts on

The highlight is a **promise**: it tells you exactly what `Enter` will act on.
So a row is highlighted only in the states where `Enter` actually acts on a row.

| State | Highlight on entry |
|-------|--------------------|
| Landing screen (Mode selection) | **none** — nothing is pointed at |
| Attach (`a`) | the first visible row |
| Delete (`d`) | the first visible row |
| Pick a remote host (`r`, `s`) | the first host |
| Theme (`t`) | the theme **currently applied** |
| Any list, after a filter removes your row | the first row the filter leaves visible |
| An **empty** list | none — `Enter` does nothing |

Why the landing screen is deliberately left unhighlighted, even though it shows a
full list: its `Enter` means **"New session"**. It does not target a listed row.
Highlighting a row there would point at one thing and then do something else with
it — the exact misleading UI this rule exists to prevent. The binding list agrees:
Mode selection has **no `Up`/`Down`** keys at all, because there is no cursor in
that state.

In the picker states the rule is strict in both directions. When filtering shifts
rows around, the selection is **re-derived from the highlighted row** rather than
left pointing at a row that is no longer on screen — so a session can never be
attached or deleted "from under" the cursor, and the cursor can never sit on
nothing. Leaving a picker clears the selection along with the filter, so the
landing screen never carries a stale pointer from two screens ago.

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
  "cleanup_policy": "only_created"
}
```

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `theme` | string | `"gruvbox-dark"` | Colour theme. See [Themes](#themes). |
| `remotes` | array | `[]` | SSH targets. See [Adding a remote](#adding-a-remote). |
| `cleanup_policy` | string | `"only_created"` | What happens to a session after you detach. See [Cleanup policy](#cleanup-policy). |

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

**One target is refused: anything that starts with `-`.** That is not a host, it
is an ssh *option* wearing a host's clothes — `-F/tmp/evil` makes ssh read a
config file of someone else's choosing, which replaces the mandatory
`BatchMode=yes` / `ConnectTimeout=5` that every remote guarantee in this app
rests on, and `-oProxyCommand=…` runs a command of the transport's own. Such a
target is refused at config-parse time with a footer warning that names it, and
refused again by the same rule on the registry path. `user@host` is fine; `-` at
the front is not.

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
vanishes. The footer reports where the list came from: `from registry + configured
remotes`, `from herdr machine registry`, or `from configured remotes` — which is
how you can tell "your registry is empty" apart from "your herdr is too old to
have one" without running anything. The label is `app.machine_source_label`, and
`main.odin` renders it whenever there is at least one remote.

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

### The palette is a schema mirror, not a hand-picked set

Every shipped theme is a **verbatim mirror of the alacritty `colors.*` schema** —
22 values, nothing added, nothing derived:

| Group | Values |
|---|---|
| `primary` | `foreground`, `background` |
| `cursor` | `cursor`, `text` |
| `selection` | `text`, `background` |
| `normal` | `black red green yellow blue magenta cyan white` |
| `bright` | `black red green yellow blue magenta cyan white` |

Each theme in `src/app/theme.odin` carries exactly those 22 values, copied from
the upstream file vendored under `.pi/plans/theme-sources/`, and
`tests/unit/theme_vendored_schema_test.odin` checks the compiled values against
the vendored file key-for-key, with the file pinned by byte length and sha256.
**Hex values are never adjusted for contrast.** If a value differs from upstream,
the test goes red.

### Roles

Nothing is painted from a raw hex. A view asks for a **role** and the role
resolves to a schema value (`src/app/theme.odin`, `theme_role_source`):

| Role | Schema value | Used for |
|---|---|---|
| `background` | `primary.background` | page fill |
| `text` | `primary.foreground` | body text |
| `secondary` | `bright.black` | headers, placeholders, dim |
| `hl_bg` | `selection.background` | selection bar fill |
| `hl_text` | `selection.text` | selection bar text |
| `border` | `bright.white` | between-children rule |
| `footer_key` | `primary.foreground` | footer key glyphs |
| `footer_desc` | `bright.black` | footer descriptions |
| `running` | `normal.green` | the state word, in both states |
| `stopped` | `normal.red` | the state word, in both states |
| `error` | `bright.red` | error frames and messages |
| `caret_bg` | `cursor.cursor` | caret cell fill |
| `caret_glyph` | `cursor.text` | caret glyph |

22 schema values, 13 roles: several values serve more than one role and some
schema values are carried without a role. The selected row keeps
`normal.green` / `normal.red` painted **on top of** `selection.background` —
the theme supplies the distinctness of running from stopped, the product does
not manufacture it.

Add a theme by adding one entry to the theme table in `src/app/theme.odin`
copied from its upstream schema file, and vendoring that file under
`.pi/plans/theme-sources/` with its sha256 recorded in
`tests/unit/theme_vendored_schema_test.odin`.

---

## Cleanup policy

> ### `cleanup_policy = "only_created"` — the session you *created here* is destroyed when you detach
>
> This is the **shipped default**. It restores the destroy-on-detach behaviour of
> the `herdr-cycle` script this replaces, but only for the half of it that was
> safe: a session this app generated a name for and asked `herdr` to start is
> stopped and deleted when the handoff returns. A session you merely **attached**
> to is left exactly as you found it — that session was yours before this app ever
> listed it, and `only_created` never touches it.
>
> **What this means in practice:** `n` → name → `Enter` → work → `prefix+q` takes
> you back to the main state *and* the session is gone from the list. Attach with
> `a`, leave, and it is still there.
>
> If the session was already deleted elsewhere, the return is silent — no error.
>
> Choose `"never"` to keep everything running and make deletion strictly an
> explicit `d` → `Enter`, or `"always"` for the old destroy-after-every-detach
> behaviour — but read [Cleanup follows the device](#cleanup-follows-the-device)
> first, because that is the part of the old behaviour that used to be wrong.

Three accepted values:

| Value | Behaviour on detach |
|-------|--------------------|
| `"never"` | leave the session running. Deletion is always an explicit user action. |
| `"only_created"` | **(default)** stop + delete sessions *this app created*; leave sessions you created elsewhere — and any session you only attached to — alone. |
| `"always"` | stop + delete after every detach — the old `herdr-cycle` behaviour. |

Two invariants that outrank every policy:

- **`default` is never destroyed** by any policy, under any circumstance.
- An unrecognised value (e.g. `"on"`) falls back to `"never"` — *not* to the
  `only_created` default — and puts a warning in the footer, so a typo in the file
  can never silently move you into a *more* destructive mode than the one you were
  trying to write. Only an **absent** key gets the `only_created` default.

The policy check lives in exactly one function
(`cleanup_should_run` in `src/app/herdr.odin`) and the detach path calls it every
time, so when D2 is eventually decided the change is one constant rather than a
hunt through the code.

### Cleanup follows the device

A session's identity is the **pair** `(device, name)`, not the name. The same
name can exist on this machine and on three remotes at once, and they are four
different sessions.

So `always` / `only_created` clean up **the device the row came from**:

| Row's device | What the cleanup runs |
|---|---|
| local | `herdr session stop --json <name>` / `… delete --json <name>` |
| remote | `ssh -T -o BatchMode=yes -o ConnectTimeout=5 <device> '<the same command>'` |

**This is a fix, and it is worth knowing about.** Up to and including the
reviewed build, `cleanup_policy = "always"` ran the *bare local* command no
matter which device you had detached from — so detaching from
`gpu-box:mywork` stopped and deleted **your local `mywork`** instead, and
reported success. If you ran with `always` on a config that had remotes, check
for sessions you did not mean to lose.

Two honesty rules go with it:

- A cleanup that **did not land** says so: `… <name> on <device> NOT cleaned
  (<reason>)`. An unreachable host is never reported as "stopped and deleted".
- Each cleanup command is capped at `CONTROL_TIMEOUT` (6 s), derived from the
  `ConnectTimeout=5` the ssh form carries, so a dead host answers on its own
  schedule rather than holding the app for twice as long as advertised.

### How fresh is the list?

The table is a **snapshot**, and a snapshot goes stale the moment someone else
creates or deletes a session. Three things keep that visible instead of hidden:

- **Entering Attach or Delete re-reads the list.** Those are the two states where
  a stale row costs something, and entering them is the last moment a refresh is
  free (~3 ms locally; remote rows keep the freshest fetch that landed rather
  than blocking on an ssh round-trip).
- **`Ctrl-L` refreshes from any state**, and says so: `list re-read — list now`.
  The age token lives in that notice, not in a permanent status cell: you see
  how old the rows were at the moment you asked, and nothing else.
- **The footer shows what each host is doing** — `local ok 2  build-box down 1`.
  The list itself is a snapshot, so the loop never wakes on a timer — the one
  scheduled wake it ever takes is the caret blink (ISC-A-2: the blink re-arms from
  the Edit's own monotonic deadline and the loop just re-arms its poll to the next
  edge; with no caret visible it blocks indefinitely on `poll(-1)`) — and no number
  quietly goes stale: the freshness you can act on is the one `Ctrl-L` prints and
  the one every Attach/Delete entry re-earns by re-reading before it lets you act.

One deliberate non-rule: a session herdr reports as **stopped** is still
attachable. `herdr session attach` *resumes* a stopped session, and forbidding
it would disable the main thing this tool is for. "Stopped and deleted
meanwhile" is answered by refreshing (above) and by re-checking the exact row
immediately before the spawn, not by refusing the target. If the name is
genuinely gone, the attach is still refused.

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
directory).

The suites that CREATE sessions also prove the list is restored byte-for-byte, by
capturing `herdr session list` before and after the run and failing on any drift:
`app-smoke` and `tui-smoke` both print their pre-run and post-run lists on the
same screen. `state`, `render`, `theme` and `ui` are pure-model / pure-render suites
that spawn no session, so they have nothing to restore and assert that instead
rather than claiming a cleanup they did not perform.

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

**Apache-2.0**, matching `license = lib.licenses.asl20` in `nix/package.nix`
(this previously said MIT while the package metadata said ASL 2.0, and the two
disagreed).

Vendored/build-time dependencies, both pinned by revision in `flake.nix`:

- [Clay](https://github.com/nicbarker/clay) (MIT) — layout, used via its C ABI
- [termbox2](https://github.com/termbox/termbox2) (zlib) — terminal rendering

Check each upstream's licence before relicensing or redistributing a combined
artifact; this project's licence governs this repository's own source only.
