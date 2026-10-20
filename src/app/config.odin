package app

// ============================================================================
// app.config — JSON configuration at ~/.config/herdr_session.json (T6.1)
//
// # FORMAT: JSON. No TOML, no XDG library.
//
// Plan D13: `core:encoding/json` for parsing and `os.user_config_dir()` for the
// location. That stdlib proc already implements the XDG Base Directory rule —
// core/os/user_posix.odin:17 reads $XDG_CONFIG_HOME and falls back to
// $HOME/.config — so an XDG package would duplicate ~40 lines of stdlib for
// nothing, and a TOML parser is not even available in this build.
//
// The parser's default spec is JSON5 (types.odin:57), which means a hand-edited
// file with `// comments` or a trailing comma still loads. That is a feature for
// a file people edit by hand, and it is noted here because it is NOT strict JSON.
//
// # THE CONTRACT: A BAD CONFIG MUST NEVER BRICK THE APP
//
// `config_load` has no error return. Every failure mode is absorbed and reported
// as a string the footer can show:
//
//   missing file        -> defaults, SILENT (a first run is not an error)
//   unreadable file     -> defaults + one warning line
//   unparseable JSON    -> defaults + one warning line                (ISC-19)
//   unknown theme name  -> gruvbox-dark + one warning line           (ISC-19)
//   wrong-typed key     -> that key ignored + one warning line
//   unknown EXTRA key   -> ignored, SILENT, and PRESERVED on save
//
// The threat model is a config file hand-edited at 2am by someone who is
// already annoyed. A missing bracket must not cost them their session list. The
// price of that decision is that errors must be SHOWN rather than thrown, which
// is what `Config.warnings` is for: the footer puts the first one where the user
// will actually see it.
//
// # WRITE-BACK RULE: we own three keys, and only three
//
// A save is a READ-MODIFY-WRITE of the parsed document:
//
//   1. read + parse the current file (if it parses)
//   2. set OUR keys: theme / remotes / cleanup_policy
//   3. marshal the WHOLE object back out
//
// `json.Object` IS the parsed document, so step 3 carries every key we do not
// understand straight through. Hand-added keys survive a save — proven by the
// smoke check `theme-save-preserves-keys`.
//
// Two deliberate consequences:
//   * An unparseable file CANNOT be preserved. The first save writes a document
//     containing only our keys; the warning already said the file was invalid.
//     Nothing quieter is honest about that.
//   * We do not delete a key just because it holds the default value. `theme`
//     stays in the file even when it is gruvbox-dark, because the file is the
//     user's record of what they chose. Absent and explicit-but-default stay
//     distinguishable, which is also why theme_resolve returns a kind.
//
// # WHAT LIVES WHERE
//
//   theme.odin    what a theme name means, and its colours
//   config.odin   bytes on disk <-> a Config value, both directions
//   main.odin     when to read it, when to write it, where to show the warning
//
// Config calls nothing in the theme module beyond `theme_resolve` /
// `Unknown_Theme_Message`, so a change to the palette list does not ripple into
// the parser.
// ============================================================================

import json "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

//-----------------------------------------------------------------------------
// Names and paths
//-----------------------------------------------------------------------------

// CONFIG_FILE_NAME: one readable file the user can cat. No extension
// negotiation, no directory of fragments.
CONFIG_FILE_NAME :: "herdr_session.json"

// CONFIG_DIR_MODE is 0o755-equivalent, and the execute bit is NOT decoration:
// a directory without +x cannot be traversed, so a config dir created rw- only
// turns EVERY save inside it into EACCES. The first version of this used
// Read_All+Write_All and every single write failed with "permission denied" on a
// directory we had just created ourselves.
CONFIG_DIR_MODE :: os.Permissions_Read_All + os.Permissions_Write_All + os.Permissions_Execute_All

// config_path resolves the file the plan specifies:
//   $XDG_CONFIG_HOME/herdr_session.json   when XDG_CONFIG_HOME is set
//   $HOME/.config/herdr_session.json      otherwise
//
// Every test points XDG_CONFIG_HOME at a temp dir, because the alternative is a
// smoke suite that edits the developer's real config.
config_path :: proc() -> (string, os.Error) {
	dir, err := os.user_config_dir(context.allocator)
	if err != nil { return "", err }
	return join_path(dir, CONFIG_FILE_NAME), nil
}

// join_path: the stdlib's path helpers are platform-gated in this build, so the
// POSIX join is spelled out here.
//
// TRAP: Odin's `+` on two dynamic strings does not compile — "String
// concatenation is only allowed with constant strings". Use fmt.tprintf (or
// strings.concatenate) for anything built at runtime.
join_path :: proc(dir, name: string) -> string {
	if len(dir) == 0 { return name }
	if dir[len(dir)-1] == '/' { return fmt.tprintf("%s%s", dir, name) }
	return fmt.tprintf("%s/%s", dir, name)
}

//-----------------------------------------------------------------------------
// The value
//-----------------------------------------------------------------------------

// Config is what was on disk, plus what we had to say about it.
//
// It is a RECORD OF A LOAD, not a live handle: mutating it does not change the
// file. Writes go through config_save_*, which re-read first. That is
// intentional — a Config that cached its own document invites a later refactor
// to write the cache instead of merging, and that is how a user's hand-added
// keys get eaten.
Config :: struct {
	// --- owned keys, normalised -----------------------------------------
	theme          : string,   // always a RESOLVED name (never a typo)
	remotes        : []Remote, // verbatim ssh targets from `remotes`
	cleanup_policy : string,   // "never" | "only_created" | "always"

	// --- provenance ------------------------------------------------------
	path            : string, // where this came from, for messages ("" if none)
	present         : bool,   // the file existed
	corrupt         : bool,   // existed but could not be read as JSON
	theme_fell_back : bool,   // `theme` was present but unknown (ISC-19)

	// --- what the user has to be told -----------------------------------
	warnings : [dynamic]string,
}

// config_new_defaults: what the app runs on with no configuration at all.
// gruvbox-dark (D4), no remote hosts, cleanup "never" (D2).
config_new_defaults :: proc() -> Config {
	// Assigned to a name, then returned: a bare `return Config{...}` is
	// rejected for a struct containing slices ("unsafe to return a compound
	// literal of a slice ... uses the current stack frame's memory").
	out : Config
	out.theme = THEME_DEFAULT_NAME
	out.cleanup_policy = CLEANUP_LABEL_NONE
	return out
}

// config_warning_text is the ONE line the footer shows: the first warning, or "".
//
// One line, not all of them: the footer is one row tall, and four simultaneous
// warnings about one bad file read as a stack trace. The full list stays on the
// Config for a future `:config` view.
config_warning_text :: proc(c: Config) -> string {
	if len(c.warnings) == 0 { return "" }
	return c.warnings[0]
}

config_add_warning :: proc(c: ^Config, msg: string) {
	append(&c.warnings, msg)
}

//-----------------------------------------------------------------------------
// Parse (pure: takes text, no filesystem)
//-----------------------------------------------------------------------------

// config_parse_json turns the CONTENTS of the file into a Config.
//
// `text` == "" means "no file": defaults, present=false, no warnings. Anything
// else that does not parse is `corrupt`.
//
// Kept separate from config_load so the smoke suite can feed it arbitrary bytes
// without touching a disk, and so the "what does a bad value do" table is
// auditable in one screen.
config_parse_json :: proc(text: string, path: string) -> Config {
	out := config_new_defaults()
	out.path = path

	// Missing/blank file: silent defaults. First run, and the most common state.
	if len(strings.trim_space(text)) == 0 {
		return out
	}
	out.present = true

	// parse_integers=true so "5" is an Integer rather than a Float. We do not
	// read numbers today, but letting 5 become 5.0 is how a config ends up
	// re-serialising as "5.0000000000000000" (seen in this very parser).
	val, perr := json.parse_bytes(transmute([]byte)(text), json.DEFAULT_SPECIFICATION, true)
	if perr != json.Error.None {
		out.corrupt = true
		config_add_warning(&out, fmt.tprintf(
			"config %s is not valid JSON (%v) - defaults in use", path, perr))
		return out
	}

	obj, is_obj := val.(json.Object)
	if !is_obj {
		out.corrupt = true
		config_add_warning(&out, fmt.tprintf(
			"config %s must be a JSON object - defaults in use", path))
		return out
	}

	// --- theme ----------------------------------------------------------
	// present and known   -> use it
	// present and unknown -> gruvbox-dark + warning  (ISC-19)
	// absent              -> gruvbox-dark, silent    (D4)
	if v, found := obj["theme"]; found {
		name, is_str := v.(json.String)
		if !is_str {
			config_add_warning(&out, "config key 'theme' is not a string - ignored")
		} else if len(strings.trim_space(string(name))) == 0 {
			// An explicit "" is treated as absent: the user cleared it, and
			// there is nothing to warn about.
		} else {
			t, kind := theme_resolve(string(name))
			out.theme = t.name
			if kind == .fell_back {
				out.theme_fell_back = true
				config_add_warning(&out, Unknown_Theme_Message(string(name)))
			}
		}
	}

	// --- remotes (this is the product-side source of hosts: the O7 seam) --
	if v, found := obj["remotes"]; found {
		arr, is_arr := v.(json.Array)
		if !is_arr {
			config_add_warning(&out, "config key 'remotes' is not an array - ignored")
		} else {
			hosts, notes := parse_remotes(arr)
			out.remotes = hosts
			for n in notes { config_add_warning(&out, n) }
		}
	}

	// --- cleanup_policy --------------------------------------------------
	if v, found := obj["cleanup_policy"]; found {
		pol, is_str := v.(json.String)
		if !is_str {
			config_add_warning(&out, "config key 'cleanup_policy' is not a string - ignored")
		} else if !cleanup_policy_valid(string(pol)) {
			config_add_warning(&out, fmt.tprintf(
				"unknown cleanup_policy '%s' - using %s", string(pol), CLEANUP_LABEL_NONE))
		} else {
			out.cleanup_policy = string(pol)
		}
	}

	// Anything else in the object is left exactly as it is: not read, not
	// warned about, and carried through the save path untouched.
	return out
}

// parse_remotes reads the `remotes` array.
//
// Two accepted shapes, because a list of ssh targets is usually written as
// strings and sometimes needs a display name:
//
//   "remotes": ["build-box", "deploy@10.0.0.7"]
//   "remotes": [{"target": "build-box", "label": "Build box"}]
//
// Both land in the []Remote the discovery layer already consumes, and `target`
// is handed to ssh VERBATIM: the remote contract is "the value is the ssh
// target, exactly as typed" (remotes.odin:212), and a config layer that
// rewrites a target is a config layer that breaks a host nobody typed.
parse_remotes :: proc(arr: json.Array) -> ([]Remote, []string) {
	out := make([dynamic]Remote, 0, len(arr))
	notes := make([dynamic]string, 0, 2)
	seen := make([dynamic]string, 0, len(arr))

	for item in arr {
		target := ""
		label := ""
		// NB: one name per binding. The build treats shadowing as an error, so
		// `ok`/`s` cannot be reused across this else-if chain.
		if sv, is_sv := item.(json.String); is_sv {
			target = string(sv)
		} else if ov, is_ov := item.(json.Object); is_ov {
			if tv, has_t := ov["target"]; has_t {
				if ts, is_ts := tv.(json.String); is_ts { target = string(ts) }
			}
			if lv, has_l := ov["label"]; has_l {
				if ls, is_ls := lv.(json.String); is_ls { label = string(ls) }
			}
		} else {
			// One unreadable entry must not cost the user the other three.
			append(&notes, "config: a 'remotes' entry is neither a string nor an object - skipped")
			continue
		}

		target = strings.trim_space(target)
		if len(target) == 0 { continue }
		// The local device is discovery's, never the config's: a hand-added
		// "local" entry must not produce two rows for one device.
		if target == DEVICE_LOCAL { continue }

		dup := false
		for sv in seen { if sv == target { dup = true } }
		if dup { continue }
		append(&seen, target)

		r := Remote{device = target}
		if len(strings.trim_space(label)) > 0 { r.label = strings.trim_space(label) }
		append(&out, r)
	}
	return out[:], notes[:]
}

//-----------------------------------------------------------------------------
// Load (filesystem)
//-----------------------------------------------------------------------------

// config_load reads the config file. No error return, by design — see the header
// contract. A caller gets a usable Config every time.
config_load :: proc() -> Config {
	path, perr := config_path()
	if perr != nil {
		// No HOME and no XDG_CONFIG_HOME: run on defaults, and say why there is
		// nowhere to save to (an unexplainable save failure is worse than one the
		// user can read off the footer).
		out := config_new_defaults()
		config_add_warning(&out, fmt.tprintf(
			"no config directory (%v) - defaults in use, nothing to save to",
			os.error_string(perr)))
		return out
	}

	if !os.is_file(path) {
		// Missing == first run: silent.
		out := config_new_defaults()
		out.path = path
		return out
	}

	bytes, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		out := config_new_defaults()
		out.path = path
		out.corrupt = true
		config_add_warning(&out, fmt.tprintf("cannot read config %s (%v) - defaults in use",
			path, os.error_string(rerr)))
		return out
	}
	defer mem.free_bytes(bytes, context.allocator)

	return config_parse_json(string(bytes), path)
}

//-----------------------------------------------------------------------------
// Save
//-----------------------------------------------------------------------------

// doc_for_write returns the JSON object a save starts from.
//
// It REREADS rather than trusting any cached copy. That costs one read per save
// and buys two things: keys the user added *after* the app started still survive,
// and an unparseable file is noticed at save time rather than silently replaced.
// has_doc=false means "nothing to merge into".
doc_for_write :: proc(path: string) -> (json.Object, bool) {
	if path == "" || !os.is_file(path) { return json.Object{}, false }
	bytes, err := os.read_entire_file(path, context.allocator)
	if err != nil { return json.Object{}, false }
	defer mem.free_bytes(bytes, context.allocator)
	if len(strings.trim_space(string(bytes))) == 0 { return json.Object{}, false }
	val, perr := json.parse_bytes(bytes, json.DEFAULT_SPECIFICATION, true)
	if perr != json.Error.None { return json.Object{}, false }
	obj, ok := val.(json.Object)
	return obj, ok
}

// TRAP: Odin params are immutable bindings, so a *by-value* distinct map cannot
// be assigned into ("Cannot assign to the value of a map"). Take ^Object and
// index through `obj^` — there is no unary `*` in Odin.
doc_set_string :: proc(obj: ^json.Object, key, value: string) {
	// Index through the deref. DO NOT "simplify" this to
	// `cast(map[string]json.Value)obj^`: that compiles and runs but writes into
	// a detached copy, so the key never reaches the document and a theme save
	// silently produced `{}`.
	obj^[key] = json.String(value)
}

doc_set_string_list :: proc(obj: ^json.Object, key: string, items: []string) {
	dv := make([dynamic]json.Value, 0, len(items))
	for s in items { append(&dv, json.String(s)) }
	obj^[key] = json.Array(dv)
}

// config_save_theme persists the applied theme. This is the ISC-7 write path.
//
// Merging is not optional: marshalling a Config back out would write only the
// keys we know and silently delete whatever else the user put in the file.
config_save_theme :: proc(path: string, theme_name: string) -> (bool, string) {
	if path == "" { return false, "no config path (no XDG_CONFIG_HOME and no HOME)" }
	obj, ok := doc_for_write(path)
	// TRAP: `json.Object{}` is a NIL map. Assigning into a nil distinct-map is a
	// silent no-op here — the save "succeeded" and wrote `{}`, which is how a
	// theme change vanished on a first run. `make` is not optional.
	if !ok { obj = make(json.Object) }
	doc_set_string(&obj, "theme", theme_name)
	return write_doc(path, obj)
}

// config_save_remotes persists the configured host list (verbatim targets).
config_save_remotes :: proc(path: string, remotes: []Remote) -> (bool, string) {
	if path == "" { return false, "no config path (no XDG_CONFIG_HOME and no HOME)" }
	obj, ok := doc_for_write(path)
	// TRAP: `json.Object{}` is a NIL map. Assigning into a nil distinct-map is a
	// silent no-op here — the save "succeeded" and wrote `{}`, which is how a
	// theme change vanished on a first run. `make` is not optional.
	if !ok { obj = make(json.Object) }
	targets := make([dynamic]string, 0, len(remotes))
	for r in remotes { append(&targets, r.device) }
	doc_set_string_list(&obj, "remotes", targets[:])
	return write_doc(path, obj)
}

// config_save_cleanup persists the cleanup policy.
config_save_cleanup :: proc(path: string, policy: string) -> (bool, string) {
	if path == "" { return false, "no config path (no XDG_CONFIG_HOME and no HOME)" }
	obj, ok := doc_for_write(path)
	// TRAP: `json.Object{}` is a NIL map. Assigning into a nil distinct-map is a
	// silent no-op here — the save "succeeded" and wrote `{}`, which is how a
	// theme change vanished on a first run. `make` is not optional.
	if !ok { obj = make(json.Object) }
	doc_set_string(&obj, "cleanup_policy", policy)
	return write_doc(path, obj)
}

// write_doc serialises and replaces the file via a temp file + os.rename.
//
// Why: rename is atomic within a filesystem, so a crash mid-write leaves the
// PREVIOUS file intact. The alternative (truncate and write) makes a crash a
// `corrupt` config — survivable, but "nothing happened" beats "your config is
// gone and here is a warning about it".
//
// Pretty + sorted keys is also deliberate: a config that is diffable and has a
// stable key order is one a human will keep editing.
write_doc :: proc(path: string, obj: json.Object) -> (bool, string) {
	opts := json.Marshal_Options{
		pretty           = true,
		use_spaces       = true,
		spaces           = 2,
		sort_maps_by_key = true,
	}
	bytes, err := json.marshal(obj, opts, context.allocator)
	if err != nil {
		return false, fmt.tprintf("cannot encode config: %v", err)
	}
	defer mem.free_bytes(bytes, context.allocator)

	dir := path_dir(path)
	if len(dir) > 0 && !os.is_dir(dir) {
		if derr := os.mkdir_all(dir, CONFIG_DIR_MODE); derr != nil {
			return false, fmt.tprintf("cannot create %s: %v", dir, os.error_string(derr))
		}
	}

	tmp := join_path(dir, fmt.tprintf("%s.tmp", path_base(path)))
	if werr := os.write_entire_file_from_string(tmp, string(bytes)); werr != nil {
		return false, fmt.tprintf("cannot write %s: %v", tmp, os.error_string(werr))
	}
	if os.is_file(path) {
		if rm := os.remove(path); rm != nil {
			return false, fmt.tprintf("cannot replace %s: %v", path, os.error_string(rm))
		}
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		return false, fmt.tprintf("cannot move %s into place: %v", tmp, os.error_string(rerr))
	}
	return true, ""
}

// path_dir / path_base: spelled out because the stdlib helpers are
// platform-gated in this build.
path_dir :: proc(p: string) -> string {
	i := last_index_of_byte(p, '/')
	if i < 0 { return "." }
	if i == 0 { return "/" }
	return p[:i]
}

path_base :: proc(p: string) -> string {
	i := last_index_of_byte(p, '/')
	if i < 0 { return p }
	return p[i+1:]
}

last_index_of_byte :: proc(s: string, b: byte) -> int {
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == b { return i }
	}
	return -1
}

//-----------------------------------------------------------------------------
// Cleanup policy (D2) — config label <-> Cleanup_Policy enum
//-----------------------------------------------------------------------------

CLEANUP_LABEL_NONE  :: "never"
CLEANUP_LABEL_OWNED :: "only_created"
CLEANUP_LABEL_ALL   :: "always"

// cleanup_policy_valid is the accepted set. An unknown value gets a warning
// rather than a silent fallback: a user who writes "on" and silently gets
// "never" destroys nothing, but will also wonder why the app ignores them, and
// that is worth one line in the footer.
cleanup_policy_valid :: proc(label: string) -> bool {
	return label == CLEANUP_LABEL_NONE || label == CLEANUP_LABEL_OWNED || label == CLEANUP_LABEL_ALL
}

// cleanup_policy_from_name maps the config string onto the Cleanup_Policy enum
// the state machine and executor use. Unknown -> .never, the safe one; the
// warning is emitted at the parse site, not here, so this stays a pure map.
cleanup_policy_from_name :: proc(label: string) -> Cleanup_Policy {
	switch label {
	case CLEANUP_LABEL_NONE:  return .never
	case CLEANUP_LABEL_OWNED: return .only_created
	case CLEANUP_LABEL_ALL:   return .always
	}
	return .never
}

// cleanup_policy_config_label is the config-side spelling of an enum value, so
// the file round-trips. The executor has its own `cleanup_policy_label` for
// notice text; keeping this separate means neither can silently change the
// string the other parses, and the smoke suite asserts they agree.
cleanup_policy_config_label :: proc(p: Cleanup_Policy) -> string {
	#partial switch p {
	case .never:        return CLEANUP_LABEL_NONE
	case .only_created: return CLEANUP_LABEL_OWNED
	case .always:       return CLEANUP_LABEL_ALL
	}
	return CLEANUP_LABEL_NONE
}
