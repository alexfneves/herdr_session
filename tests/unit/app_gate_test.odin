package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_gate_test.odin — T10 port of `unit_machine_gate` (src/app_cases.odin:600).
//
// D1: gate on JSON SHAPE, never on the exit code.
//
// The trap this exists for: a help banner printed on STDOUT with EXIT 0. A
// code-only check calls that a registry, and the app then believes the user
// has machines they never configured. The shape check is what saves us,
// downstream of `outcome`.
//
// O13 IS THE SECOND HALF. herdr 0.9.5 answers `machine list --json` with a
// bare `[]`, not the documented `{machines:[…]}`. A gate that reads that as
// "registry available, zero machines" and RETURNS that empty set silently
// drops every host in the user's config. Both halves are pinned: the bare
// array is recognised, and the config still stands behind it.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

// au_cfg is the configured-remote list used by every precedence case here.
// It carries a deliberate duplicate of the registry's device and a `local`
// that must never reach a remote list. Built from a dynamic so the slice
// outlives the call — returning a compound literal slice would hand back
// stack memory.
au_cfg :: proc() -> []app.Remote {
	d: [dynamic]app.Remote = {}
	append(&d, app.Remote{device = "cfgbox", label = "Config Box"})
	append(&d, app.Remote{device = "workbox", label = "duplicate-of-registry"})
	append(&d, app.Remote{device = "local", label = "should be dropped from the remote list"})
	return d[:]
}

AU_REG_OBJECT :: `{"machines":[{"id":"workbox","label":"Work","ssh_target":"alice@workbox.example"}]}`
AU_NO_HERDR_MACHINE :: "unknown command: machine\nrun 'herdr --help' for usage\n"

@(test)
app_gate_shape_not_exit_code :: proc(t: ^testing.T) {
	c := au_live(t)
	// herdr 0.8.2: no `machine` subcommand at all.
	eight_o_two := au_to_bytes(AU_NO_HERDR_MACHINE)
	au_check(&c, "0.8.2 'unknown command' text → NO registry",
		!app.machine_registry_available(eight_o_two), "plain text, no JSON")

	help_banner := au_to_bytes(
		"herdr — terminal workspace manager\n\nUsage: herdr [options]\n  machine list  List machines\n")
	code_zero_help := app.Capture{code = 0, spawned = true, out = help_banner}
	k, payload, _ := app.outcome(&code_zero_help)
	au_check(&c, "exit 0 + help banner: outcome says ok (it is only exit-code truth)",
		k == .ok, "the shape check is what saves us, downstream of outcome")
	au_check(&c, "help banner with exit 0 is NOT a registry",
		!app.machine_registry_available(payload), "no machines array in a help banner")
}

@(test)
app_gate_accepts_only_the_registry_shape :: proc(t: ^testing.T) {
	c := au_live(t)
	with_machines := au_to_bytes(AU_REG_OBJECT)
	au_check(&c, "object with machines array → registry",
		app.machine_registry_available(with_machines), "the gate passes on shape alone")

	remotes_key := au_to_bytes(`{"remotes":[{"id":"x","ssh_target":"y"}]}`)
	au_check(&c, "object WITHOUT a machines array → no registry",
		!app.machine_registry_available(remotes_key),
		"a differently-shaped object is not the registry")
}

@(test)
app_gate_registry_entries_parse_verbatim :: proc(t: ^testing.T) {
	c := au_live(t)
	// Registry entries parse; junk entries are skipped rather than fatal.
	mixed := au_to_bytes(`{"machines":[
		{"name":"workbox","label":"Work","host":""},
		{"name":"","host":"bob@homebox"},
		{"name":"","host":"","alias":""}]}`)
	rs, ok := app.parse_machine_list(mixed)
	au_check(&c, "parse_machine_list ok", ok, fmt.tprintf("{} remotes", len(rs)))
	au_eq(&c, "entry 1 device verbatim", rs[0].device, "workbox")
	au_eq(&c, "entry 2 falls back to host", rs[1].device, "bob@homebox")
	au_eq_i(&c, "empty entries are dropped, not fatal", i64(len(rs)), 2)

	// The VERBATIM rule: no normalisation anywhere on the device string.
	v := au_to_bytes(`{"machines":[{"name":"Alice@Work.Box.Example:2222"}]}`)
	vs, _ := app.parse_machine_list(v)
	au_eq(&c, "device string is never normalised", vs[0].device,
		"Alice@Work.Box.Example:2222")
}

@(test)
app_gate_registry_plus_config_merges :: proc(t: ^testing.T) {
	c := au_live(t)
	d := app.discover_resolved(au_to_bytes(AU_REG_OBJECT), au_cfg())
	au_check(&c, "registry + config both contributed -> .merged",
		d.source == .merged, app.machine_source_label(d.source))
	au_check(&c, "local is never in the remote list",
		!au_contains_device(d.remotes, app.DEVICE_LOCAL), "the local group is implicit")
	// The dedup key is the VERBATIM device string, so the registry entry and a
	// config entry with the same string collapse; nothing else does.
	au_eq_int(&c, "registry + config merge, deduped on the device string",
		len(d.remotes), 3)
	au_eq(&c, "registry entry first, device verbatim from ssh_target",
		d.remotes[0].device, "alice@workbox.example")
	au_eq(&c, "registry label wins over the config label", d.remotes[0].label, "Work")
	au_eq(&c, "config-only entries follow the registry", d.remotes[1].device, "cfgbox")
	au_eq_int(&c, "the merge reports 1 from the registry", d.from_registry, 1)
	au_eq_int(&c, "the merge reports 2 from the config", d.from_config, 2)
}

@(test)
app_gate_fallback_when_registry_absent :: proc(t: ^testing.T) {
	c := au_live(t)
	d2 := app.discover_resolved(au_to_bytes(AU_NO_HERDR_MACHINE), au_cfg())
	au_check(&c, "gate fails -> config fallback", d2.source == .config_fallback,
		app.machine_source_label(d2.source))
	au_eq_i(&c, "fallback carries the config remotes", i64(len(d2.remotes)), 2)
	au_eq(&c, "fallback drops local too", d2.remotes[0].device, "cfgbox")
	au_eq_int(&c, "nothing came from a registry that never answered", d2.from_registry, 0)
}

@(test)
app_gate_empty_registry_does_not_suppress_config :: proc(t: ^testing.T) {
	c := au_live(t)
	empty := au_to_bytes(`{"machines":[]}`)
	d3 := app.discover_resolved(empty, au_cfg())
	au_check(&c, "empty {machines:[]} registry does NOT suppress the configured remotes",
		len(d3.remotes) == 2,
		fmt.tprintf("{} remotes, {} from the registry", len(d3.remotes), d3.from_registry))
	au_eq_int(&c, "…and the accounting says the registry contributed zero",
		d3.from_registry, 0)
	au_eq_int(&c, "…while the config contributed both", d3.from_config, 2)
	au_check(&c, "…and the gate still KNOWS the registry exists (it is not " +
		"confused with 0.8.2)", d3.registry, fmt.tprintf("registry={}", d3.registry))
}

@(test)
app_gate_o13_bare_array_registry :: proc(t: ^testing.T) {
	c := au_live(t)
	zero_nine_five := au_to_bytes("[]\n")
	au_check(&c, "0.9.5's bare `[]` IS recognised as a registry answer",
		app.machine_registry_available(zero_nine_five),
		"bare array, not {machines:[…]} — the gate has to accept both shapes")
	z := app.discover_resolved(zero_nine_five, au_cfg())
	au_check(&c, "O13: machine list == [] + non-empty config -> the config is still there",
		len(z.remotes) == 2,
		fmt.tprintf("{} remote(s): {}", len(z.remotes), au_devices_of(z.remotes)))
	au_eq_int(&c, "O13: zero came from the empty registry", z.from_registry, 0)
	au_eq_int(&c, "O13: two came from the config", z.from_config, 2)
	au_check(&c, "O13: and they are the CONFIGURED devices, verbatim",
		z.remotes[0].device == "cfgbox" && z.remotes[1].device == "workbox",
		au_devices_of(z.remotes))
	au_check(&c, "O13: the gate reports the registry as PRESENT (not the 0.8.2 path)",
		z.registry, fmt.tprintf("registry={} source={}", z.registry,
			app.machine_source_label(z.source)))
}

@(test)
app_gate_bare_array_with_entries_merges :: proc(t: ^testing.T) {
	c := au_live(t)
	// A bare array WITH entries must merge too, not just its empty case —
	// otherwise "empty works" would be masking "non-empty ignored".
	bare_full := au_to_bytes(
		`[{"label":"Box A","ssh_target":"a@example"},{"label":"Box B","ssh_target":"b@example"}]`)
	au_check(&c, "bare array WITH entries is a registry",
		app.machine_registry_available(bare_full), "same shape rule, non-empty")
	bf := app.discover_resolved(bare_full, au_cfg())
	au_eq_i(&c, "both bare-array machines merged", i64(len(bf.remotes)), 4)
	au_eq_int(&c, "…2 from the registry", bf.from_registry, 2)
	au_eq_int(&c, "…2 from the config", bf.from_config, 2)
	au_eq(&c, "…registry first, verbatim", bf.remotes[0].device, "a@example")
}

@(test)
app_gate_disabled_and_empty_set :: proc(t: ^testing.T) {
	c := au_live(t)
	// `enabled: false` is respected; absent means enabled.
	off := au_to_bytes(
		`[{"ssh_target":"off@example","enabled":false},{"ssh_target":"on@example"}]`)
	offs, _ := app.parse_machine_list(off)
	au_eq_i(&c, "disabled entries are skipped", i64(len(offs)), 1)
	au_eq(&c, "…and the enabled one survives verbatim", offs[0].device, "on@example")

	// Nothing configured AND an empty registry: an empty set, said out loud
	// rather than implied. There must be no state that looks like "we have
	// remotes".
	none := app.discover_resolved(au_to_bytes("[]\n"), []app.Remote{})
	au_eq_i(&c, "empty registry + empty config -> empty set", i64(len(none.remotes)), 0)
	au_check(&c, "…and that is distinguishable from a registry that answered with hosts",
		none.from_registry == 0 && none.source != .merged,
		fmt.tprintf("source={}", app.machine_source_label(none.source)))
}

@(test)
app_gate_table_groups_local_first :: proc(t: ^testing.T) {
	c := au_live(t)
	d2 := app.discover_resolved(au_to_bytes(AU_NO_HERDR_MACHINE), au_cfg())
	// The table's device groups: local implicit + one group per remote.
	groups := app.devices_for_table(d2)
	gparts: [dynamic]string = {}
	for g in groups { append(&gparts, g.target) }
	gstr, _ := strings.join(gparts[:], ",")
	au_eq(&c, "table groups: local first, then the fallback remotes", gstr,
		"local,cfgbox,workbox")
}
