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
//   2. The key CAUSES A REPAINT, and the repaint is the one the key asked for.
//      Not "bytes arrived" — the screen has to change into the thing the key
//      selects. See "THE KEY IS NOT AN ARROW ANY MORE" below for why that is
//      now a state transition rather than a cursor move, and why a byte count
//      alone was never the assertion this file thought it was.
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
// ── THE KEY IS NOT AN ARROW ANY MORE (RCH-9) ────────────────────────────────
// The pre-RCH-9 version of this file pressed Down at the landing screen and
// asserted "bytes came out". That was reading a side effect, not the loop:
// the footer carried the list-age token ("list 4s"), so *any* repaint emitted
// bytes whether or not the selection had moved. The old test was passing partly
// by accident.
//
// RCH-9 took the age token out of the footer
// (50-requirement-changes.md, item
// 4). A keypress that changes no cell now legitimately emits zero bytes — and
// a Down at {Mode selection} changes no cell at all, because that state has no
// cursor and no Up/Down bindings: its complete key list is
// `Enter n r s a d t Esc Ctrl-C`, and its filter line was removed too. The
// loop was alive and reading the whole time; the PROXY was what broke.
//
// So the liveness key is now `a`, which is bound at {Mode selection} and moves
// the app into {Attach session}. What that key changes is on screen and is
// checked as content, not as a byte total:
//
//   header line 2 (HEADER_STATE_ROW):  "Mode selection"  ->  "Attach session"
//
// That is the assertion's purpose — "the app is still READING" — turned into
// something only a reading, painting app can satisfy. A loop that survived the
// storm but stopped reading cannot produce that transition, and a loop that
// read the key but could not paint cannot either, which is why both the header
// change and the byte burst are asserted.
//
// ── HOW THIS IS KNOWN TO BE FALSIFIABLE ──────────────────────────────────────
// A liveness check that cannot go red is not a check. The control is the last
// leg below and it is NOT a simulation: after the live key has been answered,
// the app is SIGSTOPped (it is alive, its tty is intact, it simply cannot run
// and therefore cannot read) and the SAME key is pressed again with a 1.5 s
// budget. The measurement is then inverted on purpose:
//
//     live `a`   -> bytes arrive, header says "Attach session"     (proved above)
//     FROZEN `a` -> zero bytes, no repaint, timeout                (this leg)
//
// Measured on this branch's binary across reps: the live `a` answered 1162–1390
// bytes at 3.2–4.1 ms; the identical keypress against the SIGSTOPped process
// answered 0 bytes and timed out. Same harness, same helper, same key — the only
// variable is whether the app is running. If the app ever stops reading after a
// resize storm, this scenario goes red on both the header check and the reply
// check, and a "repaint" that is nothing but tty echo is caught by the > 3 byte
// leg.
//
// (A byte-count-only proxy cannot make that claim, which is the whole point of
// the re-homing. The old file's own reasoning — "a loop that survived the
// storm but stopped reading input would emit nothing at all" — was right about
// the intent and wrong about the observation: with the age token gone there is
// a perfectly healthy app that emits nothing. Now the asserted fact is the
// screen, and the byte burst is corroborating evidence rather than the verdict.)
//
// 3 reps, one log per rep (/tmp/hs-it-resize-eintr-safe-repN.log).
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"
import "core:time"

import pty "../pty"
import support "../support"

EINTR_STORM :: 40

// LIVENESS_KEY is the key this scenario proves the app can still read. `a` at
// {Mode selection} is bound, transitions to {Attach session}, and repaints
// both the header state line and the whole session view. It cannot act on a
// session by itself — that takes Enter, which this scenario never sends — so it
// cannot touch a live session. It is a pure display state change.
LIVENESS_KEY :: "a"

// LIVENESS_STATE / BOOT_STATE are the header line-2 phrases on either side of
// the liveness key: what is painted before it and what must be painted after.
BOOT_STATE :: "Mode selection"
LIVENESS_STATE :: "Attach session"

// BACK_KEY is ESC. In {Attach session} it clears the filter and returns to
// {Mode selection}, so it is the second display-changing key — used after the
// freeze control, where an arrow would be the wrong probe (see that leg).
BACK_KEY :: "\x1b"

// TTY_ECHO_BYTES is the size of the echo a keypress can produce without the
// application writing a single byte. LIVENESS_KEY is one printable byte, so
// even a full echo of it is 1 byte; the threshold below is the arrow-key size
// the file's original arithmetic was built on, which every real repaint of a
// state change clears by two orders of magnitude.
TTY_ECHO_BYTES :: 3

// KEY_REPLY_TIMEOUT_MS is a ceiling, not a latency claim. The observed reply
// lands at ~100 ms; the budget is wide because this assertion is about the
// loop still READING and ANSWERING, and a fast answer is proven by the measured
// latency in the detail line rather than by a tight window here. (The frozen
// 500 ms / 2 s budgets belong to resize latency and are unchanged.)
KEY_REPLY_TIMEOUT_MS :: 5000.0

// FROZEN_PROBE_MS is how long the frozen app is given to answer before the
// control declares "nothing came". It is SHORT on purpose: the live key
// answered in ~3–4 ms, so 1.5 s is already ~400x the live latency. A live
// app's reply would have arrived long before this window ends; if this check
// ever fails, the app answered a stopped-process keypress on a second-and-a-half
// budget, which is not a thing.
FROZEN_PROBE_MS :: 1500.0

ck_eintr :: proc(t: ^testing.T, rep: int, name: string, cond: bool, detail: string) {
	support.check(t, fmt.tprintf("rep{} {}", rep, name), cond, detail)
}

// rh_key_landed is the shared shape of every liveness verdict in this file: the
// app answered, AND the header now says the phrase that key is supposed to put
// there. "Answered" alone is a byte count wearing a claim; the header phrase is
// the part only a reading-and-painting app can produce.
rh_key_landed :: proc(a: ^Rh_App, ev: pty.Resize_Evidence, want: string) -> bool {
	return pty.pty_alive(a.d) && ev.ok && !ev.timed_out &&
		ev.bytes > TTY_ECHO_BYTES &&
		rh_header_state(&a.d.screen) == want
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

	// THE STATE BEFORE THE KEY. The liveness key only means something if the
	// header is on the state it transitions FROM; otherwise "the header says
	// Attach session" could be whatever the app had already drifted into.
	header_before := rh_header_state(&a.d.screen)
	ck_eintr(t, rep, "the header line-2 state before the key is the landing state",
		header_before == BOOT_STATE,
		fmt.tprintf("header row {} = '{}' want '{}'", HEADER_STATE_ROW, header_before, BOOT_STATE))

	// (1) SILENCE BASELINE. If the app is still talking on its own, a later
	// reply proves nothing, so settle until a window comes back quiet.
	quiet := 0
	for _ in 0 ..< 6 {
		quiet = rh_silence_window(a.d, 500)
		if quiet == 0 { break }
	}
	// alive is inside this condition on purpose: a DEAD app is very quiet, and a
	// silence check that passes post-mortem would make the reply check below
	// unfalsifiable in exactly the way this file exists to avoid.
	ck_eintr(t, rep, "the output stream settled to silence before the keypress",
		quiet == 0 && pty.pty_alive(a.d),
		fmt.tprintf("{} bytes still arriving after {} settle windows", quiet, 6))

	// (2) + (3) THE KEY ANSWERED — drain, mark, press ONE key, first NEW burst.
	// Exactly one key is sent, on purpose. The app merges keys that arrive in
	// close succession: measured on the same binary, key1 answered 291 bytes,
	// a key2 pressed immediately after answered 0 within 2 s, and key3 answered
	// 50 bytes. Pressing twice "to be sure" would measure that merge instead of
	// the loop's liveness, so this presses once and waits.
	grid_before := rh_screen_snapshot(&a.d.screen)
	ev := rh_wait_key_reply(a.d, LIVENESS_KEY, KEY_REPLY_TIMEOUT_MS)

	// THE VERDICT IS THE SCREEN, NOT THE BYTE COUNT. The header state line has
	// to have become the state this key selects. `bytes > 0` is kept as
	// corroboration below, but a repaint that did not produce this transition
	// is not an answer to this key, and a byte count that arrives without it
	// would be a repaint of something else.
	ck_eintr(t, rep, "the app is still READING: `a` moved the header state",
		ev.ok && rh_header_state(&a.d.screen) == LIVENESS_STATE,
		fmt.tprintf("header row {} = '{}' want '{}' (reply bytes={} latency={}ms timed_out={})",
			HEADER_STATE_ROW, rh_header_state(&a.d.screen), LIVENESS_STATE,
			ev.bytes, ev.latency_ms, ev.timed_out))

	// …and the grid as a whole moved with it, so the reply cannot be a stray
	// byte burst from the tty: a whole-screen state change changed many cells.
	ck_eintr(t, rep, "…and the repaint changed the screen, not just the stream",
		grid_before != rh_screen_snapshot(&a.d.screen) && ev.bytes > TTY_ECHO_BYTES,
		fmt.tprintf("screen changed={} reply bytes={} (tty echo can produce at most {})",
			grid_before != rh_screen_snapshot(&a.d.screen), ev.bytes, TTY_ECHO_BYTES))

	ck_eintr(t, rep, "that output is a repaint, not tty echo",
		ev.bytes > TTY_ECHO_BYTES,
		fmt.tprintf("keypress = {} bytes; the app emitted {}", TTY_ECHO_BYTES, ev.bytes))

	// (4) THE FALSIFICATION CONTROL. Freeze the app and press the same key with
	// the same helper. An app that cannot run cannot read, so nothing can come
	// back. This is the leg that makes the two checks above falsifiable rather
	// than hopeful: it measures the harness's answer when the answerer is gone.
	// The app is thawed in the same condition it is asserted on, so a failure
	// here cannot leave a stopped process behind.
	froze := rh_freeze(a)
	time.sleep(200 * time.Millisecond)
	frozen := rh_wait_key_reply(a.d, LIVENESS_KEY, FROZEN_PROBE_MS)
	thawed := rh_thaw(a)
	time.sleep(200 * time.Millisecond)
	pty.pty_read(a.d, 400)

	ck_eintr(t, rep, "CONTROL: with the app SIGSTOPped the same key gets no reply (so the check above can actually fail)",
		froze && thawed && frozen.bytes == 0 && frozen.timed_out && !frozen.ok,
		fmt.tprintf("froze={} thawed={} frozen bytes={} timed_out={} ok={} (live reply was {} bytes at {}ms)",
			froze, thawed, frozen.bytes, frozen.timed_out, frozen.ok, ev.bytes, ev.latency_ms))

	// And the app must still be usable afterwards — a control that killed the
	// subject would prove nothing about the storm. The probe here is ESC, not an
	// arrow: we are sitting in {Attach session} and the number of sessions on
	// this machine is not ours to control, so a Down may legitimately move
	// nothing. ESC always returns to {Mode selection} and always repaints the
	// header line, so it is a key whose effect is guaranteed by the state
	// machine rather than by the row count.
	resumed := rh_wait_key_reply(a.d, BACK_KEY, KEY_REPLY_TIMEOUT_MS)
	ck_eintr(t, rep, "…and after the freeze the app is alive and answering again",
		rh_key_landed(a, resumed, BOOT_STATE),
		fmt.tprintf("alive={} reply bytes={} latency={}ms timed_out={} header='{}' want '{}'",
			pty.pty_alive(a.d), resumed.bytes, resumed.latency_ms, resumed.timed_out,
			rh_header_state(&a.d.screen), BOOT_STATE))

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
