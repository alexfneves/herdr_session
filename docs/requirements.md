You are an orchestrator, you should delegate tasks to herdr subagents.

This repository is a nix flake for the program herdr-session. The program is a TUI program to create, delete or attach to herdr sessions, both local or remote sessions.

If I nix run to this flake it should run the herdr-session program (it's the default output).

This has to be implemented in the Odin language (https://devenv.sh/languages/odin/) and use Clay (https://github.com/nicbarker/clay and the binding are in
https://github.com/nicbarker/clay/tree/main/bindings/odin), for calculating the layout of the TUI. Look in /home/alexfneves/gits/tui_experiment for inspiration of how the odin language could be used with clay to make a TUI (it's just an experiment with not enough content and possible a wrong structure).


## REQUIREMENT: Odin for everything

**Odin is the only implementation language for this project.** That covers product code, tests,
tooling, scripts, generators, probes, fixtures, build helpers and one-off analysis.

This repo is mid-migration: the legacy test suite is Python and shell under `dev/`, and porting it to
Odin is the current work. Writing new Python or shell moves the project backwards, and it happens
quietly -- an agent reaches for a scripting language to parse output or compute a value, gets an
answer fast, and leaves behind code that itself must later be migrated.

Therefore:

- Do not add new `.py` files, and do not add new shell scripts, to the repo or to any worktree.
- Do not use `python -c`, `awk`, `sed` or `jq` to reimplement what an existing Odin tool already
  does. `tests/tools/hscheck` already parses `HS_TALLY` output, reads the JSON test report, enforces
  every parity floor and emits a verdict. Use it instead of re-parsing in another language.
- Scratch analysis and throwaway measurement are not exempt.
- Need a value computed? Compute it in Odin, or derive it by reasoning and put the literal in the
  source with a comment explaining it. If a value needs a solver, the value or the design is wrong.

**If Python, or any non-Odin language, is genuinely required: stop and consult the user first.** Do
not proceed assuming a throwaway script is harmless. State what is needed, why Odin cannot do it, and
wait for a decision.

The existing `dev/*.py` and `dev/*.sh` are the source of the migration, not a precedent for adding
more. They are deleted at T17, once every assertion they carry has been ported.

The migration is not finished when the old files are gone. It is finished when nobody is writing new
non-Odin code here.

For reference, this is a program that I will use to replace the herdr-cycle in my
home-manager configuration (see /home/alexfneves/.config/home-manager).


The layout of the TUI is:

|-------------------------|
|         Header          |
|-------------------------|
|      Main content       |
|                         |
|                         |
|                         |
|                         |
|                         |
|                         |
|                         |
|-------------------------|
|         Footer          |
|-------------------------|


There is a border around the TUI application, and between each section there is also a border line.
The TUI covers all the available space on the terminal.
The header shows the title of the program.
The footer shows what is the current state, then all the keys that can be used.

> **Amended by RCH-9** (`.pi/plans/2026-10-18-herdr-session-tui/50-requirement-changes.md`).
> The two sentences above no longer describe the shipped screen, and the
> discrepancy is not incidental — it is the change.
>
> - The **header** shows the title of the program **and, on the line below it,
>   the current state** as a human phrase (`Mode selection`, `Name local
>   session`, `Select remote server`, `Name remote session`, `Attach session`,
>   `Delete session`, `Theme`, `Error`) rather than the internal snake_case
>   identifier. The header is two rows, not one.
> - The **footer** shows the keys that can be used, plus what the machine
>   observed: the per-host verdict (`local ok 2  build-box down 1`) and where
>   the host list came from (`from registry + config` / `from config`). It does
>   **not** show the state.
> - The age of the list is **not a permanent footer cell**. It is a notice, at
>   the two moments it matters: before a create (`existing session: … (Ns)`) and
>   after a refresh (`list re-read — list now`). A cell that ticks forever is a
>   clock, not information.
>
> Anything that needs to know "which state is the app in" reads header row 2 and
> compares it to the exact phrase. A test still reading the footer for the state
> is asserting a placement the product no longer has.


Main content:
- Single text: The main content contains a single text field
- Single edit: The main content displays a line for edit, and nothing below it
- Sessions: The main content displays a line for the filter (it starts empty), and below the table of all the sessions and the respective data, but only the tables following the filter. The table can be scrolled. Columns are device (local/remote server name), timestamp of the session, session state (running/stopped), session name (if not empty). The items are organized by server name first, except local is always first, then timestamp.
- Filtered list: The main content displays a line for the filter (it starts empty), and below the list of items according to the filter

> **Amended by RCH-9 (change 1).** The filter line is drawn only in the states
> that can actually receive typing — Attach, Delete, the remote picker and the
> theme picker. `{Mode selection}`'s main content is still Sessions, but it
> draws **no filter line at all**: it has no filter binding (RCH-3 / R2), and a
> filter you cannot type into is decoration that costs a row. `session_body`
> derives its body height from the same predicate that decides whether the line
> is painted (`app.state_is_filter_view`), so the table expands into the freed
> row rather than reserving space for a line that was never drawn.
>
> The two predicates answer **different questions and must not be merged**:
> `state_is_filter_view` = "is the filter line DRAWN here?";
> `state_filter_is_editable` = "does typing go INTO the filter here?" — and the
> latter is still exactly the four picker states, untouched by RCH-9. So
> "Sessions" in the bullet above means the table plus a filter line **in the
> states that filter**, and the table alone in `{Mode selection}`. Everything
> else is unchanged: full-height scrollable table, those four columns in that
> order, local first then by timestamp.


States:
- {Mode selection}: The main content is Sessions
    - [Enter] New session. TUI disappears and starts a new herdr session. Once the herdr session ends (e.g. CTRL+B q in herdr to exit while destorying the session), the TUI appears in the Mode selection. -> {Mode selection}
    - [n] New local named session -> {Select name of new local session}
    - [r] New remote session -> {Select remote server for new remote session}
    - [s] New remote named session -> {Select remote server for new named remote session}
    - [a] Attach to session -> {Select session to attach}
    - [d] Delete session -> {Select session to delete}
    - [t] Theme -> {Select theme}
    - [Escape, CTRL+C] Exit the program
- {Select name of new local session}: The main content is Single edit
    - [Other keys] type in the field
    - [Enter] TUI disappears and starts the selected herdr session. Once the herdr session ends (e.g. CTRL+B q in herdr to exit while destorying the session), the TUI appears in the Mode selection. If nothing was selected, pressing the key does nothing.
    - [Escape] Clears the edit field -> {Mode selection}
    - [CTRL+C] Exit the program
- {Select remote server for new remote session}: The main content is Filtered list with all known remotes.
    - [Up/down/Tab/Shift+Tab] move the selection
    - [Other keys] type in the filter, which updates the list.
    - [Enter] Select the remote. If nothing was selected, pressing the key does nothing. TUI disappears and starts the new herdr session. Once the herdr session ends (e.g. CTRL+B+q in herdr to exit while destorying the session), the TUI appears in the Mode selection.  -> {Mode selection}
    - [Escape] {Mode selection}
    - [CTRL+C] Exit the program
- {Select name for new named remote session}: The main content is Single edit
    - [Other keys] type in the field
    - [Enter] -> {Select remote server for new remote session}
    - [Escape] {Mode selection}
    - [CTRL+C] Exit the program
- {Select session to attach}: The main content is Sessions
    - [Up/down/Tab/Shift+Tab] move the selection
    - [Other keys] type in the filter, which updates the list.
    - [Enter] Select the session. If nothing was selected, pressing the key does nothing. TUI disappears and starts the selected herdr session. Once the herdr session ends (e.g. CTRL+B+q in herdr to exit while destorying the session), the TUI appears in the Mode selection.  -> {Mode selection}
    - [Escape] Clears the filter -> {Mode selection}
    - [CTRL+C] Exit the program
- {Select theme}: The main content is Filtered list. The theme selected by default is the theme currently being applied.
    - [Up/down/Tab/Shift+Tab] move the selection
    - [Other keys] type in the filter, which updates the list.
    - [Enter] Applies the theme and clears the filter -> {Mode selection}
    - [Escape] Clears the filter -> {Mode selection}
    - [CTRL+C] Exit the program
- {Error}: The main content is Single text with the error
    - [Enter/Escape] -> {Mode selection}
    - [CTRL+C] Exit the program

If an error happens (e.g. failed to create the remote session), a floating pane

The theme is saved in ~/.config/herdr_session.json (JSON, not TOML — the config format is JSON and there is no TOML parser in the product; the alacritty colour files live in `.pi/plans/theme-sources/` as vendored data only). When the program starts, it reads this configuration so that it knows the colors one want. Look in the internet for a list of themes. There must be catputin-latte (that is not the default, it's just what I prefer).

The palette itself is a verbatim alacritty `colors.*` schema mirror; an optional per-role override layer (`theme_overrides` in the same JSON file) may replace the resolved colour of one role per theme on top of that base.

The program should immediately show the local sessions, and in parallel, it should try to fetch the remote sessions. Whenever there is information of a session, it should update the list of sessions.


