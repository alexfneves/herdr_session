# Context for: herdr-session TUI — Odin + Clay render layer

Scout report, 2026-10-18. Scope: what a planner needs to design the render/input layer
without re-asking. All facts verified by reading the files / fetching upstream.
No project code was written.

---

## 0. Headline facts (decision-relevant)

1. **The local `clay-odin` in the experiment is byte-identical to upstream `nicbarker/clay` main today.**
   `bindings/odin/clay-odin/clay.odin` and `bindings/odin/clay-odin/linux/clay.a` both match
   (md5 `5eefb8b6…` / `399f27987f27e7be2a1ea4e10b002532`). Clay release = **v0.14** (latest tag) plus
   post-release fixes; binding last touched upstream 2026-05-03 (`8c6ab7289`), prebuilt libs 2026-05-20 (`e6cc36941`).
   ⇒ The binding is current; no need to upgrade. Just copy the `clay-odin/` folder (or vendor `clay.h` + build).
2. **Clay does NOT provide terminal rendering, raw mode, input, colors-as-cells, or borders-as-glyphs.**
   It only produces a `RenderCommandArray`. Everything below it (raw mode, ANSI output, glyph choices,
   keyboard input, resize) is the app's job. The experiment rolls all of that itself and does it *badly*
   (see §6).
3. **There are two upstream C terminal renderers worth copying as reference (there is NO Odin terminal renderer):**
   - `renderers/terminal/clay_renderer_terminal_ansi.c` (~7.6 KB, minimal, ANSI) — good skeleton,
     admits in comments that its text measure is wrong for real text.
   - `renderers/termbox2/clay_renderer_termbox2.c` (~73 KB) — the *correct* approach: UTF-8 aware,
     `tb_wcwidth` per codepoint, proper border glyphs, cell size abstraction, scissor handling.
   - There is also `examples/terminal-example/main.c` showing how the ANSI renderer is wired to Clay.
4. **Odin core has no `wcwidth`, no terminal-size helper, and no `ioctl`.** There *is* `core:terminal/ansi`
   (escape-sequence constants only) and `core:sys/posix/termios.odin` + `poll.odin` + `signal.odin`.
   A terminal size call (`ioctl(TIOCGWINSZ)`) must be hand-declared (`foreign libc`), and its request code
   differs Linux vs Darwin.
5. **The environment currently cannot build Odin at all**: no `odin`, no `clang` on PATH; the flake
   (`flake.nix`, 50 LOC) only has `pkgs.hello`. `herdr` *is* installed (`/home/alexfneves/.nix-profile/bin/herdr`).

---

## (a) File map (paths + LOC)

### Target repo — `/home/alexfneves/gits/herdr_session`
| Path | LOC / size | Notes |
|---|---|---|
| `docs/main.md` | 94 lines / 5.9 KB | Full functional spec: layout (Header/Main/Footer + borders), 7 states, key bindings, theme in `~/.config/herdr_session.toml`, async remote session fetch |
| `flake.nix` | 50 lines | devenv-based flake; **no Odin**, default outputs are only devShells; `nix run` target does not exist yet |
| `.envrc` | 11 lines | nix-direnv → `use flake . --no-pure-eval` |
| `*.odin` | — | **none exist yet** (repo is a skeleton; single commit `5146042 chore: first commit`) |

### Reference experiment — `/home/alexfneves/gits/tui_experiment`
| Path | LOC / size | Notes |
|---|---|---|
| `main.odin` | **1046 lines / 33.7 KB** | The whole experiment: raw mode, input parse, Clay layout, custom cell renderer, ANSI flush, OSC-52 clipboard, selection. Single file, all globals |
| `clay-odin/clay.odin` | 601 lines / 14.7 KB | Official Clay Odin binding (== upstream main) |
| `clay-odin/linux/clay.a` | 205,596 B | prebuilt static lib (== upstream) |
| `clay-odin/macos-arm64/clay.a` | 171,704 B | |
| `clay-odin/macos/clay.a` | 176,024 B | x86_64 mac |
| `clay-odin/windows/clay.lib` | 203,200 B | |
| `clay-odin/wasm/clay.o` | 365,455 B | |
| `report.html` | 36 KB | Auto-generated “architecture report” of main.odin. **Readable summary, but it overstates two things**: claims “double-buffered frames + diffing” and “blocking input read” — the code has *no diffing* and *non-blocking* read. Trust the source, not the report |
| git history | 7 commits | `c9261ab` initial → `8363b0e` second scrollable window. Commit `5686748 fix: exiting was changing the background of the original terminal (sometimes)` — they fought exit-restore bugs without discovering the alternate screen buffer |

### Upstream reference material fetched (in `/tmp/clayref`, also online)
| Path (github `nicbarker/clay@main`) | Size | Notes |
|---|---|---|
| `clay.h` | 303,701 B | single-header layout engine |
| `bindings/odin/clay-odin/*` | — | identical to the experiment's copy |
| `bindings/odin/build-clay-lib.sh` | 927 B | exact commands used to build each per-platform `.a` from `clay.h` (clang `-DCLAY_IMPLEMENTATION`, `-ffreestanding -static`, `ar r`) |
| `renderers/terminal/clay_renderer_terminal_ansi.c` | 7,660 B | ANSI renderer reference |
| `renderers/termbox2/clay_renderer_termbox2.c` | 73,540 B | termbox2 renderer (best-practice reference: wcwidth, border glyphs) |
| `examples/terminal-example/main.c` | 1,396 B | how the ANSI renderer + Clay are initialized (`columnWidth = 16` units per cell) |
| `bindings/odin/README.md` | 7,931 B | **stale**: its examples use `clay.TextConfig(...)` and an `id = clay.ID(...)` field on the declaration struct — neither exists in the actual v0.14 binding. Do not copy from the README |

---

## (b) Clay-in-Odin init + linking recipe (as actually used)

### Linking (`clay-odin/clay.odin:5-17`)
```odin
when ODIN_OS == .Windows {
	foreign import Clay "windows/clay.lib"
} else when ODIN_OS == .Linux {
	foreign import Clay "linux/clay.a"
} else when ODIN_OS == .Darwin {
	when ODIN_ARCH == .arm64 { foreign import Clay "macos-arm64/clay.a" }
	else                      { foreign import Clay "macos/clay.a" }
} else when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 {
	foreign import Clay "wasm/clay.o"
}
```
* Plain `foreign import <name> "<relative path>"` — **paths are resolved relative to `clay.odin` itself**, so the
  `clay-odin/<platform>/*` directory layout must be preserved when vendoring.
* There is **no** `#foreign_system_library` anywhere; the only system linkage needed by the app itself is libc:
  `foreign import libc "system:c"` (`main.odin:167`) with hand-declared `ioctl` / `fcntl` (`main.odin:168-172`).
* Consumer import is simply `import clay "clay-odin"` (`main.odin:9`).
* All Clay symbols are `@(link_prefix = "Clay_", default_calling_convention = "c")` (`clay.odin:474`), with a
  second `private` group for `_ConfigureOpenElement/_HashString/_HashStringWithOffset/_OpenTextElement` (`clay.odin:514-520`).
* Building the `.a` yourself (for Nix reproducibility) is one clang invocation per target — see
  `bindings/odin/build-clay-lib.sh`; Linux line:
  `clang -c -DCLAY_IMPLEMENTATION -o clay.o -ffreestanding -static -target x86_64-unknown-linux-gnu clay.c -fPIC -O3 && ar r clay-odin/linux/clay.a clay.o`
* **Odin needs a C linker driver** (clang on Linux/macOS) — `clang` is *not* currently in the devenv shell.

### Init (verbatim from the experiment, `main.odin:531-538`)
```odin
min_mem_size := clay.MinMemorySize()
memory := make([]u8, int(min_mem_size))
defer delete(memory)

arena := clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory))
clay.Initialize(arena, clay.Dimensions{f32(term_cols), f32(term_rows)}, {})

clay.SetMeasureTextFunction(measure_text, nil)
```
Notes:
* `MinMemorySize()` must be called *before* `CreateArenaWithCapacityAndMemory`; sizing the arena from the OS
  allocator (`make`) is the accepted pattern. Defaults behind that number: `maxElementCount = 8192`,
  `maxMeasureTextWordCacheCount = 16384` (`clay.h:1150-1151`) — both runtime-settable
  (`clay.SetMaxElementCount`, `clay.SetMaxMeasureTextCacheWordCount`).
* **`clay.Initialize(..., {})` passes a NULL error handler.** `clay.h:4196` substitutes
  `Clay__ErrorHandlerFunctionDefault`, which is a **no-op** (`clay.h:1153-1155`).
  ⇒ Every Clay error (duplicate id, arena exceeded, unbalanced open/close, percent > 1) is **silently swallowed**
  and the layout silently degrades. For a TUI you cannot print to stderr (it corrupts the screen); install a
  `proc "c"` handler that records the error into app state and surface it in the UI.
* `SetMeasureTextFunction` must be called after `Initialize` (it writes into the current context).

### Unit convention (this is the key design choice)
Clay is unit-agnostic: the measure function defines what a “unit” is.
* **Experiment**: 1 unit = 1 terminal cell. `measure_text` returns `{width = len(bytes), height = 1.0}`
  (`main.odin:202-206`), every `fontSize = 1`, root sized `SizingFixed(term_cols) × SizingFixed(term_rows)`.
* **Official terminal example**: 1 cell = 16 units (`columnWidth = 16`) to allow sub-cell padding; renderer
  divides every bounding box by `columnWidth` and rounds (`clay_renderer_terminal_ansi.c:88-93`).
* The 1-unit-per-cell scheme works only if the measure function is integer-accurate; any padding is then an
  integer number of cells (fine for a TUI and the simplest thing to plan around).

### What Clay actually emits for text (important, verified in `clay.h:2976-3008`)
A text element is wrapped **by Clay** into `Clay__WrappedTextLine`s, and **one `TEXT` render command is emitted
per wrapped line**, each with its own bounding box (`boundingBox.x + alignment offset`, `y += lineHeight`).
So a renderer can assume: one TEXT command == one terminal row of text, and `boundingBox.x` is the start column.
(⇒ The upstream ANSI renderer's per-`\n` handling is only needed for literal newlines in the source string.)
`textAlignment` (.Left/.Center/.Right) and `lineHeight` are honoured by Clay, not by the renderer.

---

## (c) Main loop skeleton — quoted from the experiment (`main.odin:513-678`)

```odin
main :: proc() {
	enable_raw_mode()
	defer disable_raw_mode()
	posix.signal(posix.Signal(posix.SIGINT),  sighandler)   // 518
	posix.signal(posix.Signal(posix.SIGTERM), sighandler)   // 519

	cols, rows := get_terminal_size()                      // ioctl TIOCGWINSZ
	resize_buffers(term_cols, term_rows)
	… build app data (flat_text, display_lines, windows) …
	… clay init (see (b)) …

	fmt.print("\u001b[?25l\u001b[2J")                    // 540 hide cursor + clear (NO alt screen)
	fmt.print(ENABLE_MOUSE)                              // \e[?1000h\e[?1003h\e[?1006h
	fmt.print(ENABLE_KB)                                 // \e[>1u  (kitty, flag 1)
	defer { fmt.print(DISABLE_KB); fmt.print(DISABLE_MOUSE_AND_SGR); …free… }

	buf := [4096]byte{}
	for is_running {
		n, err := os.read(os.stdin, buf[:])            // 560 (fd is O_NONBLOCK → returns 0 instantly)
		if int(n) > 0 && err == nil {
			key := buf[:n]
			if code, mod, ok := parse_csi_u(key); ok { // kitty CSI-u: only used to detect Ctrl+C
				if code == 99 && (mod & 4) != 0 { is_running = false; break }
				if code == 3    { is_running = false; break }
			} else {
				c := key[0]                            // 577  ← ONLY THE FIRST BYTE OF THE READ IS USED
				if c == 'y' { copy_selection_to_clipboard(sel_win()) }
				else if c == 'q' || c == '\u0003' || c == '\u001a' { is_running = false; break }
			}
			x, y, is_down, valid, wheel := parse_sgr_mouse(key)   // 588
			if valid { …mouse_pos / mouse_down / wheel→scroll… }
		}

		cols, rows = get_terminal_size()               // 611 resize is POLLED every frame, no SIGWINCH
		if cols != term_cols || rows != term_rows {
			term_cols, term_rows = cols, rows
			resize_buffers(...); build_layout(); setup_windows()
			fmt.print("\u001b[2J")                   // 618 full clear (flicker)
		}

		clay.SetLayoutDimensions(clay.Dimensions{f32(term_cols), f32(term_rows)})  // 621
		clay.SetPointerState(mouse_pos, mouse_down)                                // 622
		clay.BeginLayout()                                                           // 623
		draw_tui()                                                                   // 625  describe the tree
		just_clicked  := mouse_down && !prev_mouse_down                              // 627
		mx := int(mouse_pos[0]); my := int(mouse_pos[1]) - 1                         // 631
		if just_clicked { for i in 0..<len(windows) { if clay.PointerOver(clay.ID(windows[i].id)) { …focus/selection… } } }
		…drag selection / release bookkeeping / copied_ttl countdown…
		prev_mouse_down = mouse_down

		render_commands := clay.EndLayout(0.016)          // 669
		render_clay_to_back_buffer(&render_commands)      // 670  paint into []Cell
		flush_buffers_to_terminal()                       // 671  emit one ANSI string
		time.sleep(16 * time.Millisecond)                 // 673  busy-sleep
	}
	fmt.print("\u001b[0m\u001b[2J\u001b[H"); fmt.println("Exited gracefully!")
}
```

### Terminal setup details (verbatim-ish)
```odin
// main.odin:129-153
enable_raw_mode :: proc() {
	posix.tcgetattr(posix.STDIN_FILENO, &orig_termios)
	raw := orig_termios
	raw.c_lflag -= { .ECHO, .ICANON, .IEXTEN }   // NOTE: .ISIG is deliberately KEPT ON (see below)
	raw.c_iflag -= { .IXON, .ICRNL }
	posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &raw)
	flags := fcntl(posix.STDIN_FILENO, F_GETFL, 0)
	if flags != -1 { fcntl(posix.STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) }
}
// main.odin:155-166
TIOCGWINSZ :: 0x5413            // Linux-only constant
winsize :: struct { ws_row, ws_col, ws_xpixel, ws_ypixel: u16 }
foreign libc {
	ioctl :: proc(fd: i32, request: u64, #c_vararg args: ..any) -> i32 ---
	fcntl :: proc(fd: i32, cmd: i32,  #c_vararg args: ..any) -> i32 ---
}
```
Protocols used (`main.odin:11-17`):
```
ENABLE_MOUSE          = "\e[?1000h\e[?1003h\e[?1006h"   // X10 + all-motion + SGR mouse
DISABLE_MOUSE_AND_SGR = "\e[?25h\e[?1000l\e[?1003l\e[?1006l"
ENABLE_KB             = "\e[>1u"                        // Kitty keyboard protocol, flag 1 (disambiguate)
DISABLE_KB            = "\e[<1u"
```
Cell + flush (`main.odin:113-120`, `1007-1046`):
```odin
Cell :: struct { char: rune, r,g,b: u8, bg_r,bg_g,bg_b: u8 }
// per row:  fmt.sbprintf(&sb, "\u001b[%d;1H", y+1)
// per cell: emit "\e[48;2;r;g;bm" only if bg changed; "\e[38;2;r;g;bm" only if fg changed; then the glyph
// whole frame is one os.write(os.stdout, sb.buf[:])   ← still a FULL repaint every frame
```
Why ISIG is kept on (comment at `main.odin:132-135`): so Ctrl+C raises a real SIGINT handled at 518, which the
author says lets them distinguish Ctrl+C (exit) from Ctrl+Shift+C (copy) via Kitty modifier reporting.
**Consequence: the program never sees byte 0x03 as input.** If the spec needs Ctrl+C to be state-dependent,
you must instead turn `.ISIG` off and handle 0x03 yourself.

---

## (d) `clay.odin` API surface (real names, v0.14 binding)

All of the following are the actual declared names (verified `clay.odin:475-601`). Prefix when calling: `clay.X`.

### Foreign (C) procedures — `clay.odin:475-512`
`_OpenElement`, `_OpenElementWithId`, `_CloseElement`,
`MinMemorySize`, `CreateArenaWithCapacityAndMemory`, `SetPointerState`, `GetPointerState`,
`Initialize`, `GetCurrentContext`, `SetCurrentContext`, `UpdateScrollContainers`,
`SetLayoutDimensions`, `BeginLayout`, `EndLayout(deltaTime) -> ClayArray(RenderCommand)`,
`GetOpenElementId`, `GetElementId`, `GetElementIdWithIndex`, `GetElementData(id) -> ElementData{boundingBox, found}`,
`Hovered`, `OnHover`, `PointerOver(id) -> bool`, `GetPointerOverIds`,
`GetScrollOffset() -> Vector2`, `GetScrollContainerData(id) -> ScrollContainerData`,
`SetMeasureTextFunction(fn, userData)`, `SetQueryScrollOffsetFunction(fn, userData)`,
`RenderCommandArray_Get(^ClayArray(RenderCommand), i32) -> ^RenderCommand`,
`SetDebugModeEnabled`, `IsDebugModeEnabled`, `SetCullingEnabled`,
`GetMaxElementCount`, `SetMaxElementCount`, `GetMaxMeasureTextCacheWordCount`,
`SetMaxMeasureTextCacheWordCount`, `ResetMeasureTextCache`, `EaseOut`.
Private group (`515-520`): `_ConfigureOpenElement`, `_HashString`, `_HashStringWithOffset`, `_OpenTextElement`.

Not exposed in the Odin binding although present in the `.a`: `Clay_GetLayoutDimensions`,
`Clay_SetExternalScrollHandlingEnabled`. **Not present in this Clay version at all: `MarkDirty` /
`MarkElementDirty`** (verified via `nm`: no `*dirty*` symbols in `linux/clay.a`). Immediate-mode re-describing
every frame is the intended model; text-content changes are handled by Clay's content-hashed measure cache.

### Odin helper wrappers — `clay.odin:522-601`
| Name | Purpose |
|---|---|
| `UI_WithId(id) -> proc(config) -> bool` | `if clay.UI(clay.ID("X"))({ … }) { children }` |
| `UI_AutoId() -> proc(config) -> bool` | auto id variant (no explicit id) |
| `UI :: proc { UI_WithId, UI_AutoId }` | overload set |
| `ConfigureOpenElement(config) -> bool` | the returned configurator (used with `UI`) |
| `TextStatic($text, config)` / `TextDynamic(text, config)` / `Text :: proc { … }` | static (compile-time string, `isStaticallyAllocated`) vs runtime string |
| `PaddingAll(n)` | `Padding{left,right,top,bottom}` |
| `BorderAll(w)` | `{w,w,w,w,w}` — includes `betweenChildren` |
| `BorderOutside(w)` | `{w,w,w,w,0}` — outer only |
| `CornerRadiusAll(r)` | |
| `SizingFit({min,max})` / `SizingGrow({min,max})` / `SizingFixed(f32)` / `SizingPercent(f32 0..1)` | the 4 sizing kinds |
| `MakeString(label) -> String`, `ID(label, index=0)`, `ID_LOCAL(label, index=0)` | ids; `ID_LOCAL` scopes to the currently open element (`GetOpenElementId`) |

### Element declaration fields (`ElementDeclaration`, `clay.odin:434-447`)
`layout` (`LayoutConfig{sizing, padding, childGap, childAlignment, layoutDirection}`),
`backgroundColor`, `overlayColor`, `cornerRadius`, `aspectRatio`, `image`, `floating`, `custom`,
`clip`, **`border`**, `transition`, `userData`.

### Visual elements actually available
* **Borders (per-side!)** — `border = clay.BorderElementConfig{ color = …, width = clay.BorderWidth{left,right,top,bottom,betweenChildren} }`.
  Emitted as `RenderCommandType.Border` with `BorderRenderData{color, cornerRadius, width}` (`clay.odin:131-142, 310-314`).
  `betweenChildren` is exactly the “separator line between sections” the spec asks for.
  The experiment **never uses this** (it hand-paints box glyphs — see §6).
* **Colors** — `Color :: [4]c.float`, RGBA components in **0..255** ranges, alpha 255 = opaque.
  No palette/index mode in Clay; the renderer maps them to 24-bit SGR (`38;2;r;g;b`), or down-converts to
  8/16/256 if the terminal is limited (`core:terminal` reports `Color_Depth`: None/Three/Four/Eight/True_Color).
* **Text** — `TextElementConfig{userData, textColor, fontId, fontSize, letterSpacing, lineHeight, wrapMode, textAlignment}`
  (`clay.odin:108-117`). `TextWrapMode{Words, Newlines, None}`; `TextAlignment{Left, Center, Right}`.
  In a terminal `fontSize` is meaningless except as the measure unit; `lineHeight = 1` pins a row height of one cell.
  **Clay has no rich-text / styled-span API** — one style per text element.
* **Scroll containers** — `clip = ClipElementConfig{horizontal, vertical, childOffset}` (v0.14 replaced `.scroll`).
  Two modes: (1) Clay-managed — `clay.GetScrollOffset()` inside the element + `clay.UpdateScrollContainers(drag, scrollDelta, dt)`
  each frame; (2) app-managed — pass your own `childOffset`.
  The experiment uses **neither** (manual index math + hand-painted scrollbar).
* **Floating** — `FloatingElementConfig{offset, expand, parentId, zIndex, attachment{element,parent}, pointerCaptureMode, attachTo ∈ {None,Parent,ElementWithId,Root}, clipTo}` —
  this is the correct mechanism for the spec's “floating error pane”.
* **Render command types** — `None, Rectangle, Border, Text, Image, ScissorStart, ScissorEnd, OverlayColorStart, OverlayColorEnd, Custom`
  (`clay.odin:79-90`). A terminal renderer should handle at least Rectangle / Border / Text / Scissor*, and
  treat ScissorStart/End as a clip rectangle (this is how `clip` containers get truncated).
* **Query API** — `GetElementData(id).boundingBox` gives any element's geometry by id **without** any alpha-tag hack.

### Id model
`clay.ID(label, index)` hashes a string → `ElementId{id, offset, baseId, stringId}`. Ids must be **unique per frame
among siblings**; use `index` for lists (`clay.ID("SessionRow", i)`) or `ID_LOCAL` inside a parent scope.
Duplicate ids are a reported error type (`ErrorType.DuplicateId`) — silently ignored with a NULL handler (§b).

---

## (e) Known pitfalls / wrong turns in the experiment (do NOT repeat)

Ordered by how much they'd hurt `herdr-session`.

1. **Only the first byte of each read is interpreted as a key.** `main.odin:560-585`: `key := buf[:n]`,
   `c := key[0]`. A single `read()` from a terminal routinely contains *multiple* key events (fast typing,
   paste, or a key batched with a mouse report). Everything after byte 0 is silently dropped.
   ⇒ The new program **must** use a persistent byte buffer + incremental escape-sequence parser
   (consume complete sequences, leave partial ones for the next read). This alone rules out copying the loop.
2. **No alternate screen buffer.** Only `\e[?25l\e[2J` (`main.odin:540`), `\e[2J` on resize (`:618`),
   `\e[0m\e[2J\e[H` at exit (`:676`). This destroys the user's scrollback and is exactly the class of bug
   the git log shows them fighting (`5686748 fix: exiting was changing the background of the original terminal`).
   ⇒ Use `\e[?1049h` on start / `\e[?1049l` on exit (both are constants in Odin's `core:terminal/ansi`:
   `DECASB_ENTER` / `DECASB_EXIT`).
3. **Full repaint every frame — no diff.** `flush_buffers_to_terminal` (`:1007-1046`) repaints *every* cell
   each frame. `front_buffer` is allocated (`:119`), written (`:1038`) and **never read for comparison**.
   Combined with O_NONBLOCK stdin + `time.sleep(16ms)` (`:560`, `:673`) the app idle-spins at ~60 fps,
   re-emitting the whole screen even when nothing changed.
   ⇒ Either implement a real front/back diff (emit only changed runs, with per-row cursor seeking) or drive the
   loop with `posix.poll`/`select` and repaint on change. (Note `report.html` incorrectly claims diffing exists.)
4. **`backgroundColor.alpha` abused as a “which window” tag.** `:768`
   `backgroundColor = {0, 0, 0, f32(win.index + 1)}`; renderer detects it at `:852`
   `is_contour := a == 1 || a == 2`, then `cur_win = int(a) - 1` (`:856`) and assumes every subsequent
   `Text` command belongs to that window (`:941-957`). This is order-dependent guesswork: floating elements,
   z-index sorting, culling, or a third pane silently break attribution, and it hard-codes a 2-pane app.
   Clay already offers **`clay.GetElementData(id).boundingBox`** for geometry and **`.border`** for borders.
   ⇒ Delete this whole trick from the plan.
5. **Borders drawn by the renderer, invisible to Clay.** Rounded glyphs `╭ ╮ ╰ ╯ ─ │` are painted in
   `render_clay_to_back_buffer` (`:887-893`) and the title/footnote are overlaid onto the border row
   (`:904-928`). Because Clay doesn't know a border exists, all padding must be hand-adjusted
   (`:750-758`, `pad_left`, `-1` for scrollbar column). ⇒ Use `border = clay.BorderElementConfig{...}`
   and render `RenderCommandType.Border` into line glyphs; `betweenChildren` gives the inter-section rule.
6. **`measure_text` measures BYTES, not characters/columns.** `main.odin:202-206`:
   ```odin
   measure_text :: proc "c" (text_slice: clay.StringSlice, config: ^clay.TextElementConfig, user_data: rawptr) -> clay.Dimensions {
       return clay.Dimensions{ width = f32(text_slice.length), height = 1.0 }
   }
   ```
   Any non-ASCII (UTF-8 2-4 bytes) mis-measures 2-4×, breaking Clay's wrapping and element widths;
   CJK/emoji double-width is entirely ignored. The official C ANSI renderer has the same flaw and admits it:
   *“TODO this function is very wrong, it measures in characters”* (`clay_renderer_terminal_ansi.c:46-50`).
   The termbox2 renderer does it correctly (`clay_renderer_termbox2.c:1206-1234`): decode UTF-8 → `tb_wcwidth(ch)`,
   fallback to width of U+FFFD for non-printables. ⇒ The new `measure_text` must decode UTF-8 and sum display widths.
7. **`TIOCGWINSZ :: 0x5413` is hard-coded Linux-only** (`main.odin:155`). On macOS/BSD it is `0x40087468`
   (`_IOWR('t', 104, winsize)`). The flake's `systems` includes Darwin. ⇒ `when ODIN_OS` select the constant
   (Odin's `core:sys/posix` has **no** `ioctl`/`winsize`, so a `foreign libc` declaration is unavoidable).
8. **Mouse Y coordinate is inconsistent → off-by-one.** `parse_sgr_mouse` does `x = x_val - 1` (`:465`) but
   `y = f32(y_val)` (`:466`), leaving `mouse_pos.y` **1-based**. It is then passed *raw* to
   `clay.SetPointerState(mouse_pos, …)` (`:622`) — Clay hit-tests one row off — while the app's own manual
   hit-testing subtracts 1 (`my := int(mouse_pos[1]) - 1`, `:631`). Two coordinate systems, one row apart.
9. **Resize is polled via ioctl every frame, not driven by SIGWINCH** (`:611`), and on resize the app does
   `delete` + `make` buffers and prints `\e[2J` (`:615-618`) → visible flicker; no `TCSAFLUSH`/drain.
   A SIGWINCH handler (Odin exposes `SIGWINCH` in `core/sys/posix/signal.odin`) that just sets a “dirty size”
   flag, consumed by the poll loop, is the clean shape.
10. **Input events are not a modeled type.** Keys and mouse are ad-hoc booleans + globals (`mouse_pos`,
    `mouse_down`, `prev_mouse_down`, `is_running`, `focused_win`, module-level at `:19-30`). There is **no
    handling at all for arrow keys, Tab, Shift+Tab, Backspace, Home/End, or paste** — the whole key set the
    spec needs. Only `y`, `q`, Ctrl+C/Ctrl+Z and Kitty CSI-u Ctrl+C are handled.
11. **`#partial switch cmd.commandType`** (`:842`) handles only `Rectangle` and `Text`. `Border`, `Image`,
    `ScissorStart/End`, `OverlayColor*`, `Custom` are silently ignored → any clipped container paints outside
    its bounds, and `.border` configs would render nothing.
12. **Manual, hand-maintained memory cleanup** — `defer` block at `:543-555` must individually know that
    `windows[1].lines` (`:552`), `windows[1].flat_text` (`:553`) and `window2_lines` are separate owners, and
    `make_window2_content`/`make_window_lines` carry explicit “do NOT `defer delete` here, the returned slice
    aliases the dynamic array” comments (`:279-281`, `:292-293`). This is a leak/double-free trap factory.
    ⇒ Use one arena for the frame / per-render allocations and pass owners explicitly.
13. **Clay scroll containers unused.** `UpdateScrollContainers` / `GetScrollOffset` / `clip` never called;
    scrolling = manual `w.scroll` index math (`:594-603`) and the scrollbar is hand-painted from the alpha-tagged
    rect (`draw_scrollbar`, `:787-829`). Fine as a fallback, but the natural Clay path is `.clip` +
    `ScrollContainerData` (`clay.odin:335-344`, whose `scrollPosition` is a mutable pointer by design).
14. **Global mutable state / monolith.** 1046 LOC in one `main.odin`, `windows: [2]Window` fixed-size array
    (`:55`), hard-coded `paragraphs` (`:72-77`), no model/layout/input/render separation. The spec has 7 states,
    filters, async remote fetch — it needs real module boundaries.
15. **Frame-budget lies**: `clay.EndLayout(0.016)` and `time.sleep(16 ms)` are hard-coded; the sleep is
    additive to the work, so the real frame rate is <60 and irregular. Timers/animation TTLs are frame-counted
    (`copied_ttl = 120` ≈ “2 s”, `:420`) and drift with actual frame time.
16. **`fmt.tprintf` per text line per frame** (`:699-720`) allocates from the global allocator every frame.
    Minor GC churn; better to build into a scratch builder or a frame arena.
17. **Width coupling**: the *text model* wraps at `wrap_width = min(100, max(20, cols-8))` (`:246`) while the
    *Clay box* width is `wrap_width + PAD_LEFT + PAD_RIGHT` (`:684`) and overflow is silently truncated at
    `avail` (`:776`). Two sources of truth for the same width; if they diverge, content silently disappears.
18. **`report.html` is not trustworthy** on two points: it claims “double-buffered frames + diffing” and a
    “blocking input read”. Neither is true in the code (see #1, #3). Also “~16 ms frame budget (60 FPS)” is
    optimistic given the sleep is added *after* the work.

---

## 1. Upstream Clay binding — verification details

* Repo path: `bindings/odin/{clay.odin, clay-odin/{linux,macos,macos-arm64,windows,wasm}/…, examples/, build-clay-lib.sh, README.md, odinfmt.json, ols.json}`.
* `bindings/odin/clay-odin/clay.odin` @ main == experiment's `clay-odin/clay.odin` (**md5 identical**).
* `bindings/odin/clay-odin/linux/clay.a` @ main == experiment's (`399f27987f27e7be2a1ea4e10b002532`).
* Latest release tag: **v0.14** (“Aspect Ratio Elements, Better Clipping”), and the release ships
  **`clay-odin.zip`** (595 KB) as a download artifact — the easiest way to vendor a matching binding + libs.
* v0.14 breaking change relevant here: **`.scroll` → `.clip`** (`ClipElementConfig{horizontal, vertical, childOffset}`),
  plus `Clay_GetScrollOffset()` for built-in scroll handling, or supply your own offset for external handling.
* The binding still carries transition APIs (`TransitionElementConfig`, `EaseOut`, …) added 2026-04/05 — unused for a TUI.
* **No official terminal-style Odin example exists.** `bindings/odin/examples/` only contains
  `clay-official-website.odin` + `clay_renderer_raylib.odin` (raylib/GUI). The only terminal renderers are C:
  `renderers/terminal/clay_renderer_terminal_ansi.c`, `renderers/termbox2/clay_renderer_termbox2.c`,
  and `examples/terminal-example/main.c`.
* Binding README is **stale** (uses `clay.TextConfig(...)` and `id = clay.ID(...)` inside declaration structs;
  neither exists — the real API is `clay.TextDynamic(string, clay.TextElementConfig{...})` and
  `clay.UI(clay.ID(...))({ ... })`).

---

## 2. Terminal rendering fundamentals (for Odin, no heavy framework)

### Raw mode
Use `core:sys/posix` (`termios.odin`, `tcgetattr`/`tcsetattr`/`tcsendbreak`/`tcflush` are all bound).
Canonical TUI raw mode:
```
c_lflag -= ECHO | ICANON | IEXTEN        (VMIN/VTIME may need tuning: set c_cc[VMIN]=1, c_cc[VTIME]=0)
c_lflag -= ISIG   ← decide: keep ON (Ctrl+C = SIGINT, app never sees 0x03)
                 or OFF (0x03 arrives as a byte — needed if Ctrl+C must be state-dependent)
c_iflag -= IXON | ICRNL                 (optional: - ICRNL so Enter arrives as \r not \n)
c_oflag : leave OPOST mostly intact unless you need exact byte output
restore the saved termios on exit (defer), even on signals
```
Windows: `core:sys/windows` console modes; not needed if the flake targets Linux only (planner's call).

### Alternate screen / exit hygiene
`\e[?1049h` on start, `\e[?1049l` on exit (Odin constants: `ansi.DECASB_ENTER`, `ansi.DECASB_EXIT`,
`core/terminal/ansi/ansi.odin`). Also hide/show cursor `ansi.DECTCEM_HIDE`/`_SHOW`, and `\e[0m` reset before exit.

### Escape sequences needed (constants available in `core:terminal/ansi`)
| Purpose | Sequence | `core:terminal/ansi` constant |
|---|---|---|
| Cursor position (1-based row;col) | `\e[{row};{col}H` | `CSI + CUP("H")` |
| Move cursor n cells | `\e[{n}A/B/C/D` | `CUU/CUD/CUF/CUB` |
| Hide / show cursor | `\e[?25l` / `\e[?25h` | `DECTCEM_HIDE/_SHOW` |
| Alt screen in/out | `\e[?1049h` / `\e[?1049l` | `DECASB_ENTER/_EXIT` |
| Erase display / line | `\e[2J` / `\e[K` | `ED("J")` / `EL("K")` |
| Truecolor fg/bg | `\e[38;2;r;g;bm` / `\e[48;2;r;g;bm` | `FG_COLOR_24_BIT` / `BG_COLOR_24_BIT` |
| 256-color fg/bg | `\e[38;5;{n}m` / `\e[48;5;{n}m` | `FG_COLOR_8_BIT` / `BG_COLOR_8_BIT` |
| Reset / bold / reverse / underline | `\e[0m` `\e[1m` `\e[7m` `\e[4m` | `RESET/BOLD/INVERT/UNDERLINE` |
| Save/restore cursor | `\e[s` / `\e[u` (or DECSC/DECRC `\e7` `\e8`) | `SCP/RCP`, `DECSC/DECRC` |
| Mouse (SGR) | `\e[?1000h\e[?1006h` (+`\e[?1003h` for motion) | (not in core — app constants) |
| Keyboard: kitty | `\e[>1u` / `\e[<1u` | (not in core) |
| Bracketed paste | `\e[?2004h` / `\e[?2004l`; paste delimited by `\e[200~ … \e[201~` | (not in core) |
| OSC 52 clipboard | `\e]52;c;<base64>\e\\` | `CLIPBOARD("52")` |

### Key input — what the terminal actually sends (must be parsed by hand)
* Plain printable: bytes (UTF-8 sequences for non-ASCII).
* Enter → `\r` (0x0D); with `-ICRNL` Ctrl+J also `\n`; **Backspace → 0x7F** (sometimes 0x08).
* Tab → `\t` (0x09); **Shift+Tab → `\e[Z`** (CSI Z) — a distinct sequence, needs explicit handling.
* Arrows → `CSI A/B/C/D` (`\e[1A` …), with modifiers as `\e[1;{mod}A`.
* Home/End/Insert/Delete/PgUp/PgDn/F1-F12 → assorted `CSI … ~` / legacy `SS3` (`\eO…`) forms.
* Ctrl+letter → the control byte (`Ctrl+C`=0x03, `Ctrl+D`=0x04, `Ctrl+H`=0x08, `Ctrl+M`=0x0D), unless ISIG
  intercepts (only C/D/Z/O are signals: SIGINT/SIGQUIT/Suspend/Toggle).
* **Ambiguity**: a lone `\e` may be the Escape key or the start of a sequence ⇒ requires a timeout
  (e.g. VTIME / poll timeout of ~50 ms) or the Kitty keyboard protocol to disambiguate.
* **Kitty protocol (`\e[>1u`)**: with flag 1 (disambiguate), keys report structured modifiers.
  CSI-u form is `\e[{unicode-or-PUA};{modifier}u`; modifier bits are **1 = Shift, 2 = Alt, 4 = Ctrl,
  8 = CapsLock, 16 = Ctrl+Alt as Super…** (value is 1-based: plain = 1, Ctrl = 5).
  Functional keys that have no legacy encoding use PUA codepoints (0xE000+). Arrow keys keep their
  legacy `CSI A..D` form but gain `;{mod}`. Terminal support varies (kitty, foot, wezterm, ghostty, st patched);
  **xterm/alacritty(legacy)/Windows Terminal don't support it** ⇒ a robust app must support *both* the plain
  legacy encodings and CSI-u, and degrade gracefully. The experiment relies on CSI-u for Ctrl+C detection while
  *also* keeping ISIG on — redundant and confusing.
* **Paste**: enable bracketed paste (`\e[?2004h`) to tell typed text from pasted text and to stop a pasted
  `\r` from submitting a form.

### Sizing / resize
* `ioctl(STDOUT, TIOCGWINSZ, &winsize)` → `ws_row`, `ws_col` (+ pixel fields, useless in most terminals).
  Constant differs per OS: **Linux `0x5413`**, **Darwin/BSD `0x40087468`**. Odin has no `ioctl` binding ⇒ declare
  `foreign libc { ioctl :: proc(fd: i32, request: u64, #c_vararg args: ..any) -> i32 --- }`.
  Odin's `posix.winsize` does **not** exist either (verified) — declare the struct locally, as the experiment does.
* Handle **SIGWINCH** (`core/sys/posix/signal.odin` exports `SIGWINCH` per-OS) → set a flag; re-read size on
  the next loop iteration; rebuild layout; repaint whole alt screen (fast) or handle gracefully.
  Fallback for non-tty / ioctl failure: 80×24 (the experiment does this at `main.odin:173-181`).

### Main-loop shape that actually behaves (recommendation to the planner)
`poll()` on stdin with a timeout (`core/sys/posix/poll.odin`: `poll :: proc(fds: [^]pollfd, nfds: nfds_t, timeout: c.int)`)
— or `select()` (`core/sys/posix/sys_select.odin`) — instead of O_NONBLOCK + `sleep(16ms)`.
Pipeline: `poll → read chunk → append to input buffer → drain complete events → update model → clay.BeginLayout →
declare UI → EndLayout → rasterize into cell buffer → diff vs front buffer → build one ANSI string → single write → swap buffers`.
Only repaint changed cells; batch colour changes; never `printf` per cell.

### Existing Odin terminal libraries (surveyed, GitHub search 2026-10-18)
| Library | Stars | Status | Notes |
|---|---|---|---|
| `RaphGL/TermCL` | 108 | **explicitly unmaintained** (author left Odin) | Full framework: `init_screen(vtable)`, Raw/Cbreak/Restored modes, parsed `Keyboard_Input`/`Mouse_Input`, window caching + `blit`, `termcl/raw` is a ~300 LOC escape-code file you can copy. Would fight Clay for ownership of the screen unless used purely as escape-code/IO layer |
| `CRBroughton/alloy` | 5 | TUI framework for Odin | Generic framework; overlaps Clay's job |
| `qxuken/odin-tui` | 5 | WIP cell renderer for Odin | Cell renderer — closest analogue to what we hand-roll |
| `joaocarvalhoopen/ogdb`, `odb` | 9/8 | debugger TUIs | Reference only |
| `krisfur/huginn`, `dbrckovi/Simple-File-Commander`, etc. | 2-7 | apps | Reference only |
* **No Odin library is the obvious pairing for Clay.** Every project surveyed either *is* a framework or is unmaintained.
* Practical options: (A) roll the ~300 LOC escape/raw layer by hand (Odin core termios + a hand-declared ioctl +
  a CSI parser) — matches the experiment's zero-dependency style and Clay's “you own the renderer” model;
  (B) **termbox2** (single C file, ~public-domain) via a thin Odin binding — gives raw mode, a parsed input
  event queue with correct UTF-8/modifiers, resize events, and a 256-colour cell buffer; the upstream
  `clay_renderer_termbox2.c` is a direct translation target. Note termbox2 does **24-bit colour via
  `TB_ATTR_...` palette only** unless built with truecolor support (`tb_set_truecolor(1)`); Clay colors are RGBA
  floats so mapping is needed either way.

---

## 3. Text input / editable fields in Odin (caret, backspace, UTF-8, wide chars)

### What Clay gives you
**Nothing beyond layout.** Clay has no text-input widget, no caret model, no selection/cursor API.
For text it provides: `TextDynamic/TextStatic` with `textColor/fontSize/letterSpacing/lineHeight/wrapMode/textAlignment`,
its own wrapping into per-line render commands, `textAlignment` offsets, and hover/pointer hit-testing.
There is **no rich-text / inline-style-run API** — a whole text element has one style.

### What you must implement yourself
* **Buffer + caret**: the app owns the string and a caret offset. Rendering the caret = place the caret glyph
  at the cell computed from the string's *display width* up to that offset (+ container x offset which
  Clay gives you from the element's bounding box).
  Practical approach in a cell renderer: keep caret as a **cell column**, derived from display width of the
  prefix — never from byte offset — or keep byte/rune offset and compute display columns when drawing.
* **Backspace**: must delete a whole **rune** (or grapheme cluster), not a byte; `utf8.decode_last_rune_in_string(s, caret)`
  gives you the rune and its byte length so you can splice from the caret.
* **UTF-8 decoding**: `core:unicode/utf8` — `decode_rune` (`decode_rune_in_string`, `decode_rune_in_bytes`),
  `decode_last_rune` (`decode_last_rune_in_string`, `…_in_bytes`), `encode_rune`.
  Grapheme clusters: `core:unicode/utf8/grapheme.odin` — `decode_grapheme_clusters`,
  `decode_grapheme_iterator_make`, `decode_grapheme_iterate(it) -> (text, Grapheme, ok)`.
  For an input field, grapheme-aware editing matters for emoji + ZWJ sequences and combining marks.
* **Display width (wcwidth)**: **Odin has no wcwidth** (verified: nothing in `core` — only `core/unicode`
  tables which don't include East Asian Width lookups as a public helper). You must implement or bind:
  - ASCII → 1
  - Combining marks (Mn/Me/Mc), ZWJ (U+200D), variation selectors U+FE00–FE0F → 0
  - East Asian Wide/Fullwidth (and emoji ranges) → 2
  - C0/C1 controls → 0 or handle as `\x..` escapes
  - Emoji presentation (e.g. U+1F600) → 2 in modern terminals; a new emoji-with-skin-tone (ZWJ) sequence is
    typically 2 cells total regardless of its byte count, and terminals disagree.
  Reference implementation to copy: `clay_renderer_termbox2.c:1206-1234` (uses `tb_wcwidth`,
  falls back to `tb_wcwidth(0xFFFD)` for non-printables).
  Practical scope note for `herdr-session`: session names, remote hosts and filter text are almost always ASCII,
  but session names are user-supplied — a user can type any UTF-8. **Minimum viable**: decode UTF-8, treat
  every rune as ≥1 cell, treat wide ranges as 2 cells, treat combining as 0 cells, and never index into a
  string by byte while laying out.
* **Cell-level consequence of wide chars**: in a cell grid, a 2-column glyph must occupy the next cell too
  (usually written as a blank/placeholder cell) or every subsequent column shifts by one and the renderer's
  cursor math desyncs. The experiment never deals with this (byte-wise `cx += 1` at `main.odin:960-979`).
* **Input sanitation**: control characters arriving in the middle of a buffer (e.g. pasted text containing `\r`,
  `\e`, `0x00`) must be filtered before they reach an edit field, otherwise an embedded escape sequence can be
  emitted back out and mess up the screen.

---

## 4. Environment / build facts

* Current shell (devenv, `nix-direnv` 3.1.0, `use flake . --no-pure-eval`) has **`gcc` 16.2 + binutils**, but
  **no `odin`, no `clang`**. `nix run` currently runs nothing useful (`packages = [pkgs.hello]`).
* The spec requires `languages.odin.enable = true` (devenv Odin module) and the flake must gain:
  a default **package** output (`herdr-session`) so `nix run .#herdr-session` / `nix run` (default output) works,
  Odin packages, a C linker (clang), and Clay (vendored `clay.odin` + `.a`, or a derivation that compiles
  `clay.h -DCLAY_IMPLEMENTATION` into a static lib using `bindings/odin/build-clay-lib.sh` as the recipe).
* The `clay-odin` folder layout must be preserved (relative `foreign import` paths), or the binding patched.
* `herdr` **is** installed and has a rich CLI + socket API: `herdr session <subcommand>`, `herdr api …`,
  `herdr workspace|worktree|tab|pane|agent|notification …`, `herdr --remote <ssh-target> [--session <name>]`,
  `herdr status [server|client]`. The existing shell equivalent being replaced is
  `~/.config/home-manager/herdr/herdr-cycle.sh` (185 lines, bash+fzf+python3), which documents real
  constraints: **herdr session names only allow `[A-Za-z0-9._-]` — no colons**, and names are timestamped
  `YYYY-MM-DD-HH-MM-SS-mmm`.
* Odin core pieces useful here: `core:sys/posix` (`termios.odin`, `poll.odin`, `signal.odin`, `unistd.odin`),
  `core:terminal` (`is_terminal`, `color_depth`, `is_dumb`), `core:terminal/ansi` (escape constants),
  `core:unicode/utf8` (+ `grapheme.odin`), `core:strings` (`Builder`, `builder_init`/`builder_destroy` still
  present in master, `write_byte`, `write_string`, `to_string`), `core:strconv`, `core:fmt` (`sbprintf`),
  `core:time`, `core:os` (`os.read`, `os.write`, `os.stdout`, `get_environment_variable*`).

---

## 5. Mapping the spec onto Clay elements (facts that make the mapping obvious)

| Spec requirement | Direct Clay mechanism | Notes |
|---|---|---|
| Border around whole app + border line between sections | `border = BorderElementConfig{color, width: BorderAll(1)}` on Header/Main/Footer; `BorderWidth.betweenChildren` for the rules between children | Renderer must turn `RenderCommandType.Border` + `BorderRenderData.width.{left,right,top,bottom,betweenChildren}` into line glyphs (`─ │ ┌ ┐ └ ┘ ├ ┤ ─` or single-line box drawing) |
| TUI fills all available space | root element `SizingFixed(cols)` × `SizingFixed(rows)` (or `SizingGrow`) with `layoutDirection = .TopToBottom` | |
| Header fixed height / Footer fixed height / Main grows | `SizingFixed(1)` / `SizingGrow({})` | |
| Sessions list with filter line above | TopToBottom container: filter text element + scroll/clip container of rows | Scrolling via `.clip{vertical=true, childOffset=…}` (app-managed) or Clay-managed with `UpdateScrollContainers` |
| Table columns (device, timestamp, state, name) | LeftToRight rows with fixed `SizingFixed(n)` per column | Column widths in cells; decide truncation policy (`textAlignment` won't truncate — the renderer must clip) |
| Selection highlight on a row | Draw the selected row's background from app state at render time (Clay knows nothing about “selected”) | Or `overlayColor` on the row element — `RenderCommandType.Rectangle` carries `backgroundColor` only, `overlayColor` comes as `OverlayColorStart/End` pairs |
| Floating error pane | `floating = FloatingElementConfig{attachTo = .Root (or .Parent), zIndex, offset, expand, pointerCaptureMode}` | Renders above siblings |
| Themes (catppuccin-latte etc.) | App-level palette table → Clay `Color` (RGBA 0..255 floats) at declare time | Clay has no theme concept; colors are passed per element each frame |
| “Nothing selected → Enter does nothing” | App state, not layout | |

---

## (f) Open questions the planner must decide

1. **Renderer base**: hand-rolled cell renderer (Odin + termios + own ANSI writer, Clay commands → cells)
   **or** a `clay_renderer_termbox2.c`-style port (termbox2 dependency)? This decides raw-mode code,
   input parsing, color mapping, diffing, and the whole Nix dependency set.
2. **Diff vs full repaint, and repaint trigger**: real front/back diff + `poll()`-driven repaint, or full repaint
   on a timer? (Recommendation implied by §e.3: diff + poll.)
3. **Ctrl+C semantics**: keep `ISIG` on so Ctrl+C is a signal that must exit *from any state* (simplest, matches
   the spec “CTRL+C Exit the program”), or turn it off and treat 0x03 as an input event? Note: with ISIG on
   you cannot intercept Ctrl+C, and Ctrl+D (0x04) still arrives as a byte (not a signal without ICANON).
4. **Escape key vs sequence ambiguity**: adopt the Kitty protocol (`\e[>1u`) as the experiment does, or parse only
   legacy sequences with a timeout to disambiguate lone ESC (the spec uses Escape as “back”)? Terminals without
   Kitty support make this a real decision.
5. **Units**: 1 Clay unit = 1 cell (simple, integer, no sub-cell padding) or 1 cell = N units (like upstream's 16,
   allows proportional padding/alignment)? Affects `measure_text`, all `padding`, all `SizingFixed` values.
6. **measure_text accuracy / UTF-8 width**: implement a wcwidth table in Odin, bind a C one, or restrict the
   input charset? What is the minimum acceptable behavior for CJK/emoji in filters and session names?
7. **Where wrapping happens**: let Clay wrap text (`wrapMode = .Words`) and rely on per-line TEXT render commands,
   or pre-wrap in the app model (the experiment's approach) and use `wrapMode = .None`? Pre-wrapping is needed for
   the flat-document/selection/reading-order model if selection/copy is ever required.
8. **Borders vs padding**: use Clay `.border` (renderer draws glyphs, Clay accounts for the space) — recommended —
   or draw glyphs in the renderer outside Clay's knowledge? Must be decided before any layout math is written.
9. **Scroll strategy for the session table**: Clay-managed scrolling (`clip` + `GetScrollOffset` +
   `UpdateScrollContainers`) or app-managed (scroll index in cells, `childOffset`, keyboard-driven)?
   Keyboard-driven lists almost certainly want app-managed (pixel offsets are meaningless at cell granularity).
10. **Async remote session fetch**: the spec requires the local list to show immediately and remotes to fill in
    “whenever” data arrives — decide the concurrency model (core threads + channel (`core:thread`), a poll callback
    inside the loop, or a background goroutine-like worker) and how arrival wakes the render loop
    (self-pipe / eventfd added to `poll()`).
11. **Theme storage**: `~/.config/herdr_session.toml` — Odin has no TOML in core. Decide: vendor/binding a TOML
    parser (C library through the same static-lib approach? which one?), a simpler format, or a hand-rolled minimal parser.
12. **Module decomposition**: e.g. `terminal/` (raw mode, io, escape), `input/` (key model + parser),
    `render/` (Clay→cells→ANSI), `ui/` (Clay layout components), `app/` (state machine, sessions, config),
    `main.odin` (loop wiring). Needs an explicit decision to avoid the experiment's 1046-LOC monolith.
13. **Platform scope**: Linux only, or also Darwin (affects the `TIOCGWINSZ` constant, termios details, the `.a`
    used, and the flake's `systems`)?
14. **Vendoring strategy for Clay**: copy `clay-odin/` (with prebuilt `.a`/`.lib`) into the repo, or a Nix
    derivation that fetches `clay.h` at a pinned rev and runs the `build-clay-lib.sh` recipe (reproducible, no
    binaries in git)?
15. **Error/floating pane behavior**: which element does the error float attach to, what dismisses it
    (Enter/Escape per spec), and does it need to survive across states?
16. **Cursor vs fake caret**: show the real terminal cursor positioned at the field caret (simpler, IME-friendly,
    but requires managing cursor position across the diff renderer), or hide it and draw a caret block?
