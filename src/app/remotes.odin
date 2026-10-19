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
// # Config injection is temporary by design
//
// `config_remotes` is passed in rather than loaded here. T6.1 replaces the
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

// remote_is_valid rejects empty and whitespace-laden targets before they become
// argv. This is *not* the session-name charset rule — ssh targets legitimately
// contain `@` and `:`, which session names may not.
remote_is_valid :: proc(r: Remote) -> bool {
	if len(r.device) == 0 { return false }
	for b in transmute([]byte)(r.device) {
		if b == ' ' || b == '\t' || b == '\n' || b == 0 { return false }
	}
	return true
}

//-----------------------------------------------------------------------------
// `herdr machine list --json`
//-----------------------------------------------------------------------------

// Raw_Machine accepts every key spelling a registry entry might use. The registry
// shape is not fixed by any contract we control, and herdr has not shipped it in
// the build installed here, so the field set is deliberately generous: an
// unrecognised key is simply not read, and the precedence chain below picks the
// first non-empty candidate for the device string.
Raw_Machine :: struct {
	name       : string,
	label      : string,
	host       : string,
	alias      : string,
	id         : string  `json:"id"`,
	ssh_target : string  `json:"ssh_target"`,
}

Raw_Machine_List :: struct {
	machines : []Raw_Machine,
}

// Machine_Source says where the remote list came from, which the UI shows and the
// evidence logs need in order to prove the gate behaved as designed.
Machine_Source :: enum {
	not_probed,        // we have not asked yet
	registry,        // `machine list` answered with a real registry shape
	config_fallback, // no registry (0.8.2), or it answered with the wrong shape
}

machine_source_label :: proc(s: Machine_Source) -> string {
	#partial switch s {
	case .not_probed:      return "not probed"
	case .registry:        return "herdr machine registry"
	case .config_fallback: return "configured remotes"
	}
	return "configured remotes"
}

// machine_registry_available is THE GATE.
//
// True only when `payload` parses as a JSON object with a `machines` array. This
// deliberately ignores the exit code that produced the payload: the shape is the
// evidence, so "unknown command: machine" (0.8.2) and a malformed registry
// response (0.9.x) both read as unavailable, while a well-formed registry reads
// as available even if some individual entries are unusable.
machine_registry_available :: proc(payload: []byte) -> bool {
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

// parse_machine_list turns a registry payload into remotes. Entries with no usable
// device string are skipped rather than failing the whole list: one bad registry
// entry must not cost us the other hosts.
parse_machine_list :: proc(payload: []byte) -> (remotes: []Remote, ok: bool) {
	raw : Raw_Machine_List = {}
	if err := json.unmarshal(payload, &raw); err != nil {
		return nil, false
	}
	out := make([dynamic]Remote, 0, len(raw.machines))
	for m in raw.machines {
		// Precedence: the explicit ssh target wins (it is what `--remote` needs),
		// then host/name/alias. Never synthesised, never rewritten.
		r := Remote{device = m.ssh_target, label = m.label}
		if r.device == "" { r.device = m.host }
		if r.device == "" { r.device = m.name }
		if r.device == "" { r.device = m.alias }
		if r.label == "" { r.label = r.device }
		if !remote_is_valid(r) { continue }
		append(&out, r)
	}
	return out[:], true
}

//-----------------------------------------------------------------------------
// Discovery
//-----------------------------------------------------------------------------

// Discovery holds the resolved remote set plus how it was obtained.
Discovery :: struct {
	remotes  : []Remote,      // never includes DEVICE_LOCAL
	source   : Machine_Source,
	registry : bool,          // convenience mirror of `source == .registry`
	note     : string,        // what we saw, for the status line / evidence
}

// machine_probe_argv is the feature probe. Run once at startup and cached — not on
// every refresh — because on 0.8.2 it is a guaranteed error path and paying it per
// refresh buys nothing.
machine_probe_argv :: proc() -> []string {
	argv := make([dynamic]string, 0, 4)
	append(&argv, HERDR_BIN, "machine", "list", "--json")
	return argv[:]
}

// discover_resolved is the seam T4.1 calls.
//
// `probe` is the raw payload of `machine list --json` (stdout, exit 0 path only —
// a non-zero exit is passed as an empty payload so it reads as "no registry"),
// and `config_remotes` is what the user configured.
//
// Precedence: registry wins when the shape gate passes; otherwise the configured
// list is used verbatim. DEVICE_LOCAL is never part of this list — the local group
// is implicit in the table and adding it here would double it.
discover_resolved :: proc(probe: []byte, config_remotes: []Remote) -> Discovery {
	valid := make([dynamic]Remote, 0, len(config_remotes) + 1)
	for r in config_remotes {
		if is_local_device(r.device) { continue }
		if !remote_is_valid(r) { continue }
		append(&valid, r)
	}

	if !machine_registry_available(probe) {
		return Discovery{
			remotes = valid[:],
			source  = .config_fallback,
			note    = "no machine registry in this herdr — using configured remotes",
		}
	}

	regs, ok := parse_machine_list(probe)
	if !ok || len(regs) == 0 {
		return Discovery{
			remotes = valid[:],
			source  = .config_fallback,
			note    = "machine registry present but empty — using configured remotes",
		}
	}

	// Registry first, then any configured remote it does not already know about,
	// de-duplicated on the VERBATIM device string (identity rule).
	merged := make([dynamic]Remote, 0, len(regs) + len(valid))
	seen := make(map[string]bool)
	for r in regs {
		key := strings.to_lower(r.device)
		if seen[key] { continue }
		seen[key] = true
		append(&merged, r)
	}
	for r in valid {
		key := strings.to_lower(r.device)
		if seen[key] { continue }
		seen[key] = true
		append(&merged, r)
	}

	return Discovery{
		remotes  = merged[:],
		source   = .registry,
		registry = true,
		note     = fmt.tprintf("machine registry: {} machine(s)", len(regs)),
	}
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
