You are an orchestrator, you should delegate tasks to herdr subagents.

This repository is a nix flake for the program herdr-session. The program is a TUI program to create, delete or attach to herdr sessions, both local or remote sessions.

If I nix run to this flake it should run the herdr-session program (it's the default output).

This has to be implemented in the Odin language (https://devenv.sh/languages/odin/) and use Clay (https://github.com/nicbarker/clay and the binding are in
https://github.com/nicbarker/clay/tree/main/bindings/odin), for calculating the layout of the TUI. Look in /home/alexfneves/gits/tui_experiment for inspiration of how the odin language could be used with clay to make a TUI (it's just an experiment with not enough content and possible a wrong structure).


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


Main content:
- Single text: The main content contains a single text field
- Single edit: The main content displays a line for edit, and nothing below it
- Sessions: The main content displays a line for the filter (it starts empty), and below the table of all the sessions and the respective data, but only the tables following the filter. The table can be scrolled. Columns are device (local/remote server name), timestamp of the session, session state (running/stopped), session name (if not empty). The items are organized by server name first, except local is always first, then timestamp.
- Filtered list: The main content displays a line for the filter (it starts empty), and below the list of items according to the filter


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

The theme is saved in ~/.config/herdr_session.toml. When the program starts, it reads this configuration so that it knows the colors one want. Look in the internet for a list of themes. There must be catputin-latte (that is not the default, it's just what I prefer).

The program should immediately show the local sessions, and in parallel, it should try to fetch the remote sessions. Whenever there is information of a session, it should update the list of sessions.


