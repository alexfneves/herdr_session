# Decisions needed from the user (before the planner designs)

Raised by the herdr scout; these cannot be answered by reading code. Answer inline or just say
"you decide" per item and the planner will pick a default and record the rationale.

---

## D1. Where does the "known remotes" list come from?

Spec: `{Select remote server for new remote session}` shows "all known remotes".

**Constraint found:** this host has **no `~/.ssh/config`** (`~/.ssh` = `authorized_keys`,
`id_ed25519[.pub]`, `known_hosts*` only), so an ssh-config-only design shows an empty list today.
herdr 0.8.2 also has **no** remote registry (`herdr machine` is 0.9.x-only).

Options:
- **(a)** `~/.config/herdr_session.toml` `[[remote]]` entries only — explicit, in our control,
  and the config file already exists per spec.
- **(b)** Parse `~/.ssh/config` `Host` stanzas only — automatic, but empty today.
- **(c)** Both: toml is authoritative, plus auto-discovered `~/.ssh/config` hosts, merged/deduped.

> **USER ANSWER:**

---

## D2. Destroy-on-detach policy

**Constraint found:** a herdr session **survives** the client. Detaching with `prefix+q` hands the
terminal back but leaves the server running. `herdr-cycle` always runs `stop` + `delete` after
attach returns, so nothing leaks.

Options:
- **(a)** Always destroy after detach (exact `herdr-cycle` parity; simplest; matches the spec's
  "session ends → TUI reappears" reading).
- **(b)** Never destroy — detach just returns; sessions accumulate and are managed explicitly via
  the `[d]` Delete flow.
- **(c)** Destroy only sessions **we** created in this run; never destroy sessions we merely attached
  to, nor anything that already existed. *(Closest to least-surprising.)*

> **USER ANSWER:**

---

## D3. What fills the "timestamp" column?

**Constraint found:** no timestamp exists in `herdr session list --json` or `session.json`. Only
sources are filesystem **birth time** (`stat -c %w`), or **mtime of `session.json`** (last save —
actually arguably more useful: "last active"), or the name-embedded time for
`herdr-cycle`-style names (`YYYY-MM-DD-HH-MM-SS-mmm`).

Consequence: for **remote** rows this needs `ssh <host> stat ...` per session (extra round-trips,
or one batched remote command).

Options:
- **(a)** Creation time via birth time (`%w`) — most spec-literal, but `%w` can be `-` on some FS.
- **(b)** Last-active via `session.json` mtime — no birth-time dependency, arguably more useful.
- **(c)** Batch one remote shell command per host returning all stats at once (cheap + robust).
- **(d)** Show `—` for remote rows; local only.

Recommendation: **(b) + (c)** batched.

> **USER ANSWER:**

---

## D4. Default theme

Spec requires `catppuccin-latte` to exist but explicitly says it is **not** the default.
So: what ships as the built-in default when `~/.config/herdr_session.toml` is absent?

Suggested shortlist: `catppuccin-mocha` (dark sibling of your preference), `gruvbox-dark`,
`tokyonight-night`, `nord`, `rosé-pine`.

> **USER ANSWER:**

---

---

# Architecture decisions (from scout-odin-clay.md)

Clay gives **layout only** — no terminal rendering, raw mode, input, glyphs, or color mapping. Those are
ours. These are the forks that determine the whole codebase.

## D5. Renderer base — the biggest single decision

- **(a) Hand-rolled**: Odin + `posix.termios` + hand-declared `ioctl(TIOCGWINSZ)` + our own CSI parser +
  Clay→cell rasterizer + ANSI writer. Zero deps, matches the experiment's style, but we own ~everything
  the termbox2 renderer does in 73KB.
- **(b) termbox2 as a C dependency**: raw mode, parsed input event queue (correct UTF-8 + modifiers),
  resize events, 256-col cell buffer. Upstream `clay_renderer_termbox2.c` is a **direct port target**.
  Adds one C dep to the flake; 24-bit color needs `tb_set_truecolor(1)`.
- **(c) `RaphGL/TermCL`**: 108 stars but **explicitly unmaintained** (author left Odin). Would fight Clay
  for screen ownership. Not recommended.

**Scout-leaning recommendation: (b)** — it eliminates the exact bug classes that broke the experiment
(input parsing, wcwidth, resize) and there is a known-good C port target. Choose (a) only if a zero-C-dep
binary is a hard requirement.

> **USER ANSWER:**

## D6. Platform scope

Linux only, or Linux + Darwin? Affects the `TIOCGWINSZ` constant (Linux `0x5413` vs Darwin/BSD
`0x40087468`), which `.a` gets linked, termios details, and the flake's `systems` (currently
`nix-systems/default`, which **includes Darwin**). Note: the user's hosts are `gmktec` + `afn`.

> **USER ANSWER:**

## D7. UTF-8 / wide-character bar

Odin has **no `wcwidth`**. Minimum viable per scout: decode UTF-8, ASCII=1, combining marks/ZWJ/variation
selectors=0, East Asian Wide/Fullwidth + emoji ranges=2, and never index by byte during layout. A 2-cell
glyph must also claim the following cell or all column math desyncs.
Session names are **user-supplied**, so arbitrary UTF-8 is reachable via the filter and name fields.

- **(a)** Full-ish wcwidth table (copy `clay_renderer_termbox2.c:1206-1234` logic)
- **(b)** Minimal: correct rune decoding + wide=2 + combining=0, no grapheme clusters
- **(c)** ASCII-only validation on names/filters (reject the rest)

> **USER ANSWER:**

## D8. Ctrl+C / ISIG semantics

Spec says `[CTRL+C] Exit the program` from **every** state. Two ways:
- **(a)** Keep `ISIG` **on** → Ctrl+C is a real `SIGINT`; our handler must do full terminal restore.
  We never see byte `0x03`.
- **(b)** Turn `ISIG` **off** → `0x03` arrives as an ordinary input byte, handled uniformly by the state
  machine (cleanest for "same action in all 7 states"), but we must install our own restore-on-signal path
  so a real `SIGINT`/`SIGTERM` can't leave the terminal broken.

Recommendation: **(b)** for uniform state-machine handling + explicit restore.

> **USER ANSWER:**

## D9. Repaint strategy

Experiment paints the full screen every frame and **never reads its front buffer**. Spec also requires live
updates arriving asynchronously from remote fetches.
- **(a)** Real front/back diff (emit only changed runs, seek per row) + `poll()`-driven repaint on change
- **(b)** Full repaint, but `poll()`-driven only when something actually changed (no idle spin)

Recommendation: **(a)**; **(b)** is an acceptable simplification if it never idle-spins.

> **USER ANSWER:**

## D10. Escape-key ambiguity (affects a core interaction)

Spec uses `[Escape]` as "back" in every state. A lone `\e` is ambiguous: Escape key, **or** the first byte
of a CSI sequence. Options:
- **(a)** Legacy-only + short timeout (~50ms) to disambiguate a lone ESC — works everywhere, adds latency
  to Escape only.
- **(b)** Adopt Kitty keyboard protocol (`\e[>1u`) as the primary path — clean, but **Alacritty (legacy),
  xterm, Windows Terminal don't support it**, and the user's terminal *is* Alacritty.
- **(c)** Both: parse legacy always, use Kitty when advertised.

Given the user runs **Alacritty**: **(a)** or **(c)**. Do **not** make Kitty a hard dependency (the
experiment's CSI-u-only Ctrl+C detection is a known flaw).

> **USER ANSWER:**

---

## Recommended module decomposition (planner to confirm)

To avoid the experiment's 1046-LOC single-file monolith with fixed `[2]Window` globals:

```
terminal/   raw mode, alt screen, size/ioctl, ANSI writer, restore-on-exit
input/      key event model + incremental escape parser (buffered, partial-safe)
render/     Clay RenderCommand -> cell grid -> diff -> ANSI
ui/         Clay layout components (header, footer, sessions table, filter, edit, float)
app/        state machine (7 states), session model, config/themes
main.odin   loop wiring only
```

---

## Notes for the planner (non-negotiable, from scout-herdr.md)

- **Never** parse plain `herdr session list` — use `--json` everywhere.
- JSON errors arrive on **stderr** with exit 1 → must be parsed and surfaced in `{Error}` state;
  the `{Error}` body for remote failures is **raw text**, not JSON (`--remote` failures are not JSON).
- `delete` cannot detect a typo'd name (returns `deleted:true` for unknown sessions) — do our own
  existence check before reporting success.
- Never offer to delete/stop the `default` session (herdr refuses; `herdr-cycle` filters it out).
- Set the child's cwd explicitly (e.g. `$HOME`) — the created session inherits the spawner's cwd
  as `identity_cwd`.
- Pin behavior to herdr **0.8.2**; treat 0.9.x (`machine`/`--machine`) as additive, not required.
- Testing `herdr --remote localhost` from inside the same user account is inherently risky (can
  target the server hosting the current agent session). Mitigation: non-interactive stdin makes
  host-modifying paths fail instead of mutate. Planner should define a **safe** remote test strategy.
