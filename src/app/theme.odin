package app

// ============================================================================
// app.theme — the compiled-in palette set (T6.2, plan D4)
//
// # WHAT THIS FILE OWNS
//
// The *names* and the *colours*. Nothing else. No file I/O (that is config.odin),
// no termbox call (that is render.attr_of), no Clay type. A palette here is a
// table of 0xRRGGBB integers behind semantic slot names, and the only thing that
// turns one into a `clay.Color` is `ui.palette_of` — one function, in one place,
// with the 0..255 fact written next to it.
//
// # WHY A U32 HEX AND NOT A clay.Color
//
//   * the values below are transcribed straight from the cited sources as hex, so
//     `bg = 0x282828` is diffable against gruvbox's own table without a
//     float-in-a-literal detour;
//   * it keeps this package free of the renderer's dependencies — `app` stays
//     testable without a terminal or a Clay archive in the picture;
//   * the conversion point is then impossible to miss, which matters because of
//     the trap below.
//
// # TRAP: Clay channels are 0..255, NOT 0.0..1.0
//
// `Clay_Color` is `[4]c.float` carrying 0..255 (clay-odin/clay.odin:51).
// Feeding 0.16 instead of 40 paints the whole UI black and every check goes red
// at once. Already paid for once; see render/renderer.odin's `attr_of` header.
//
// # TRAP: termbox2 reads a zero attr as "terminal default"
//
// In truecolour the attr's low 24 bits are the RGB, and an attr of 0 with no
// TB_HI_BLACK means "use whatever the terminal has", not "black" (termbox2.h:
// 3830, 3883). So a genuinely black cell needs TB_HI_BLACK set. That is
// handled inside `render.attr_of` — a theme asking for #000000 gets real black,
// not the terminal's background. `theme_rgb` keeps that a non-issue upstream by
// never rounding a requested colour toward zero.
//
// # SOURCES (scout-nix-packaging.md §f; do not "improve" a hex value)
//
//   gruvbox     morhetz/gruvbox          gruvbox_256palette.sh
//   catppuccin  catppuccin/palette       palette.json (v1.8.0)
//   tokyonight  folke/tokyonight.nvim   lua/tokyonight/colors/night.lua
//   nord        nordtheme/nord           src/nord.scss ($nord0..$nord15)
//   solarized   altercation/solarized    README palette table
//
// Every slot value below is one of those files' values, re-labelled. The *choice*
// of which documented colour fills which slot is ours and is stated per theme.
//
// # SLOT SET
//
// The rule for "no gaps" is: the palette has a slot for every semantic colour
// the view layer references, so a view never reaches for a colour the theme does
// not define. The thirteen slots are exactly the fields of `ui.Palette`:
//
//   bg, fg, dim, border (== the between-children rule colour; with D14 there is
//   no outer box, so border and rule are the same colour by construction),
//   header_fg, accent (the selection bar background), sel_fg (text drawn ON the
//   bar), caret, float_bg, float_fg, err_fg, running, stopped.
//
// `running` / `stopped` are new with the theme work: the sessions table painted
// both with the default fg, so a theme could not distinguish a live session from
// a dormant one. Both now come from the palette.
//
// # DEFAULT IS gruvbox-dark (D4)
//
// `catppuccin-latte` ships and is selectable — the user asked for it by name —
// but it is explicitly NOT the default. `THEME_DEFAULT_NAME` is the fallback for
// "no config", "unreadable config" and "config names a theme we do not have",
// which is why it lives here rather than in the config module.
// ============================================================================

import "core:fmt"
import "base:runtime"
import "core:strings"

//-----------------------------------------------------------------------------
// Slot model
//-----------------------------------------------------------------------------

// Palette is one theme's semantic colours as 0xRRGGBB.
//
// Field order matches `ui.Palette` one-for-one; `ui.palette_of` maps them by
// name, so a rename here that skips the mapper is a compile error rather than a
// silently-miscoloured widget.
Palette :: struct {
	bg        : u32, // terminal background
	fg        : u32, // default text
	dim       : u32, // secondary text: column headers, placeholders, key hints
	border    : u32, // box border AND the between-children rules (D14: no box)
	header_fg : u32, // the header title
	accent    : u32, // the selection bar background
	sel_fg    : u32, // text drawn on the selection bar
	caret     : u32, // edit caret
	float_bg  : u32, // floating pane background
	float_fg  : u32, // floating pane text
	err_fg    : u32, // error text / error pane border
	running   : u32, // a session that is up
	stopped   : u32, // a session that is not
}

// PALETTE_SLOTS names the count the smoke suite asserts on. Adding a slot to
// `Palette` without bumping this makes that check fail, which is the point: the
// view layer must never be left without a colour.
PALETTE_SLOTS :: 13

// theme_rgb splits a palette entry into 0..255 channels.
//
// Explicit shifts rather than a transmute: the caller must be able to see that a
// 0xRRGGBB becomes (R,G,B) with no normalisation anywhere near it.
theme_rgb :: proc(hex: u32) -> (r, g, b: u8) {
	r = u8((hex >> 16) & 0xff)
	g = u8((hex >> 8) & 0xff)
	b = u8(hex & 0xff)
	return
}

// theme_hex renders a palette entry back as the six-digit form the sources use.
theme_hex :: proc(hex: u32) -> string {
	return fmt.tprintf("#%06x", hex & 0xffffff)
}

//-----------------------------------------------------------------------------
// Theme identity
//-----------------------------------------------------------------------------

// Theme is one selectable entry: its canonical name, the names that also resolve
// to it, and its colours.
Theme :: struct {
	name    : string,   // canonical, kebab-case — what the config stores
	aliases : []string, // tolerant spellings for CONFIG resolution only
	pal     : Palette,
}

// THEME_DEFAULT_NAME is the answer to "we could not work out a theme". D4.
THEME_DEFAULT_NAME :: "gruvbox-dark"

// Resolve_Kind says how a requested name landed, so the caller can put the
// honest word in front of it.
Resolve_Kind :: enum {
	explicit,  // the name was known and used as given
	defaulted, // nothing was requested: the D4 default, no warning owed
	fell_back, // a name WAS given but we do not ship it: warn, use the default
}

resolve_kind_label :: proc(k: Resolve_Kind) -> string {
	switch k {
	case .explicit:  return "explicit"
	case .defaulted: return "defaulted"
	case .fell_back: return "fell_back"
	}
	return "?"
}

//-----------------------------------------------------------------------------
// THE SET
//
// Ten themes. The plan defers the size of the set ("extend later"), so the bar
// used here was: every value present in scout-nix-packaging.md §f with a cited
// upstream file, a coherent 13-slot mapping, and both required names.
//
// Aliases are deliberately NARROW: they exist so a hand-edited config written
// with the flavour word ("latte") rather than the canonical id still resolves.
// The picker's filter is a substring match over the canonical names, so
// "latte", "catppuccin" and "c-latte" all narrow the list without help from
// this field — see the note on theme_matches.
//-----------------------------------------------------------------------------

THEMES : [10]Theme = {
	// ── gruvbox-dark: the default (D4) ─────────────────────────────────
	// Source: gruvbox_256palette.sh. accent = bright yellow (gruvbox's own
	// highlight colour); sel_fg is dark0_hard so the bar stays readable.
	{
		name    = "gruvbox-dark",
		aliases = []string{"gruvbox", "gruvbox_dark"},
		pal = Palette{
			bg        = 0x282828, // dark0
			fg        = 0xebdbb2, // fg1
			dim       = 0xd5c4a1, // fg2
			border    = 0x504945, // dark2
			header_fg = 0xebdbb2, // fg1
			accent    = 0xd79921, // bright yellow
			sel_fg    = 0x1d2021, // dark0_hard
			caret     = 0xfe8019, // orange
			float_bg  = 0x32302f, // dark0_medium
			float_fg  = 0xebdbb2, // fg1
			err_fg    = 0xfb4934, // red
			running   = 0xb8bb26, // green
			stopped   = 0x928374, // gray
		},
	},

	// ── gruvbox-light ──────────────────────────────────────────────────
	{
		name    = "gruvbox-light",
		aliases = []string{"gruvbox_light"},
		pal = Palette{
			bg        = 0xfbf1c7, // light0
			fg        = 0x3c3836, // dark1
			dim       = 0x504945, // dark2
			border    = 0xd5c4a1, // light3
			header_fg = 0x3c3836, // dark1
			accent    = 0xb57614, // dark yellow
			sel_fg    = 0xfbf1c7, // light0
			caret     = 0xaf3a03, // dark orange
			float_bg  = 0xf9f5d7, // light0_h
			float_fg  = 0x3c3836, // dark1
			err_fg    = 0x9d0006, // neutral red
			running   = 0x79740e, // neutral green
			stopped   = 0x928374, // mid gray (documented neutral)
		},
	},

	// ── catppuccin-latte: REQUIRED, and explicitly NOT the default ─────
	// Source: catppuccin/palette palette.json v1.8.0. The canonical spelling is
	// `catppuccin-latte` (the user wrote "catputin"); the misspelling is an
	// alias so the config forgives but the product name stays correct.
	{
		name    = "catppuccin-latte",
		aliases = []string{"latte", "catppuccin", "catpuccin-latte", "catppuccin_latte"},
		pal = Palette{
			bg        = 0xeff1f5, // base
			fg        = 0x4c4f69, // text
			dim       = 0x6c6f85, // subtext0
			border    = 0xbcc0cc, // surface1
			header_fg = 0x4c4f69, // text
			accent    = 0x8839ef, // mauve
			sel_fg    = 0xeff1f5, // base
			caret     = 0xfe640b, // peach
			float_bg  = 0xe6e9ef, // mantle
			float_fg  = 0x4c4f69, // text
			err_fg    = 0xd20f39, // red
			running   = 0x40a02b, // green
			stopped   = 0x9ca0b0, // overlay0
		},
	},

	{
		name    = "catppuccin-frappe",
		aliases = []string{"frappe"},
		pal = Palette{
			bg        = 0x303446, // base
			fg        = 0xc6d0f5, // text
			dim       = 0xa5adce, // subtext0
			border    = 0x51576d, // surface1
			header_fg = 0xc6d0f5, // text
			accent    = 0xca9ee6, // mauve
			sel_fg    = 0x292c3c, // mantle
			caret     = 0xef9f76, // peach
			float_bg  = 0x292c3c, // mantle
			float_fg  = 0xc6d0f5, // text
			err_fg    = 0xe78284, // red
			running   = 0xa6d189, // green
			stopped   = 0x737994, // overlay0
		},
	},

	{
		name    = "catppuccin-macchiato",
		aliases = []string{"macchiato"},
		pal = Palette{
			bg        = 0x24273a, // base
			fg        = 0xcad3f5, // text
			dim       = 0xa5adcb, // subtext0
			border    = 0x494d64, // surface1
			header_fg = 0xcad3f5, // text
			accent    = 0xc6a0f6, // mauve
			sel_fg    = 0x1e2030, // mantle
			caret     = 0xf5a97f, // peach
			float_bg  = 0x1e2030, // mantle
			float_fg  = 0xcad3f5, // text
			err_fg    = 0xed8796, // red
			running   = 0xa6da95, // green
			stopped   = 0x6e738d, // overlay0
		},
	},

	{
		name    = "catppuccin-mocha",
		aliases = []string{"mocha"},
		pal = Palette{
			bg        = 0x1e1e2e, // base
			fg        = 0xcdd6f4, // text
			dim       = 0xa6adc8, // subtext0
			border    = 0x45475a, // surface1
			header_fg = 0xcdd6f4, // text
			accent    = 0xcba6f7, // mauve
			sel_fg    = 0x181825, // mantle
			caret     = 0xfab387, // peach
			float_bg  = 0x181825, // mantle
			float_fg  = 0xcdd6f4, // text
			err_fg    = 0xf38ba8, // red
			running   = 0xa6e3a1, // green
			stopped   = 0x6c7086, // overlay0
		},
	},

	// ── tokyonight-night ───────────────────────────────────────────────
	{
		name    = "tokyonight-night",
		aliases = []string{"tokyonight", "tokyo-night", "tokyo_night"},
		pal = Palette{
			bg        = 0x1a1b26, // bg
			fg        = 0xc0caf5, // fg
			dim       = 0xa9b1d6, // fg
			border    = 0x3b4261, // fg_gutter
			header_fg = 0xc0caf5, // fg
			accent    = 0x7aa2f7, // blue
			sel_fg    = 0x1a1b26, // bg
			caret     = 0xff9e64, // orange
			float_bg  = 0x16161e, // bg_dark
			float_fg  = 0xc0caf5, // fg
			err_fg    = 0xf7768e, // red
			running   = 0x9ece6a, // green
			stopped   = 0x565f89, // comment
		},
	},

	// ── nord: nord0..nord15 maps 1:1 onto the slots ───────────────────
	{
		name    = "nord",
		aliases = []string{"nord-theme", "nordtheme"},
		pal = Palette{
			bg        = 0x2e3440, // nord0
			fg        = 0xe5e9f0, // nord5
			dim       = 0xd8dee9, // nord4
			border    = 0x4c566a, // nord3
			header_fg = 0xeceff4, // nord6
			accent    = 0x88c0d0, // nord8 (frost)
			sel_fg    = 0x2e3440, // nord0
			caret     = 0xd08770, // nord12
			float_bg  = 0x3b4252, // nord1
			float_fg  = 0xe5e9f0, // nord5
			err_fg    = 0xbf616a, // nord11
			running   = 0xa3be8c, // nord14
			stopped   = 0x4c566a, // nord3
		},
	},

	// ── solarized ──────────────────────────────────────────────────────
	// Dark and light share the accent set exactly; only the monotone pairs swap
	// (base03<->base3, base02<->base2, base01<->base1, base00<->base0).
	{
		name    = "solarized-dark",
		aliases = []string{"solarized", "solarized_dark"},
		pal = Palette{
			bg        = 0x002b36, // base03
			fg        = 0x839496, // base0
			dim       = 0x586e75, // base01
			border    = 0x073642, // base02
			header_fg = 0x93a1a1, // base1
			accent    = 0x268bd2, // blue
			sel_fg    = 0x002b36, // base03
			caret     = 0xcb4b16, // orange
			float_bg  = 0x073642, // base02
			float_fg  = 0x839496, // base0
			err_fg    = 0xdc322f, // red
			running   = 0x859900, // green
			stopped   = 0x586e75, // base01
		},
	},

	{
		name    = "solarized-light",
		aliases = []string{"solarized_light"},
		pal = Palette{
			bg        = 0xfdf6e3, // base3
			fg        = 0x657b83, // base00
			dim       = 0x93a1a1, // base1
			border    = 0xeee8d5, // base2
			header_fg = 0x586e75, // base01
			accent    = 0x268bd2, // blue (identical in both modes)
			sel_fg    = 0xfdf6e3, // base3
			caret     = 0xcb4b16, // orange
			float_bg  = 0xeee8d5, // base2
			float_fg  = 0x657b83, // base00
			err_fg    = 0xdc322f, // red
			running   = 0x859900, // green
			stopped   = 0x93a1a1, // base1
		},
	},
}

//-----------------------------------------------------------------------------
// Enumeration
//-----------------------------------------------------------------------------

theme_count :: proc() -> int { return len(THEMES) }

theme_at :: proc(i: int) -> Theme { return THEMES[i] }

// theme_names lists the CANONICAL names in picker order, allocated from `alloc`.
//
// Only canonical names reach the picker: an alias is a door into the table, not
// a second entry in it. Listing both would let the user "pick" two names for one
// palette and then the config would disagree with the screen.
//
// The picker's *filter* is `theme_matches`, which lives with the state machine in
// state.odin and is a case-insensitive substring test over the canonical name.
// The alias list is deliberately NOT consulted there: the filter narrows a list
// the user is looking at, and showing `latte` and `catppuccin-latte` as two rows
// for one palette would misreport how many themes exist. Aliases belong to
// config resolution (theme_resolve), where the user typed a name and meant one.
theme_names :: proc(alloc: runtime.Allocator) -> ([]string, runtime.Allocator_Error) {
	out := make([dynamic]string, 0, len(THEMES))
	for t in THEMES do append(&out, strings.clone(t.name, alloc))
	return out[:], nil
}

//-----------------------------------------------------------------------------
// Resolution
//-----------------------------------------------------------------------------

// theme_index_of finds a theme by canonical name, then by alias.
// Comparison ignores case and surrounding whitespace, because a hand-written
// config is edited by a person and `"Gruvbox-Dark "` must not be a fatal typo.
theme_index_of :: proc(requested: string) -> (int, bool) {
	needle := strings.trim_space(requested)
	if len(needle) == 0 { return -1, false }
	lowered := strings.to_lower(needle, context.temp_allocator)

	for t, i in THEMES {
		if strings.to_lower(t.name, context.temp_allocator) == lowered {
			return i, true
		}
	}
	for t, i in THEMES {
		for a in t.aliases {
			if strings.to_lower(a, context.temp_allocator) == lowered {
				return i, true
			}
		}
	}
	return -1, false
}

theme_is_known :: proc(requested: string) -> bool {
	_, ok := theme_index_of(requested)
	return ok
}

theme_named :: proc(requested: string) -> (Theme, bool) {
	i, ok := theme_index_of(requested)
	if !ok { return Theme{}, false }
	return THEMES[i], true
}

// theme_named_or_default is the "just give me something to paint with"
// lookup: exact name, then alias, then the D4 default. It is `theme_resolve`
// with the kind dropped, for callers that cannot act on the difference.
theme_named_or_default :: proc(requested: string) -> Theme {
	t, _ := theme_resolve(requested)
	return t
}

// theme_default is THE fallback theme: no config, unreadable config, or a config
// naming something we do not ship. It is a lookup, so the default can never be a
// palette that drifted away from the table.
theme_default :: proc() -> Theme {
	t, ok := theme_named(THEME_DEFAULT_NAME)
	// gruvbox-dark is in the table by construction (the smoke suite asserts
	// it). If that ever stops being true, the FIRST theme is the next-best
	// answer: a usable, fully-populated palette, which is all this path needs.
	if !ok && len(THEMES) > 0 { return THEMES[0] }
	return t
}

// theme_resolve answers "the config said X — what do we paint, and what must we
// tell the user about it?"
//
// The three answers are why this returns a kind rather than a bool: ISC-19 needs
// an unknown name to be LOUD (a warning) and an absent name to be SILENT (a
// default). A bool would collapse the two and the footer would either spam on a
// fresh install or stay quiet over a typo.
theme_resolve :: proc(requested: string) -> (Theme, Resolve_Kind) {
	trimmed := strings.trim_space(requested)
	if len(trimmed) == 0 {
		return theme_default(), .defaulted
	}
	t, ok := theme_named(trimmed)
	if !ok {
		return theme_default(), .fell_back
	}
	return t, .explicit
}

// Unknown_Theme_Message is the one line ISC-19 asks for: it names the value that
// was wrong, what is being used instead, and where the list lives.
Unknown_Theme_Message :: proc(requested: string) -> string {
	return fmt.tprintf(
		"unknown theme '%s' - using %s (available: %s)",
		requested, THEME_DEFAULT_NAME, theme_list_string(context.allocator))
}

// theme_list_string is the shipped set, canonical spelling, in picker order.
//
// strings.join, not `+`: Odin does not concatenate strings with an operator (the
// plan's trap list), and the result is allocated from the caller's allocator.
theme_list_string :: proc(alloc: runtime.Allocator) -> string {
	names, _ := theme_names(alloc)
	joined, _ := strings.join(names, ", ", alloc)
	return joined
}
