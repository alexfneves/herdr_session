# Vendored alacritty theme files (terminalcolors.com)

Fetched 2026-10-25 from `https://terminalcolors.com/downloads/alacritty/<slug>.toml`.
Files are VERBATIM byte copies. No values edited, normalized, or invented.

| # | repo theme name    | working slug           | URL | bytes | status | sha256 |
|---|------------------|------------------------|-----|-------|--------|--------|
| 1 | gruvbox-dark      | gruvbox-dark            | https://terminalcolors.com/downloads/alacritty/gruvbox-dark.toml | 496 | FETCHED | 321c9813559a9a6eb99a6ee19829f19a9b9b874ac3cb849d5ddf9826ff7aeb0f |
| 2 | gruvbox-light     | gruvbox-light           | https://terminalcolors.com/downloads/alacritty/gruvbox-light.toml | 496 | FETCHED | 4b3f4dccaf5496bbdff7908d928dc11232df4e4e9b288e42d571f3d1b586c828 |
| 3 | catppuccin-latte  | catppuccin-latte        | https://terminalcolors.com/downloads/alacritty/catppuccin-latte.toml | 496 | FETCHED | 3e23ff7d55a606811dcea37fd87991c7f6c28ba7e53cd8be4107f09e99babded |
| 4 | catppuccin-frappe | catppuccin-frappe       | https://terminalcolors.com/downloads/alacritty/catppuccin-frappe.toml | 496 | FETCHED | 6a2bd3bb2aedb7764ee302716e9ecde375a1a7efcd8578cd5061fe398011df2a |
| 5 | catppuccin-macchiato | catppuccin-macchiato | https://terminalcolors.com/downloads/alacritty/catppuccin-macchiato.toml | 496 | FETCHED | 4340bb9b6b3ad823d27d4e66052b00a06e51876f12bcdd8e668a569bd7c2055f |
| 6 | catppuccin-mocha  | catppuccin-mocha        | https://terminalcolors.com/downloads/alacritty/catppuccin-mocha.toml | 496 | FETCHED | 76829d7b773dfa66f282c2963d297089db89e45c442dd71b33f6d45cf4e8a43b |
| 7 | tokyonight-night  | tokyo-night-default     | https://terminalcolors.com/downloads/alacritty/tokyo-night-default.toml | 496 | FETCHED | 4618d0efa28c768b86973fcf6f0a94e92f2bb14fae46cac3992b0cfe54821092 |
| 8 | nord              | nord-default            | https://terminalcolors.com/downloads/alacritty/nord-default.toml | 496 | FETCHED | f1aeb81518df1413f1e265c8e207cad214bf09a3a4b379b73d4dbd91b7329431 |
| 9 | solarized-dark    | solarized-dark          | https://terminalcolors.com/downloads/alacritty/solarized-dark.toml | 496 | FETCHED | c892854c5437e8b39161092f452fb06d6b86064fff2c2b9ed147ac5f725cd346 |
| 10 | solarized-light  | solarized-light         | https://terminalcolors.com/downloads/alacritty/solarized-light.toml | 496 | FETCHED | 1230f8ec75ddb464d9edd026c08e5f9876cf1df5bf1266fb5065cec2869a2cf4 |

## Validation

- Every one of the 10 files: HTTP 200, `Content-Type: application/toml`, 496 bytes, and starts with the exact bytes `[colors`.
- All 10 default/first-choice slugs resolved on the first try. No fallback discovery was needed and no theme is NOT FOUND.
- The 496-byte uniformity is real, not a placeholder: md5 of the 10 files yields 10 distinct digests.

## Key set (identical across all 10 files)

Exactly 5 tables / 22 keys, same order in every file:

```
[colors.primary]  foreground, background
[colors.cursor]   text, cursor
[colors.selection] text, background
[colors.normal]   black, red, green, yellow, blue, magenta, cyan, white
[colors.bright]   black, red, green, yellow, blue, magenta, cyan, white
```

- **No theme deviates from this shape.** No `secondary`, `dim`, `vi_mode_cursor`, `search`, `hints`, `badge`, `indexed_colors`, or `ansi` tables appear in any of the 10 files. Only the hex values differ.

## Cross-check vs the app's existing verbatim palettes (src/app/theme.odin, read-only)

Reference shape taken from the plan's existing catppuccin-latte / gruvbox-dark entries.

- gruvbox-dark: primary fg `#ebdbb2` / bg `#282828` == repo `fg 0xebdbb2` / `bg 0x282828`. MATCH.
- catppuccin-latte: primary fg `#4c4f69` / bg `#eff1f5` == repo `fg 0x4c4f69` / `bg 0xeff1f5`. MATCH.
- Also matching between fetched primary fg/bg and repo bg/fg: gruvbox-light, catppuccin-frappe, catppuccin-macchiato, catppuccin-mocha, tokyonight-night, solarized-dark, solarized-light.
- **nord differs (NOT fixed, recorded only):** fetched `primary.foreground = "#d8dee9"` (nord4), repo `fg = 0xe5e9f0` (nord5). Backgrounds agree (`#2e3440` == `0x2e3440`).
- The alacritty files carry no equivalent of the app's other palette roles (dim, border, accent, header_fg, sel_fg, caret, float_*, err_fg, running, stopped, key_fg, desc_fg, caret_bg, caret_fg). Only primary/cursor/selection/normal/bright exist upstream.
