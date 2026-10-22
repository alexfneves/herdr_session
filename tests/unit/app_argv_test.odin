package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_argv_test.odin — T10 port of `unit_argv` (src/app_cases.odin:801).
//
// Byte-exact argv. The exact string IS the thing being pinned: one device
// string travels through launch, attach and ssh-fetch, and any change to its
// position is a security-relevant change, not a formatting change.
//
// The `--` before the ssh device was added AFTER this expectation was first
// pinned (P2-7). Updating the expected string then was a deliberate test
// change, not a regression — which is why the byte-exact form is what is
// asserted rather than a "contains the device" predicate that would have
// absorbed the change silently.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:time"
import "core:testing"

import app "../../src/app"
import support "../support"

@(test)
app_argv_launch_and_attach :: proc(t: ^testing.T) {
	c := au_live(t)
	la, ok := app.launch_argv(app.DEVICE_LOCAL, "mydb")
	au_check(&c, "local launch argv built", ok, au_argv_text(la))
	au_eq(&c, "local launch is `herdr --session <name>`", au_argv_text(la),
		"herdr --session mydb")

	ra, rok := app.launch_argv("alice@workbox.example", "mydb")
	au_check(&c, "remote launch argv built", rok, au_argv_text(ra))
	au_eq(&c, "remote launch carries --remote VERBATIM", au_argv_text(ra),
		"herdr --remote alice@workbox.example --session mydb")

	aa, aok := app.attach_argv("2026-10-18-20-30-45-123")
	au_check(&c, "attach argv built", aok, "")
	au_eq(&c, "attach argv", au_argv_text(aa),
		"herdr session attach 2026-10-18-20-30-45-123")
}

@(test)
app_argv_control_commands_are_json :: proc(t: ^testing.T) {
	c := au_live(t)
	au_eq(&c, "stop argv is --json", au_argv_text(app.stop_argv("x")),
		"herdr session stop --json x")
	au_eq(&c, "delete argv is --json", au_argv_text(app.delete_argv("x")),
		"herdr session delete --json x")
	au_eq(&c, "list argv is --json", au_argv_text(app.list_argv()),
		"herdr session list --json")
	au_eq(&c, "machine probe argv", au_argv_text(app.machine_probe_argv()),
		"herdr machine list --json")
}

@(test)
app_argv_ssh_fetch_uses_the_same_device_string :: proc(t: ^testing.T) {
	c := au_live(t)
	// The same device string must be what our ssh fetch uses — one string,
	// three uses. The `--` before the device is the P2-7 option terminator.
	fa := app.remote_list_argv("Alice@Work.Box.Example")
	au_eq(&c, "ssh fetch uses the same verbatim device string, after the `--` terminator",
		au_argv_text(fa),
		"ssh -T -o BatchMode=yes -o ConnectTimeout=5 -- Alice@Work.Box.Example herdr session list --json")
}

@(test)
app_argv_invalid_name_builds_nothing :: proc(t: ^testing.T) {
	c := au_live(t)
	// Validation gate: a bad name must produce NO argv at all. Not an argv
	// that herdr would refuse — no argv, so nothing can be spawned with it.
	bad_names := []string{"", "default", "bad name", "bad:name", ".", ".."}
	for n in bad_names {
		bad_l, bad_launch_ok := app.launch_argv(app.DEVICE_LOCAL, n)
		bad_a, bad_attach_ok := app.attach_argv(n)
		au_check(&c, fmt.tprintf("invalid name %q produces no launch/attach argv", n),
			!bad_launch_ok && !bad_attach_ok && len(bad_l) == 0 && len(bad_a) == 0,
			fmt.tprintf("launch_ok={} attach_ok={}", bad_launch_ok, bad_attach_ok))
	}
}

@(test)
app_argv_delete_precheck_refuses_without_spawning :: proc(t: ^testing.T) {
	c := au_live(t)
	// delete_session's pre-check refuses WITHOUT invoking herdr: there is
	// nothing to delete, and invoking it would put `deleted:true` in our own
	// logs for a session that never existed.
	res := app.delete_session([]app.Session{}, app.DEVICE_LOCAL,
		"hs-never-existed-zz-99", 2 * time.Second)
	au_check(&c, "delete of an unknown session is refused by the pre-check",
		res.refused && !res.deleted && !res.existed,
		fmt.tprintf("refused={} deleted={} existed={} reason={}",
			res.refused, res.deleted, res.existed, res.reason))

	dres := app.delete_session([]app.Session{}, app.DEVICE_LOCAL, "default", 2 * time.Second)
	au_check(&c, "delete of `default` is refused by name (D12)",
		dres.refused && !dres.deleted, fmt.tprintf("reason={}", dres.reason))
}

// ─────────────────────────────────────────────────────────────────────────────
// P1 — cleanup must carry the DEVICE it belongs to.
//
// `cleanup_policy = "always"` after detaching from a REMOTE row used to run
// the BARE local `herdr session stop/delete <name>`, destroying the LOCAL
// session that happened to share the name. (device, name) is the identity
// (D8); dropping the device half of the pair deletes the wrong session.
//
// Both halves are pinned, because a test that only checked the remote case
// would still pass if someone made the LOCAL case ssh-wrapped too.
// ─────────────────────────────────────────────────────────────────────────────

@(test)
app_p1_remote_cleanup_wraps_ssh_with_the_rows_device :: proc(t: ^testing.T) {
	c := au_live(t)
	r_stop, r_del := app.cleanup_argv("alice@build-box.example", "hs-t-p1")
	au_eq(&c, "remote cleanup stop argv", au_argv_text(r_stop),
		"ssh -T -o BatchMode=yes -o ConnectTimeout=5 -- alice@build-box.example 'herdr session stop --json hs-t-p1'")
	au_eq(&c, "remote cleanup delete argv", au_argv_text(r_del),
		"ssh -T -o BatchMode=yes -o ConnectTimeout=5 -- alice@build-box.example 'herdr session delete --json hs-t-p1'")

	// The device in the HOST slot, verbatim — not the label, not a resolved
	// address, not "local".
	host_i := len(app.SSH_BASE_ARGS) + 1
	au_eq(&c, "remote cleanup stop: host operand is the device verbatim",
		r_stop[host_i], "alice@build-box.example")
	au_eq(&c, "remote cleanup delete: host operand is the device verbatim",
		r_del[host_i], "alice@build-box.example")
	au_eq(&c, "remote cleanup runs ssh, not herdr", r_stop[0], "ssh")
}

@(test)
app_p1_local_cleanup_is_bare_herdr :: proc(t: ^testing.T) {
	c := au_live(t)
	l_stop, l_del := app.cleanup_argv(app.DEVICE_LOCAL, "hs-t-p1")
	au_eq(&c, "local cleanup stop argv carries NO device wrapper",
		au_argv_text(l_stop), "herdr session stop --json hs-t-p1")
	au_eq(&c, "local cleanup delete argv carries NO device wrapper",
		au_argv_text(l_del), "herdr session delete --json hs-t-p1")
	au_eq(&c, "local cleanup runs herdr, not ssh", l_stop[0], "herdr")
}

@(test)
app_p1_remote_cleanup_is_not_the_bare_local_argv :: proc(t: ^testing.T) {
	c := au_live(t)
	r_stop, r_del := app.cleanup_argv("alice@build-box.example", "hs-t-p1")
	bare_stop := app.stop_argv("hs-t-p1")
	bare_del := app.delete_argv("hs-t-p1")
	// THE regression assertion, stated as the bug itself.
	au_check(&c, "remote cleanup is NOT the bare local stop argv (the P1 bug)",
		au_argv_text(r_stop) != au_argv_text(bare_stop),
		fmt.tprintf("remote=%q bare=%q", au_argv_text(r_stop), au_argv_text(bare_stop)))
	au_check(&c, "remote cleanup is NOT the bare local delete argv (the P1 bug)",
		au_argv_text(r_del) != au_argv_text(bare_del),
		fmt.tprintf("remote=%q bare=%q", au_argv_text(r_del), au_argv_text(bare_del)))

	host_i := len(app.SSH_BASE_ARGS) + 1
	au_check(&c, "…and the two halves of the pair are independently routed",
		r_stop[host_i] == r_del[host_i] && r_stop[host_i] != app.DEVICE_LOCAL,
		fmt.tprintf("stop.host=%q delete.host=%q", r_stop[host_i], r_del[host_i]))
}

@(test)
app_p1_numeric_device_and_labels :: proc(t: ^testing.T) {
	c := au_live(t)
	// A device alias must not be substituted either: the same string goes out
	// that came in. TEST-NET-3 (RFC 5737) documentation space — a numeric
	// target that is not this machine. The loopback literals stay out of the
	// suite on purpose: naming the fixture's host makes a test un-readable as
	// a generic one.
	a_stop, a_del := app.cleanup_argv("203.0.113.9", "hs-t-p1")
	host_i := len(app.SSH_BASE_ARGS) + 1
	au_eq(&c, "a numeric device travels verbatim through cleanup stop",
		a_stop[host_i], "203.0.113.9")
	au_eq(&c, "a numeric device travels verbatim through cleanup delete",
		a_del[host_i], "203.0.113.9")

	// The notice wording: the user has to be able to tell WHICH machine was
	// cleaned up, which is the whole point of the fix.
	au_eq(&c, "cleanup label for the local device",
		app.cleanup_target_label(app.DEVICE_LOCAL), "local")
	au_eq(&c, "cleanup label for a remote device",
		app.cleanup_target_label("build-box"), "build-box")
}
