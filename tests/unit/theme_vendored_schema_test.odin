package unit

// ============================================================================
// theme_vendored_schema_test.odin — the palette's PROVENANCE, checked against
// the files it was transcribed from.
//
// WHY THIS FILE IS THE LOAD-BEARING ONE
//
// The palette is no longer authored. It is a mirror of an externally-defined
// colour schema, and the mirrors live in `.pi/plans/theme-sources/*.toml`. The
// claim "every theme loads its 22 values from the vendored schema" is only
// worth something if it is CHECKED, because the alternative failure mode is
// silent: a single hex digit mistyped during the transcription produces a theme
// that looks fine, passes every "is the slot filled" test, and disagrees with
// its own source. So this test goes and looks.
//
// IT IS NOT A TOML PARSER AND MUST NOT BECOME ONE
//
// The repo's rule is JSON-only configuration and no TOML parser anywhere (see
// `hygiene_no_toml_anywhere_in_src` — which greps `src/`, and this file is in
// `tests/` deliberately). What lives here is an EXACT-SHAPE VERIFIER:
//
//   * every file is byte-pinned by sha256 FIRST, so the bytes being examined
//     are known-identical to the recorded artifact and cannot be "some other
//     file that happens to be shaped like one";
//   * the file must contain EXACTLY 5 table headers, in a fixed order, and
//     EXACTLY 22 lines of the form `key = "#rrggbb"`, in the recorded order,
//     with nothing else but blank lines between sections;
//   * anything unexpected — a comment, an extra key, a different quoting
//     style, a 3-digit hex, a nested table — makes the verifier FAIL rather
//     than get parsed. It is a fingerprint check with a lookup, not a
//     decoder: a file that varies from the pinned shape cannot reach the
//     lookup at all.
//
// The reason it exists at all is that sha256 alone proves the file is unchanged
// but says nothing about the COMPILED VALUES, and a hand-transcribed table in
// the test would prove nothing about the FILE. This closes both ends: the file
// is pinned, the file's 22 values are read off it in key order, and the
// compiled palette must equal them key for key.
//
// WHY THE SCHEMA KEY ORDER IS SOURCED FROM `app.palette_keys()`
//
// So there is one definition of "the 22 keys" shared by the product and this
// test. The verifier maps `(table, key)` from the file text onto the same enum,
// and the comparison is `theme_slot(theme, k) == file_value(k)` for every k —
// a key added to the schema without being vendored, or vendored without being
// added, fails with the key named.
// ============================================================================

import "core:fmt"
import "core:crypto/sha2"
import "core:os"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

// ── the pinned artifacts ───────────────────────────────────────────────────
//
// `file` is the vendored filename; `theme` is the CANONICAL repo theme name it
// must match; `sha256` is the digest recorded in
// `.pi/plans/theme-sources/README.md`; `bytes` is the size recorded there
// (all ten are 496 — a length check that catches a truncated fetch before the
// digest has to).
Vendored :: struct {
	file   : string,
	theme  : string,
	bytes  : int,
	sha256 : string,
}

VENDORED : [10]Vendored = {
	{"gruvbox-dark.toml",          "gruvbox-dark",          496, "321c9813559a9a6eb99a6ee19829f19a9b9b874ac3cb849d5ddf9826ff7aeb0f"},
	{"gruvbox-light.toml",         "gruvbox-light",         496, "4b3f4dccaf5496bbdff7908d928dc11232df4e4e9b288e42d571f3d1b586c828"},
	{"catppuccin-latte.toml",      "catppuccin-latte",      496, "3e23ff7d55a606811dcea37fd87991c7f6c28ba7e53cd8be4107f09e99babded"},
	{"catppuccin-frappe.toml",     "catppuccin-frappe",     496, "6a2bd3bb2aedb7764ee302716e9ecde375a1a7efcd8578cd5061fe398011df2a"},
	{"catppuccin-macchiato.toml",  "catppuccin-macchiato",  496, "4340bb9b6b3ad823d27d4e66052b00a06e51876f12bcdd8e668a569bd7c2055f"},
	{"catppuccin-mocha.toml",      "catppuccin-mocha",      496, "76829d7b773dfa66f282c2963d297089db89e45c442dd71b33f6d45cf4e8a43b"},
	{"tokyo-night-default.toml",   "tokyonight-night",      496, "4618d0efa28c768b86973fcf6f0a94e92f2bb14fae46cac3992b0cfe54821092"},
	{"nord-default.toml",          "nord",                  496, "f1aeb81518df1413f1e265c8e207cad214bf09a3a4b379b73d4dbd91b7329431"},
	{"solarized-dark.toml",        "solarized-dark",        496, "c892854c5437e8b39161092f452fb06d6b86064fff2c2b9ed147ac5f725cd346"},
	{"solarized-light.toml",       "solarized-light",       496, "1230f8ec75ddb464d9edd026c08e5f9876cf1df5bf1266fb5065cec2869a2cf4"},
}

SCHEMA_DIR_REL :: ".pi/plans/theme-sources"

// the five tables, in the order the files list them, with the keys each holds.
SCHEMA_TABLES : [5]string = {"primary", "cursor", "selection", "normal", "bright"}
TABLE_KEYS    : [5][8]string = {
	{"foreground", "background", "", "", "", "", "", ""},
	{"text", "cursor", "", "", "", "", "", ""},
	{"text", "background", "", "", "", "", "", ""},
	{"black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"},
	{"black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"},
}

// ── where the vendored files are, from wherever the suite was started ────────
schema_dir :: proc() -> string {
	cands : [4]string = {
		SCHEMA_DIR_REL,
		fmt.tprintf("../{}", SCHEMA_DIR_REL),
		fmt.tprintf("../../{}", SCHEMA_DIR_REL),
		fmt.tprintf("../../../{}", SCHEMA_DIR_REL),
	}
	for d in cands {
		if fi, err := os.stat(d, context.allocator); err == nil && fi.type == .Directory {
			return string(d)
		}
	}
	return ""
}

hex_value :: proc(text: string) -> (u32, bool) {
	if len(text) != 6 { return 0, false }
	v : u32 = 0
	for i := 0; i < 6; i += 1 {
		c := text[i]
		d : u8
		if c >= '0' && c <= '9' {
			d = c - '0'
		} else if c >= 'a' && c <= 'f' {
			d = c - 'a' + 10
		} else if c >= 'A' && c <= 'F' {
			d = c - 'A' + 10
		} else {
			return 0, false
		}
		v = (v << 4) | u32(d)
	}
	return v, true
}

hex_digit :: proc(v: u8) -> u8 {
	if v < 10 { return u8('0') + v }
	return u8('a') + (v - 10)
}

// sha256_into writes the lowercase hex digest of `data` into `hex`, which must
// be at least 64 bytes. It deliberately takes a caller-owned buffer instead of
// returning a string: `string(stack_array[:])` would build a header pointing at
// memory that dies on return, and the digest would read back as NULs — a silent
// failure that looks like a hash mismatch. The caller keeps the buffer alive for
// as long as the string it derives from it is used.
sha256_into :: proc(data: []byte, hex: []byte) {
	assert(len(hex) >= 64, "sha256_into needs 64 bytes")
	ctx : sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sum : [32]u8
	sha2.final(&ctx, sum[:])
	for i := 0; i < 32; i += 1 {
		b := sum[i]
		hex[i*2] = hex_digit(u8(b >> 4))
		hex[i*2+1] = hex_digit(u8(b & 0xf))
	}
}

// Schema_File :: the 22 values read off a vendored file, indexed by
// `app.Palette_Key` so the comparison against the compiled palette is by key
// and not by position-in-array.
Schema_File :: struct {
	values : [22]u32,
	found  : [22]bool,
	// the verifier's complaint, if it has one. Anything unrecognised lands here
	// and the caller treats a non-empty reason as a FAILED verification rather
	// than as "that line didn't count".
	reason : string,
	ok     : bool,
}

// read_schema_file verifies the exact shape of one vendored file and returns
// its 22 values keyed by `app.Palette_Key`.
//
// Not a parser: see the header. Every line is either a known table header, a
// `key = "#rrggbb"` line whose (table,key) is one of the 22 known schema
// keys, or empty. A line that is none of those fails the whole read.
read_schema_file :: proc(path: string) -> Schema_File {
	out : Schema_File
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil || data == nil {
		out.reason = fmt.tprintf("cannot read: {}", err)
		return out
	}
	defer delete(data)
	text := string(data)

	table := -1 // index into SCHEMA_TABLES; -1 before the first header
	key_seen : [5][8]bool
	lineno := 0
	for line in split_lines(text) {
		lineno += 1
		raw := line
		// A trailing CR is a line-ending difference, not a schema difference.
		if len(raw) > 0 && raw[len(raw)-1] == '\r' { raw = raw[:len(raw)-1] }
		trimmed := strings.trim_space(raw)
		if len(trimmed) == 0 { continue }

		if trimmed[0] == '[' {
			// Must be exactly `[colors.<table>]` for the NEXT table in order.
			want := fmt.tprintf("[colors.{}]", SCHEMA_TABLES[0])
			if table + 1 < len(SCHEMA_TABLES) {
				want = fmt.tprintf("[colors.{}]", SCHEMA_TABLES[table+1])
			} else {
				out.reason = fmt.tprintf("line {}: table header after all 5 tables", lineno)
				return out
			}
			if trimmed != want {
				out.reason = fmt.tprintf("line {}: header '{}' is not the expected '{}'", lineno, trimmed, want)
				return out
			}
			table += 1
			continue
		}

		if table < 0 {
			out.reason = fmt.tprintf("line {}: content before the first table header", lineno)
			return out
		}

		// Must be `key = "#rrggbb"` with `key` one of this table's known keys.
		eq := strings.index(trimmed, "=")
		if eq < 0 {
			out.reason = fmt.tprintf("line {}: not a key/value line: '{}'", lineno, trimmed)
			return out
		}
		k := strings.trim_space(trimmed[:eq])
		v := strings.trim_space(trimmed[eq+1:])
		// The whole value token must be exactly `"#rrggbb"` — 9 bytes, quote,
		// hash, six hex, quote. Anything else (single quotes, no hash, a
		// 3-digit hex, a trailing comma) is a shape this verifier refuses.
		if len(v) != 9 || v[0] != '"' || v[1] != '#' || v[8] != '"' {
			out.reason = fmt.tprintf("line {}: value {} is not exactly a quoted #rrggbb (len {})", lineno, v, len(v))
			return out
		}
		digits := v[2:8]
		hex, ok := hex_value(digits)
		if !ok {
			out.reason = fmt.tprintf("line {}: '{}' is not six hex digits", lineno, digits)
			return out
		}
		key_idx := -1
		for i := 0; i < 8; i += 1 {
			if TABLE_KEYS[table][i] == k { key_idx = i; break }
		}
		if key_idx < 0 {
			out.reason = fmt.tprintf("line {}: unknown key '{}' in table '{}'", lineno, k, SCHEMA_TABLES[table])
			return out
		}
		if key_seen[table][key_idx] {
			out.reason = fmt.tprintf("line {}: duplicate key '{}' in table '{}'", lineno, k, SCHEMA_TABLES[table])
			return out
		}
		key_seen[table][key_idx] = true

		kidx := palette_key_index(SCHEMA_TABLES[table], k)
		if kidx < 0 {
			out.reason = fmt.tprintf("line {}: '{}.{}' has no app.Palette_Key — the schema enum is out of step with the vendored files",
				lineno, SCHEMA_TABLES[table], k)
			return out
		}
		out.values[kidx] = hex
		out.found[kidx] = true
	}

	if table != len(SCHEMA_TABLES) - 1 {
		out.reason = fmt.tprintf("saw {} table header(s), expected {}", table+1, len(SCHEMA_TABLES))
		return out
	}
	missing := ""
	for i := 0; i < len(out.found); i += 1 {
		if !out.found[i] {
			missing = fmt.tprintf("{} {};", missing, app.palette_key_name(app.Palette_Key(i)))
		}
	}
	if len(missing) > 0 {
		out.reason = fmt.tprintf("schema key(s) absent from the file:{}", missing)
		return out
	}
	out.ok = true
	return out
}

// palette_key_index maps (table, key) as written in the file onto the product's
// schema-key enum. Linear and tiny on purpose: a lookup table here would be
// another thing that can drift from the enum.
palette_key_index :: proc(table, key: string) -> int {
	name := fmt.tprintf("{}.{}", table, key)
	for k in app.palette_keys() {
		if app.palette_key_name(k) == name { return int(k) }
	}
	return -1
}

// ── the assertions ─────────────────────────────────────────────────────────

@(test)
vendored_schema_files_are_present_and_byte_pinned :: proc(t: ^testing.T) {
	dir := schema_dir()
	if len(dir) == 0 {
		support.check(t, "the vendored schema directory is reachable from the test CWD", false,
			fmt.tprintf("looked for '{}' and three parent-relative forms; a pinned-provenance test that cannot find its artifacts has not verified anything, so this is a FAILURE and not a skip", SCHEMA_DIR_REL))
		return
	}
	bad := 0
	detail := ""
	for v in VENDORED {
		path := fmt.tprintf("{}/{}", dir, v.file)
		data, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil || data == nil {
			bad += 1
			detail = fmt.tprintf("{} MISSING:{};", detail, v.file)
			continue
		}
		got_len := len(data)
		hex_buf : [64]u8
		sha256_into(data, hex_buf[:])
		digest := string(hex_buf[:])
		delete(data)
		if got_len != v.bytes {
			bad += 1
			detail = fmt.tprintf("{} {} length {} want {};", detail, v.file, got_len, v.bytes)
		}
		if digest != v.sha256 {
			bad += 1
			detail = fmt.tprintf("{} sha256 {} want {};", detail, v.file, digest, v.sha256)
		}
	}
	support.check(t, "all 10 vendored schema files are present, right size, and hash to the recorded sha256",
		bad == 0, fmt.tprintf("{} mismatch(es) in dir '{}'{}", bad, dir, detail))
}

@(test)
vendored_schema_head_is_colors :: proc(t: ^testing.T) {
	// The recorded fact is that each file starts with the exact bytes `[colors`.
	// If a fetch ever produced an HTML error page or a README, this catches it
	// by shape before any hex comparison is even meaningful.
	dir := schema_dir()
	if len(dir) == 0 {
		support.check(t, "vendored schema dir reachable (head check)", false, "not found")
		return
	}
	bad := 0
	for v in VENDORED {
		data, err := os.read_entire_file_from_path(fmt.tprintf("{}/{}", dir, v.file), context.allocator)
		if err != nil || data == nil { bad += 1; continue }
		prefix := string(data[0:min(7, len(data))])
		delete(data)
		if prefix != "[colors" {
			bad += 1
			support.note(t, fmt.tprintf("    {}: starts with '{}' not '[colors'", v.file, prefix))
		}
	}
	support.check(t, "every vendored file starts with the exact bytes `[colors`", bad == 0,
		fmt.tprintf("{} file(s) with a different head", bad))
}

@(test)
theme_values_match_the_vendored_schema :: proc(t: ^testing.T) {
	// THE ANTI-FUDGE TEST.
	//
	// Every one of the 22 values of every compiled theme must equal the value
	// the vendored file carries for the same schema key — including the ones
	// that disagree with what this repo used to ship (nord's `primary.foreground`
	// is #d8dee9 here, not the old #e5e9f0) and including the ones that are
	// bad for legibility (solarized-dark's `bright.black` is its own page
	// colour). Adjusting a hex to make a contrast test pass is forbidden; this
	// is the check that makes it visible.
	dir := schema_dir()
	if len(dir) == 0 {
		support.check(t, "vendored schema dir reachable (value check)", false,
			fmt.tprintf("'{}' not found from CWD", SCHEMA_DIR_REL))
		return
	}
	mismatch := 0
	unread := 0
	detail := ""
	for v in VENDORED {
		th, ok := app.theme_named(v.theme)
		if !ok {
			mismatch += 1
			detail = fmt.tprintf("{} theme '{}' named in the provenance table is not shipped;", detail, v.theme)
			continue
		}
		sf := read_schema_file(fmt.tprintf("{}/{}", dir, v.file))
		if !sf.ok {
			unread += 1
			detail = fmt.tprintf("{} {}: VERIFY FAILED ({}) — nothing was compared;", detail, v.file, sf.reason)
			continue
		}
		for k in app.palette_keys() {
			got := app.theme_slot(th.pal, k)
			want := sf.values[int(k)]
			if got != want {
				mismatch += 1
				detail = fmt.tprintf("{} {} / {}: compiled {:06x}, vendored {:06x}",
					detail, v.theme, app.palette_key_name(k), got, want)
			}
		}
	}
	support.check(t, "every theme's 22 values equal the vendored schema's, key for key (220 comparisons)",
		mismatch == 0 && unread == 0,
		fmt.tprintf("{} mismatch(es), {} file(s) that failed shape verification{}", mismatch, unread, detail))
}

@(test)
vendored_schema_covers_every_shipped_theme_exactly_once :: proc(t: ^testing.T) {
	// The provenance table and the shipped set must be the same 10 themes, each
	// covered exactly once. A theme added without a vendored file (or a file
	// added without a theme) is an unprovenanced palette, which is exactly what
	// this suite exists to prevent.
	shipped := app.theme_count()
	if shipped != len(VENDORED) {
		support.check(t, "one vendored file per shipped theme", false,
			fmt.tprintf("{} shipped, {} vendored", shipped, len(VENDORED)))
		return
	}
	orphan := 0
	detail := ""
	for v in VENDORED {
		hits := 0
		for i := 0; i < shipped; i += 1 {
			if app.theme_at(i).name == v.theme { hits += 1 }
		}
		if hits != 1 {
			orphan += 1
			detail = fmt.tprintf("{} '{}' matched {} shipped theme(s);", detail, v.theme, hits)
		}
	}
	// And the reverse: every shipped theme is named.
	uncovered := 0
	for i := 0; i < shipped; i += 1 {
		named := false
		for v in VENDORED {
			if v.theme == app.theme_at(i).name { named = true }
		}
		if !named {
			uncovered += 1
			detail = fmt.tprintf("{} shipped theme '{}' has no vendored source;", detail, app.theme_at(i).name)
		}
	}
	support.check(t, "the provenance table is EXACTLY the shipped set, one file each way",
		orphan == 0 && uncovered == 0,
		fmt.tprintf("{} orphan(s), {} uncovered theme(s){}", orphan, uncovered, detail))
}

@(test)
schema_loader_seam_is_declared_and_unimplemented :: proc(t: ^testing.T) {
	// The seam is a seam, not a parser with a smile painted on it. It must
	// return the not-implemented message for ANY input — including a real
	// vendored file's contents, which is the input it would eventually have to
	// handle. If someone ships a loader under this name, they must also update
	// the docs and the hygiene guard, and this test is what forces that to be a
	// deliberate act rather than a quiet one.
	msg := "not-it"
	{
		p, err := app.theme_from_alacritty_schema("")
		msg = err
		support.check(t, "the schema seam refuses an empty document",
			err == app.Theme_Schema_Loader_Stub && p.primary.background == 0 && p.bright.white == 0,
			fmt.tprintf("err='{}'", err))
	}
	{
		_, err := app.theme_from_alacritty_schema("[colors.primary]\nforeground = \"#ebdbb2\"\n")
		support.check(t, "…and refuses a well-formed one (it is a STUB, not a partial loader)",
			err == app.Theme_Schema_Loader_Stub, fmt.tprintf("err='{}'", err))
	}
	support.check(t, "the stub message is the documented one",
		msg == app.Theme_Schema_Loader_Stub, fmt.tprintf("'{}'", msg))
}
