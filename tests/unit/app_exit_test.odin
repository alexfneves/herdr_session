package unit

// ─────────────────────────────────────────────────────────────────────────────
// app_exit_test.odin — T10 port of `unit_exit_contract` (:396) and
// `unit_tty_version_tolerance` (:496).
//
// The exit-code contract: every code maps to a DISTINCT meaning, and the
// authoritative stream is chosen by the code and nothing else. The failure
// this exists to prevent is a map keyed on the code alone: code 1 is BOTH
// "herdr refused, read the envelope" and (0.9.3+) "there was no terminal".
// The discriminator is the ENVELOPE, so both directions are pinned here —
// the refusal that must not be swallowed, and the refusal that must be.
//
// The two tty payloads are captured byte for byte from real herdr binaries on
// this box (0.8.2 panic / 0.9.5 one clean sentence). They are reproduced
// verbatim below; reformatting either would test the reformatter, not the
// parser.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:strings"
import "core:testing"

import app "../../src/app"
import support "../support"

AU_Exit_Case :: struct {
	code : i32,
	want : string,
}

// The label column is what the UI would print, so the table spells the
// human-readable strings `outcome_label` returns.
AU_EXIT_EXPECT : []AU_Exit_Case = {
	{0, "ok"},
	{1, "herdr error"},
	{2, "bad command line"},
	{101, "terminal-init panic"},
	{124, "timed out"},
	{127, "herdr not installed there"},
	{255, "ssh failed"},
	{7, "unknown error"},
}

app_exit_battery_app_exit_code_table :: proc(c: ^AU_Ctx) {
	for e in AU_EXIT_EXPECT {
		code := e.code
		cs := app.Capture{code = code, spawned = true}
		if code == 124 { cs.timed_out = true }
		kind, payload, _ := app.outcome(&cs)
		label := app.outcome_label(kind)
		au_eq(c, fmt.tprintf("exit {} maps to", code), label, e.want)

		// The split: exit 0 reads STDOUT, every other code reads STDERR.
		cs.out = au_to_bytes(`{"stdout_marker":1}`)
		cs.err = au_to_bytes(`{"error":{"code":"boom","message":"stderr marker"}}`)
		kind2, payload2, herr2 := app.outcome(&cs)
		if code == 0 {
			au_check(c, "exit 0 → STDOUT is authoritative",
				strings.contains(string(payload2), "stdout_marker"),
				fmt.tprintf("payload={}", string(payload2)))
			au_check(c, "exit 0 → no error envelope parsed", !herr2.present, "")
		} else if kind2 == .tty_panic {
			au_check(c, "exit 101 → NO payload parsed (Rust panic is not JSON)",
				payload2 == nil && !herr2.present,
				fmt.tprintf("payload={}", payload2 == nil))
		} else if code == 124 {
			// Our own timeout has no child stream to be authoritative about:
			// the kind is the answer, and the payload stays empty.
			au_check(c, "exit 124 → no payload claimed from either stream",
				len(payload2) == 0, fmt.tprintf("payload={}", string(payload2)))
		} else {
			au_check(c, fmt.tprintf("exit {} → STDERR is authoritative", code),
				strings.contains(string(payload2), "stderr marker"),
				fmt.tprintf("payload={}", string(payload2)))
			if e.code == 1 {
				au_check(c, "exit 1 → error code+message parsed out of stderr",
					herr2.present && herr2.code == "boom",
					fmt.tprintf("present={} code={} message={}",
						herr2.present, herr2.code, herr2.message))
			}
		}
		_ = payload
	}
}
@(test)
app_exit_code_table :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_exit_battery_app_exit_code_table(&__c)
}

app_exit_battery_app_exit_panic_is_never_an_envelope :: proc(c: ^AU_Ctx) {
	// 101 must not be mistaken for a parseable error even when stderr *contains*
	// JSON-shaped text — the panic text is not an envelope.
	cs := app.Capture{
		code    = 101,
		spawned = true,
		err     = au_to_bytes(
			"thread 'main' panicked at init.rs:299: failed to initialize terminal"),
	}
	k, p, h := app.outcome(&cs)
	au_check(c, "panic text is never presented as a herdr error",
		k == .tty_panic && !h.present && p == nil,
		fmt.tprintf("kind={} present={}", app.outcome_label(k), h.present))

	// not-spawned is distinct from every child answer.
	c2 := app.Capture{code = 127, spawned = false}
	k2, _, _ := app.outcome(&c2)
	au_eq(c, "we could not spawn → its own kind", app.outcome_label(k2), "herdr not found")

	// A timeout is OUR code and outranks whatever the child's status was.
	c3 := app.Capture{code = 0, spawned = true, timed_out = true}
	k3, _, _ := app.outcome(&c3)
	au_eq(c, "our timeout outranks the child", app.outcome_label(k3), "timed out")
}
@(test)
app_exit_panic_is_never_an_envelope :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_exit_battery_app_exit_panic_is_never_an_envelope(&__c)
}

app_exit_battery_app_exit_codes_map_to_distinct_meanings :: proc(c: ^AU_Ctx) {
	// 8 codes, 8 distinct labels — a collapse here would hide errors.
	seen := make(map[string]bool)
	codes := []i32{0, 1, 2, 101, 124, 127, 255, 7}
	for code in codes {
		cx := app.Capture{code = code, spawned = true, timed_out = code == 124}
		kx, _, _ := app.outcome(&cx)
		seen[app.outcome_label(kx)] = true
	}
	au_eq_i(c, "all 8 exit codes map to distinct meanings", i64(len(seen)), 8)
}
@(test)
app_exit_codes_map_to_distinct_meanings :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_exit_battery_app_exit_codes_map_to_distinct_meanings(&__c)
}

app_exit_battery_app_tty_herdr_0_8_2_panic_path :: proc(c: ^AU_Ctx) {
	p82 := app.Capture{
		code    = 101,
		spawned = true,
		err = au_to_bytes("thread 'main' panicked at src/ui/init.rs:299:11:\nfailed to initialize terminal: IoError(Os { code: 25, kind: Uncategorized, message: \"Inappropriate ioctl for device\" })\nnote: run with `RUST_BACKTRACE=1` for a backtrace\n"),
	}
	k82, p_ok82, h82 := app.outcome(&p82)
	au_say(c, fmt.tprintf("    0.8.2 exit 101  -> {}", app.outcome_label(k82)))
	au_check(c, "0.8.2: exit 101 is a terminal failure",
		app.outcome_needs_terminal(k82), app.outcome_label(k82))
	au_check(c, "0.8.2: the panic is never parsed as a herdr error envelope",
		!h82.present && p_ok82 == nil,
		fmt.tprintf("present={} payload_nil={}", h82.present, p_ok82 == nil))
}
@(test)
app_tty_herdr_0_8_2_panic_path :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_exit_battery_app_tty_herdr_0_8_2_panic_path(&__c)
}

app_exit_battery_app_tty_herdr_0_9_5_message_path :: proc(c: ^AU_Ctx) {
	// VERBATIM from `env -u HERDR_ENV herdr --session x < /dev/null` on herdr
	// 0.9.5 (RCH-2's capture; the whole line is 116 bytes).
	p95 := app.Capture{
		code    = 1,
		spawned = true,
		err = au_to_bytes("herdr: cannot attach without a usable terminal: Inappropriate ioctl for device (os error 25); run inside a terminal\n"),
	}
	k95, p95_payload, h95 := app.outcome(&p95)
	au_say(c, fmt.tprintf("    0.9.5 exit 1    -> {}", app.outcome_label(k95)))
	au_check(c, "0.9.5: exit 1 with no envelope and a terminal message is a terminal failure",
		app.outcome_needs_terminal(k95), app.outcome_label(k95))
	au_check(c, "0.9.5: it is NOT mislabelled as the generic herdr error",
		k95 != .herdr_error, fmt.tprintf("kind={}", app.outcome_label(k95)))
	au_check(c, "0.9.5: nothing was parsed as an envelope (there is none)",
		!h95.present, fmt.tprintf("present={}", h95.present))
	au_check(c, "0.9.5: the human sentence IS the payload — safe to show the user",
		len(p95_payload) > 0 && strings.contains(string(p95_payload), "terminal"),
		fmt.tprintf("{} bytes, mentions the terminal", len(p95_payload)))

	// THE PAIR: one answer, two codes. Both sides are computed HERE rather
	// than referenced from the other test, so this assertion can fail on its
	// own evidence and does not depend on another proc having run first.
	kp82, _, _ := app.outcome(&app.Capture{
		code    = 101,
		spawned = true,
		err = au_to_bytes("thread 'main' panicked at src/ui/init.rs:299:11:\nfailed to initialize terminal: IoError(Os { code: 25, kind: Uncategorized, message: \"Inappropriate ioctl for device\" })\nnote: run with `RUST_BACKTRACE=1` for a backtrace\n"),
	})
	au_check(c, "both herdr generations reach the SAME verdict",
		app.outcome_needs_terminal(kp82) == app.outcome_needs_terminal(k95) &&
			app.outcome_needs_terminal(kp82),
		fmt.tprintf("101 -> {} · 1 -> {}",
			app.outcome_label(kp82), app.outcome_label(k95)))
}
@(test)
app_tty_herdr_0_9_5_message_path :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_exit_battery_app_tty_herdr_0_9_5_message_path(&__c)
}

app_exit_battery_app_tty_exit_one_with_envelope_stays_herdr_error :: proc(c: ^AU_Ctx) {
	// The negative half: exit 1 must NOT become a terminal refusal. This is the
	// rule that keeps `nested herdr is disabled`, a failed `stop`, and a
	// rejected session name readable. Each arrives at exit 1 WITH an envelope;
	// if the marker check ran first, or ran without the envelope check, every
	// one of those would tell the user to go find a terminal.
	enveloped := []string{
		`{"error":{"code":"session_stop_failed","message":"session x is not running"}}`,
		`{"error":{"code":"invalid_session_name","message":"name may contain only [A-Za-z0-9._-]"}}`,
	}
	for body in enveloped {
		cs := app.Capture{code = 1, spawned = true, err = au_to_bytes(body)}
		k, _, h := app.outcome(&cs)
		au_check(c, "exit 1 WITH an envelope stays a herdr error (never 'no terminal')",
			k == .herdr_error && h.present,
			fmt.tprintf("kind={} code={}", app.outcome_label(k), h.code))
	}
}
@(test)
app_tty_exit_one_with_envelope_stays_herdr_error :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_exit_battery_app_tty_exit_one_with_envelope_stays_herdr_error(&__c)
}

app_exit_battery_app_tty_other_exit_one_shapes :: proc(c: ^AU_Ctx) {
	// A nested-herdr refusal is plain text on some builds and mentions nothing
	// terminal-shaped; still not a tty failure.
	nested := app.Capture{code = 1, spawned = true,
		err = au_to_bytes("error: nested herdr is disabled by default.\nsee configuration if you want to enable it.\n")}
	kn, _, _ := app.outcome(&nested)
	au_check(c, "the nesting refusal is not read as a terminal problem",
		!app.outcome_needs_terminal(kn), app.outcome_label(kn))

	// Exit 1 with an EMPTY stderr is a herdr error with no detail — not a tty
	// failure. (The marker check must not fire on nothing.)
	empty := app.Capture{code = 1, spawned = true}
	ke, _, _ := app.outcome(&empty)
	au_check(c, "exit 1 with no stderr at all is NOT a terminal refusal",
		ke == .herdr_error, app.outcome_label(ke))
}
@(test)
app_tty_other_exit_one_shapes :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_exit_battery_app_tty_other_exit_one_shapes(&__c)
}

app_exit_battery_app_tty_unknown_and_distinct_kinds :: proc(c: ^AU_Ctx) {
	// A NEW version that invents a third code still has to be answerable. It is:
	// unknown is not terminal, which means a future code cannot silently
	// inherit "go find a terminal" — and if herdr changes the WORDS rather
	// than the code, TTY_REFUSAL_MARKERS is the one list to extend.
	future := app.Capture{code = 137, spawned = true,
		err = au_to_bytes("herdr: something entirely new happened\n")}
	kf, _, _ := app.outcome(&future)
	au_check(c, "an unknown code is never misread as a terminal refusal",
		kf == .unknown && !app.outcome_needs_terminal(kf), app.outcome_label(kf))

	// The two terminal kinds stay DISTINCT (the panic and the refusal are
	// different facts and the UI may want different words) while sharing the
	// ONE predicate every caller actually asks.
	au_check(c, "tty_panic and tty_unavailable are distinct kinds but one answer",
		app.outcome_label(.tty_panic) != app.outcome_label(.tty_unavailable) &&
			app.outcome_needs_terminal(.tty_panic) &&
			app.outcome_needs_terminal(.tty_unavailable),
		fmt.tprintf("{} / {}", app.outcome_label(.tty_panic),
			app.outcome_label(.tty_unavailable)))

	// And neither is a device outage: a host whose herdr cannot find a terminal
	// is a config fact about the whole app, not "that host is down".
	au_check(c, "a terminal failure is still a per-host 'failed', never 'unreachable'",
		app.device_status_label(app.device_status_of(.tty_unavailable, "")) == "failed" &&
			app.device_status_label(app.device_status_of(.tty_unavailable, "")) !=
				app.device_status_label(.unreachable),
		app.device_status_label(app.device_status_of(.tty_unavailable, "")))
}
@(test)
app_tty_unknown_and_distinct_kinds :: proc(t: ^testing.T) {
	__c := au_live(t)
	app_exit_battery_app_tty_unknown_and_distinct_kinds(&__c)
}

