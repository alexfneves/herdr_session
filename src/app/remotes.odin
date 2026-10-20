package app

// Remote discovery (T3.4) — and why it is feature-gated rather than assumed.
//
// # What `machine list` is for
//
// herdr 0.9.x added a machine registry. If this build has it, one call enumerates
// every registered machine and we get remote discovery for free. If it does not,
// we fall back to the user's own remote list.
//
// # The gate is a JSON-shape check, not an exit-code check
//
// On the installed 0.8.2 there is **no `machine` command at all**. Captured this
// session:
//
//	$ herdr machine list --json
//	unknown command: machine                     # exit 2, plain text, no JSON
//
// Exit code alone cannot distinguish "subcommand does not exist" (0.8.2) from
// "subcommand exists but returned an error" (0.9.x with a broken registry), and
// both answer non-zero. Treating them alike would either hide a real registry or
// fall back to config while the registry was actually fine. So the decision is made
// on **payload shape**: the registry is available only when the payload parses as
// an object containing a `machines` array. Anything else — unknown-command text,
// an error envelope, an empty string — means unavailable.
//
// # Remotes are also fetched the long way round
//
// Whatever the registry says, listing a remote's sessions is **our own ssh**
// (`remote_list_argv` in `herdr.odin`): `herdr --remote X session list` is
// rejected outright (exit 2, "--remote can only be used with the default launch
// command"). The registry can tell us *which* hosts exist; it cannot list them
// for us.
//
// # THE MERGE RULE (RCH-2 / O13) — registry and config are SUMMED, never chosen
//
// `machine list --json` on herdr 0.9.5 answers `[]`. That is a *valid* answer,
// and it is the dangerous one: a gate that reads "registry available, zero
// machines" and returns the empty set would silently drop every host the user
// wrote into `herdr_session.json`. Nothing on screen would say so — the device
// list would just be shorter than the config.
//
// So `discover_resolved` never picks a winner. It reads the registry, reads the
// config, and returns the UNION of the two, de-duplicated on the VERBATIM device
// string. There is no code path in this file that can produce "registry said X,
// therefore not-X": the only way a configured remote disappears is if it is
// literally `local` (which is implicit in the table) or not a valid target at
// all, and both are reported.
//
// The registry answer is also SHAPE-flexible, because we do not own its schema and
// 0.9.5 proved that: it returns a **bare JSON array** (`[]`), while the shape
// documented earlier in this project was an object with a `machines` array. Both
// parse. What still does NOT parse is 0.8.2's plain-text `unknown command: machine`
// on stdout with exit 0 — a help banner is not a registry, and exit code alone
// cannot tell them apart. That is why the gate is a shape check.
//
// # Config injection is temporary by design
//
// `config_remotes` is passed in rather than loaded here. T6.1 replaced the
// argument with a real config loader; until then no fixture value is baked into
// product code, so `HERDR_SESSION_TEST_REMOTE` cannot leak into a shipped binary.

import json "core:encoding/json"
import "core:fmt"
import "core:strings"

//-----------------------------------------------------------------------------
// Remote description
//-----------------------------------------------------------------------------

// Remote is one ssh target we know about.
//
// `device` is the VERBATIM configured string. It is used unchanged for the
// identity key, for `ssh -T <device>`, and for `herdr --remote <device>` — any
// normalisation (strip user, resolve alias, lower-case) breaks at least one of
// those three, so it is forbidden.
Remote :: struct {
	device : string,
	label  : string, // display name; falls back to `device` when empty
}

remote_label :: proc(r: Remote) -> string {
	if r.label != "" { return r.label }
	return r.device
}

// remote_invalid_reason says, in words a user can act on, why a target is
// refused. "" means the target is usable. One source for the rule and the
// sentence, so the footer can never disagree with the gate.
//
// The leading-`-` rule is OPTION INJECTION, not tidiness. The device travels as
// an operand of `ssh -T ... <device> '<cmd>'` (remote_list_argv, control_argv)
// and of `herdr --remote <device> ...` (launch_argv). A target that begins with
// `-` is read by the transport as an OPTION instead of a host:
//
//	-F/tmp/evil       -> ssh reads an attacker-chosen config file, which
//	                 REPLACES BatchMode=yes / ConnectTimeout=5 with whatever
//	                 that file says. Every D5 guarantee is then void.
//	-oProxyCommand=.. -> arbitrary command run by the transport itself.
//
// This is LAYER ONE. Layer two is the `--` terminator in SSH_BASE_ARGS, which
// makes the transport unable to be hijacked even if this check is ever bypassed
// (see the measured proof on that constant). Refusing the input is the polite
// layer; the terminator is the load-bearing one.
//
// The class is closed at validation rather than by quoting, because the same
// string has to work as an ssh operand, as `--remote`'s value and as a registry
// key, and no single escape fixes all three. A device starting with `-` is not a
// host anybody typed on purpose. `alice@host` mid-string stays legal.
remote_invalid_reason :: proc(r: Remote) -> string {
	if len(r.device) == 0 { return "empty device" }
	if r.device[0] == '-' {
		return fmt.tprintf(
			"device '{}' starts with '-' and would be read by ssh / herdr as an OPTION, not a host - refused",
			r.device)
	}
	for b in transmute([]byte)(r.device) {
		if b == ' ' || b == '\t' || b == '\n' || b == 0 {
			return fmt.tprintf("device '{}' contains whitespace - refused", r.device)
		}
	}
	return ""
}

// remote_is_valid rejects empty, whitespace-laden and option-looking targets
// before they become argv. This is *not* the session-name charset rule — ssh
// targets legitimately contain `@` and `:`, which session names may not.
remote_is_valid :: proc(r: Remote) -> bool {
	return remote_invalid_reason(r) == ""
}

//-----------------------------------------------------------------------------
// `herdr machine list --json`
//-----------------------------------------------------------------------------

// Raw_Machine accepts every key spelling a registry entry might use. The registry
// shape is not fixed by any contract we control, and herdr has not shipped it in
// the build installed here, so the field set is deliberately generous: an
// unrecognised key is simply not read, and the precedence chain below picks the
// first non-empty candidate for the device string.
// Raw_Machine is deliberately permissive about which key carries the device, and
// that tolerance is load-bearing rather than speculative in exactly one
// direction: herdr's registry shape has changed once already between the 0.8.x
// and 0.9.x generations this app has to run against, and it was observed as an
// EMPTY registry on this box — so the non-empty spelling is genuinely not known
// from direct experience. Keeping the accept-set wide is what stops "we have not
// seen a non-empty registry" from turning into "a real one gets dropped in
// silence". What got DROPPED here is the speculative machinery that bought
// nothing: `Raw_Machine_List` (see `parse_machine_list`, which reads both the
// bare-array and the `machines`-object shape without a wrapper struct) and the
// per-entry re-parse of the payload just to count provenance.
Raw_Machine :: struct {
	name       : string,
	label      : string,
	host       : string,
	alias      : string,
	id         : string  `json:"id"`,
	ssh_target : string `json:"ssh_target"`,
	target     : string `json:"target"`,
}

// Machine_Source says where the remote list came from, which the UI shows and the
// evidence logs need in order to prove the gate behaved as designed.
//
// It describes the REGISTRY's answer, not the merge: the merged `remotes` always
// carry the configured hosts too, and `Discovery.from_config` / `from_registry`
// are the counts that prove it. `.registry` therefore does NOT mean "the config
// was consulted and discarded" — it never is.
Machine_Source :: enum {
	not_probed,      // we have not asked yet
	registry,        // `machine list` answered with a registry shape
	merged,          // registry shape AND configured remotes both contributed
	config_fallback, // no registry (0.8.2), or it answered with the wrong shape
}

machine_source_label :: proc(s: Machine_Source) -> string {
	#partial switch s {
	case .not_probed:      return "not probed"
	case .registry:        return "herdr machine registry"
	case .merged:          return "registry + configured remotes"
	case .config_fallback: return "configured remotes"
	}
	return "configured remotes"
}

// machine_registry_available is THE GATE.
//
// True when `payload` has a *registry shape*, which is either:
//
//   * a bare JSON array            — what herdr 0.9.5 actually returns (`[]`)
//   * an object with a `machines` array — the shape documented in this project
//     before 0.9.5 could be observed non-empty
//
// deliberately ignores the exit code that produced the payload: the shape is the
// evidence, so "unknown command: machine" (0.8.2) and a malformed registry
// response (0.9.x) both read as unavailable, while a well-formed registry reads
// as available even if some individual entries are unusable — or if it is EMPTY.
//
// An EMPTY registry reads as available. That is not sloppiness: "no machines
// registered" is a true answer about the registry, and `discover_resolved` sums
// it with the config rather than stopping at it. The failure O13 guards against
// is exactly the version where an empty array is treated as "nothing to do".
machine_registry_available :: proc(payload: []byte) -> bool {
	if _, ok := registry_entries(payload); ok { return true }
	return registry_object_has_machines(payload)
}

// registry_entries returns the machine array when the payload IS a bare array
// (0.9.5's shape). Returns ok=false for anything that is not an array, so the
// caller can fall through to the object shape.
registry_entries :: proc(payload: []byte) -> (json.Array, bool) {
	if len(payload) == 0 { return json.Array{}, false }
	v, err := json.parse_bytes(payload)
	if err != nil { return json.Array{}, false }
	arr, is_arr := v.(json.Array)
	return arr, is_arr
}

// registry_object_has_machines is the pre-observed shape: {"machines": [...]}
registry_object_has_machines :: proc(payload: []byte) -> bool {
	if len(payload) == 0 { return false }
	v, err := json.parse_bytes(payload)
	if err != nil { return false }
	obj, is_obj := v.(json.Object)
	if !is_obj { return false }
	arr, has := obj["machines"]
	if !has { return false }
	_, is_arr := arr.(json.Array)
	return is_arr
}

// machine_array_of returns whichever array the registry used, in the shape the
// rest of this file parses. Centralised so a third shape has exactly one place
// to be added.
machine_array_of :: proc(payload: []byte) -> json.Array {
	if arr, ok := registry_entries(payload); ok { return arr }
	empty := json.Array{}
	if len(payload) == 0 { return empty }
	v, err := json.parse_bytes(payload)
	if err != nil { return empty }
	obj, is_obj := v.(json.Object)
	if !is_obj { return empty }
	mv, has := obj["machines"]
	if !has { return empty }
	arr, is_arr := mv.(json.Array)
	if !is_arr { return empty }
	return arr
}

// parse_machine_list turns a registry payload into remotes. Entries with no usable
// device string are skipped rather than failing the whole list: one bad registry
// entry must not cost us the other hosts.
//
// Reads through `machine_array_of` so both registry shapes (bare array, and the
// `{machines:[...]}` object) go down the same code path — one place to add a
// third, and no chance of the two shapes disagreeing about what a machine is.
parse_machine_list :: proc(payload: []byte) -> (remotes: []Remote, ok: bool) {
	arr := machine_array_of(payload)
	out := make([dynamic]Remote, 0, len(arr))
	for item in arr {
		m, is_obj := item.(json.Object)
		if !is_obj { continue }
		// Precedence: the explicit ssh target wins (it is what `--remote` needs),
		// then host/name/alias. Never synthesised, never rewritten.
		r := Remote{device = json_str(m, "ssh_target"), label = json_str(m, "label")}
		if r.device == "" { r.device = json_str(m, "target") }
		if r.device == "" { r.device = json_str(m, "host") }
		if r.device == "" { r.device = json_str(m, "name") }
		if r.device == "" { r.device = json_str(m, "alias") }
		if r.label == "" { r.label = r.device }
		// A DISABLED machine is not a remote we should reach for. Only an explicit
		// `"enabled": false` skips it: absent means enabled, so a registry that
		// does not carry the key at all (the shape this project was written
		// against) still works.
		if !json_enabled(m) { continue }
		if !remote_is_valid(r) { continue }
		append(&out, r)
	}
	return out[:], true
}

// json_str reads one string field, or "" if it is missing or not a string.
// Written out because the assert-and-default idiom otherwise repeats eight times.
json_str :: proc(o: json.Object, key: string) -> string {
	v, has := o[key]
	if !has { return "" }
	s, is_str := v.(json.String)
	if !is_str { return "" }
	return string(s)
}

// json_enabled: absent -> true. Only `false` (or the strings "false"/"0",
// because a registry that serialises booleans as strings would otherwise have
// every machine silently dropped and nothing on screen would say why) is off.
json_enabled :: proc(o: json.Object) -> bool {
	v, has := o["enabled"]
	if !has { return true }
	if b, is_b := v.(json.Boolean); is_b { return bool(b) }
	if s, is_s := v.(json.String); is_s {
		low := strings.to_lower(string(s))
		if low == "false" || low == "0" || low == "off" { return false }
	}
	if i, is_i := v.(json.Integer); is_i { return int(i) != 0 }
	return true
}

//-----------------------------------------------------------------------------
// Discovery
//-----------------------------------------------------------------------------

// Discovery holds the resolved remote set plus how it was obtained.
//
// `from_registry` and `from_config` are not decoration. They are the numbers that
// distinguish "the registry was empty and the config carried the hosts" from
// "nothing was configured" from "the registry answered and the config added
// more" — and O13's failure mode (an empty registry swallowing the config) is
// exactly the thing a caller must be able to see without re-deriving it.
Discovery :: struct {
	remotes  : []Remote,      // never includes DEVICE_LOCAL
	source   : Machine_Source,
	registry : bool,          // the registry answered with a real shape
	note     : string,        // what we saw, for the status line / evidence
	from_registry : int,      // merged entries that came from the registry
	from_config   : int,      // merged entries that came from `config_remotes`
	skipped     : int,        // registry entries dropped (invalid / disabled)
}

// machine_probe_argv is the feature probe. Run once at startup and cached — not on
// every refresh — because on 0.8.2 it is a guaranteed error path and paying it per
// refresh buys nothing.
machine_probe_argv :: proc() -> []string {
	argv := make([dynamic]string, 0, 4)
	append(&argv, HERDR_BIN, "machine", "list", "--json")
	return argv[:]
}

// discover_resolved is the seam T4.1 calls, and the one place the O13 merge rule
// lives.
//
// `probe` is the raw payload of `machine list --json` (stdout only — a non-zero
// exit is passed as an empty payload so it reads as "no registry"), and
// `config_remotes` is what the user configured.
//
// THE RULE: the result is the UNION, never the choice.
//
//   remotes = registry_entries ∪ config_remotes   (deduped on VERBATIM device)
//
// Registry entries first, so a registry `label` wins a collision with a bare
// config target — the registry knows the machine, the config only knows how to
// dial it. Nothing else about the merge can lose information:
//
//   * registry empty (`[]`, today's herdr)   -> the configured remotes stand
//   * config empty, registry full           -> the registry's hosts stand
//   * both empty                             -> an empty set, said out loud
//   * registry unavailable (0.8.2)         -> the configured remotes stand
//
// The reason this is a union rather than "registry wins when present": the
// registry's emptiness is a statement about HERDR's saved-machine list, not about
// the user's intent. Treating it as authority would drop configured hosts with no
// message anywhere — the specific silent failure O13 exists to prevent.
//
// DEVICE_LOCAL is never part of this list — the local group is implicit in the
// table and adding it here would double it.
discover_resolved :: proc(probe: []byte, config_remotes: []Remote) -> Discovery {
	valid := make([dynamic]Remote, 0, len(config_remotes) + 1)
	for r in config_remotes {
		if is_local_device(r.device) { continue }
		if !remote_is_valid(r) { continue }
		append(&valid, r)
	}

	available := machine_registry_available(probe)
	merged := make([dynamic]Remote, 0, len(valid) + 4)
	seen := make(map[string]bool)
	note := ""
	regs_skipped := 0
	n_from_registry := 0

	if available {
		all := machine_array_of(probe)
		regs, _ := parse_machine_list(probe)
		for r in regs {
			key := strings.to_lower(r.device)
			if seen[key] { continue }
			seen[key] = true
			append(&merged, r)
			// Counted HERE, during the pass that already has the parsed registry.
			// The previous version re-derived this by calling `registry_has_device`
			// once per merged entry, and that helper re-parsed the whole payload
			// every time — O(n²) JSON on a number we could have had for free from
			// the loop we were already running.
			n_from_registry += 1
		}
		regs_skipped = len(all) - len(regs)
		note = fmt.tprintf("machine registry: {} of {} entr(y/ies) usable", len(regs), len(all))
	} else {
		note = "no machine registry in this herdr — configured remotes only"
	}

	// The config pass. This runs whether or not the registry answered, and that
	// single line is the whole of O13.
	for r in valid {
		key := strings.to_lower(r.device)
		if seen[key] { continue }
		seen[key] = true
		append(&merged, r)
	}

	n_from_config := len(merged) - n_from_registry

	src := Machine_Source.config_fallback
	if available && n_from_registry > 0 && n_from_config > 0 { src = .merged }
	if available && n_from_registry > 0 && n_from_config == 0 { src = .registry }

	return Discovery{
		remotes       = merged[:],
		source        = src,
		registry      = available,
		note          = note,
		from_registry = n_from_registry,
		from_config   = n_from_config,
		skipped       = regs_skipped,
	}
}

// registry_has_device answers whether a merged entry came from the registry, by
// the VERBATIM device string. Kept for callers outside discover_resolved; note
// that it re-parses per call, which is why discover_resolved no longer uses it
// in a loop (see the counting comment there).
registry_has_device :: proc(probe: []byte, device: string) -> bool {
	regs, _ := parse_machine_list(probe)
	for r in regs {
		if r.device == device { return true }
	}
	return false
}

// devices_for_table projects a Discovery into the table's device groups, with the
// implicit local group first.
devices_for_table :: proc(d: Discovery) -> []Device {
	out := make([dynamic]Device, 0, len(d.remotes) + 1)
	append(&out, Device{target = DEVICE_LOCAL, label = DEVICE_LOCAL, status = .pending})
	for r in d.remotes {
		append(&out, Device{target = r.device, label = remote_label(r), status = .pending})
	}
	return out[:]
}
