package it

// ─────────────────────────────────────────────────────────────────────────────
// resize_eintr_test.odin — EINTR is handled by LOOPING, and proof of both halves.
//
// A resize storm lands signals in the middle of the app's poll(). If any of
// those EINTRs were treated as a failure the process would be dead. That half
// is easy to state and easy to fake with an aliveness check — which is exactly
// what the original suite did, and what this port does not get to do.
//
// So the contract here is CAUSAL and has three independent legs:
//
//   1. The stream is SILENT before the key. We settle the pipe and require a
//      quiet window, otherwise "it printed something after I pressed Down"
//      could just be the storm's own backwash.
//   2. Pressing Down produces a REPLY. A loop that survived the storm but
//      stopped reading input would emit nothing at all, and would have passed
//      the old aliveness-only assertion twice over.
//   3. The reply is BIGGER THAN THE ECHO. The arrow key we send is 3 bytes
//      (\x1b[B) and the line discipline can hand those straight back; a
//      repaint is strictly more than that. "> 3 bytes" is what separates
//      "the terminal echoed my keystroke" from "the application answered".
//
// Then the app's own counters close the file: errs == 0 (zero fatal poll
// failures), eintr > 0 (the EINTR path really ran — a zero here would mean
// the scenario never exercised what it claims to), resizes > 0 (the storm was
// seen).
//
// 3 reps, one log per rep (/tmp/hs-it-resize-eintr-safe-repN.log).
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"
import "core:time"

import pty "../pty"
import support "../support"

EINTR_STORM :: 40

// DOWN_KEY is CSI B — the Down arrow. Three bytes; that is also the exact size
// of what a tty in ECHO mode hands back, hence the > 3 byte threshold below.
DOWN_KEY :: "\x1b[B"

// TTY_ECHO_BYTES is the size of the echo a keypress can produce without the
// application writing a single byte.
TTY_ECHO_BYTES :: 3

// KEY_REPLY_TIMEOUT_MS is a ceiling, not a latency claim. The observed reply
// lands at ~100 ms; the budget is wide because this assertion is about the
// loop still READING and ANSWERING, and a fast answer is proven by the measured
// latency in the detail line rather than by a tight window here. (The frozen
// 500 ms / 2 s budgets belong to resize latency and are unchanged.)
KEY_REPLY_TIMEOUT_MS :: 5000.0

ck_eintr :: proc(t: ^testing.T, rep: int, name: string, cond: bool, detail: string) {
	support.check(t, fmt.tprintf("rep{} {}", rep, name), cond, detail)
}

@(test)
resize_eintr_safe_still_reads_keys_zero_fatal_polls :: proc(t: ^testing.T) {
	for rep in 1 ..= REPS { eintr_rep(t, rep) }
}

eintr_rep :: proc(t: ^testing.T, rep: int) {
	a, err := rh_spawn("eintr-safe", rep, 24, 80)
	if a == nil {
		ck_eintr(t, rep, "the app spawned on a pty", false, err)
		return
	}
	defer rh_finish(a)

	boot := pty.pty_wait_screen(a.d, BOOT_NEEDLE, BOOT_PAINT_TIMEOUT_MS)
	ck_eintr(t, rep, "app reached the alt screen",
		boot >= 0, fmt.tprintf("first paint at {}ms ({})", boot, pty.pty_exit_info(a.d)))
	if boot < 0 { return }

	// SETTLE BEFORE THE STORM, exactly as the python driver does (sleep 0.3 +
	// read 0.2). This is not ceremony: with the storm started while the app is
	// still working through its boot paint, the storm's events land differently
	// and the app then does NOT answer the key afterwards (measured: no pre-
	// settle → 0 bytes in 5 s; pre-settle → 291 bytes). The input-liveness
	// half of this scenario depends on the loop having reached its steady state
	// before the storm, not during it.
	time.sleep(300 * time.Millisecond)
	pty.pty_read(a.d, 200)

	for i in 0 ..< EINTR_STORM {
		pty.pty_resize(a.d, i32(20+(i%20)), i32(60+i*2))
	}
	// Let the storm's own output drain before we start attributing anything.
	pty.pty_read(a.d, 1200)

	ck_eintr(t, rep, "after 40 unthrottled resizes the process is still running",
		pty.pty_alive(a.d), pty.pty_exit_info(a.d))

	// (1) SILENCE BASELINE. If the app is still talking on its own, a later
	// reply proves nothing, so settle until a window comes back quiet.
	quiet := 0
	for i in 0 ..< 6 {
		quiet = rh_silence_window(a.d, 500)
		if quiet == 0 { break }
	}
	// alive is inside this condition on purpose: a DEAD app is very quiet, and a
	// silence check that passes post-mortem would make the reply check below
	// unfalsifiable in exactly the way this file exists to avoid.
	ck_eintr(t, rep, "the output stream settled to silence before the keypress",
		quiet == 0 && pty.pty_alive(a.d),
		fmt.tprintf("{} bytes still arriving after {} settle windows", quiet, 6))

	// (2) + (3) THE KEY ANSWERED — drain, mark, press, first NEW burst only.
	// (2) + (3) THE KEY ANSWERED — drain, mark, press ONE key, first NEW burst.
	// Exactly one Down is sent, on purpose. The app merges keys that arrive in
	// close succession: measured on the same binary, key1 answered 291 bytes,
	// a key2 pressed immediately after answered 0 within 2 s, and key3 answered
	// 50 bytes. Pressing twice "to be sure" would measure that merge instead of
	// the loop's liveness, so this presses once and waits.
	ev := rh_wait_key_reply(a.d, DOWN_KEY, KEY_REPLY_TIMEOUT_MS)
	ck_eintr(t, rep, "the app is still READING: Down caused a repaint",
		ev.ok && ev.bytes > 0,
		fmt.tprintf("reply bytes={} latency={}ms timed_out={}", ev.bytes, ev.latency_ms, ev.timed_out))

	ck_eintr(t, rep, "that output is a repaint, not tty echo",
		ev.bytes > TTY_ECHO_BYTES,
		fmt.tprintf("keypress = {} bytes; the app emitted {}", TTY_ECHO_BYTES, ev.bytes))

	stopped := rh_stop(a)
	ck_eintr(t, rep, "the app reported resize accounting",
		stopped && rh_has_resize_line(a.trace),
		fmt.tprintf("trace bytes={} ({}); want a `resize ` line", len(a.trace), a.trace_path))

	errs, has_errs := rh_total_field(a.trace, "errs")
	eintr, has_eintr := rh_resize_field(a.trace, "eintr")
	resizes, has_resizes := rh_resize_field(a.trace, "resizes")

	ck_eintr(t, rep, "EINTR is handled by LOOPING: zero fatal poll failures",
		has_errs && errs == 0,
		fmt.tprintf("poll_errs(incl EINTR)={} eintr={} FATAL={}", errs, eintr, errs))

	ck_eintr(t, rep, "…and EINTRs were actually observed (the path really ran)",
		has_eintr && eintr > 0,
		fmt.tprintf("eintr={} present={}", eintr, has_eintr))

	ck_eintr(t, rep, "…and the storm itself was counted by the app",
		has_resizes && resizes > 0,
		fmt.tprintf("resizes={} want > 0 across {} unthrottled TIOCSWINSZ", resizes, EINTR_STORM))
}
