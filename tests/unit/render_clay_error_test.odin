package unit

// ─────────────────────────────────────────────────────────────────────────────
// render_clay_error_test.odin — T7 port of the `clay-error` case (13 checks).
//
// Source: `case_clay_error` (src/render_cases.odin:650), section 4 of
// dev/render-smoke.sh.
//
// WHAT A GREEN RUN HERE MEANS
//
// Clay's DEFAULT error handler is a no-op. So any error text that shows up in
// our log can only have come from OUR handler, installed at Clay_Initialize.
// This case is therefore not "did Clay complain" — Clay complains in a void
// unless someone is listening. It is: did OUR listener catch it, did the
// record SURVIVE the C frame it was raised inside (the message must be copied
// into Odin-owned storage, because Clay's buffer is gone the moment the
// callback returns), and does the whole thing degrade honestly under the
// hostile cases — oversized text, unknown ordinals, an error storm.
//
// WHY ONE @(test) PROC RATHER THAN ONE PER CHECK
//
// Unlike the other cases, this one's assertions are about the STATE OF ONE
// RING BUFFER read at thirteen points along a single sequence. The retention
// window, the cumulative total and the dropped count are each checked at a
// specific position in that sequence; splitting the procs would either make
// each proc re-establish the exact same prior state (duplicating the sequence
// under a different name, so nobody can tell which step is being proven) or
// change what "dropped > 0" means. The old case was one sequence and it is
// ported as one sequence. Cross-run verdicts belong to the gate anyway —
// `t.error_count` is per test, so there is no shared `any_failed` flag to
// leak into anything else in this binary.
// ─────────────────────────────────────────────────────────────────────────────

import "core:fmt"
import "core:testing"

import clay "../../clay-odin"
import render "../../src/render"
import tb "../../vendor/termbox2-odin"

import support "../support"

@(test)
render_clay_error_survives_the_c_frame :: proc(t: ^testing.T) {
	support.note(t, "case clay-error — duplicate id survives the C frame")
	if !render_session(t, "clay-error") { return }

	render.errors_clear()
	support.check(t, "no errors before the frame", render.errors_total() == 0,
		fmt.tprintf("total={}", render.errors_total()))

	tb.tb_clear()
	render_and_present(render_build_duplicate)

	total := render.errors_total()
	support.check(t, "the duplicate id was reported", total > 0,
		fmt.tprintf("total={}", total))

	msg := render.errors_latest()
	support.note(t, fmt.tprintf("  reported: {}", msg))
	support.check(t, "message is non-empty", len(msg) > 0, fmt.tprintf("len={}", len(msg)))
	support.check(t, "message survived intact outside the C frame",
		len(msg) > 8 && render.errors_count() >= 1,
		fmt.tprintf("retained={} len={}", render.errors_count(), len(msg)))

	// And it must be identifiable as a duplicate-id class error, not just noise
	// that happened to arrive from somewhere.
	is_dup := false
	i := 0
	for i < render.errors_count() {
		one := render.errors_at(i)
		if render_contains_ci(one, "already") || render_contains_ci(one, "duplicate") {
			is_dup = true
		}
		i += 1
	}
	support.check(t, "message reads as a duplicate-id problem", is_dup, fmt.tprintf("\"{}\"", msg))

	// The kind mapping must work — the raw ordinal is what we key on, because
	// clay.odin's ErrorType enum does not name all of clay.h's members. A
	// switch on the enum would be handling a value the binding cannot name.
	recs := render.errors_records()
	kind_ok := len(recs) > 0
	first_kind := ""
	if len(recs) > 0 { first_kind = recs[0].kind }
	for r in recs {
		if r.kind != "DuplicateId" { kind_ok = false }
	}
	support.check(t, "error kind mapped from the ordinal", kind_ok,
		fmt.tprintf("all {} records have kind DuplicateId (first={})", len(recs), first_kind))

	// Truncation must be honest, not a silent cut or an overrun. A synthetic
	// oversized message goes straight through the same handler Clay uses.
	render.errors_clear()
	long := render_make_long(render.ERROR_MESSAGE_CAPACITY * 3)
	render.errors_handler(clay.ErrorData{
		errorType = clay.ErrorType.DuplicateId,
		errorText = clay.MakeString(long),
		userData  = nil,
	})
	trunc := render.errors_records()[0]
	tlen := len(render.record_message(&trunc))
	support.check(t, "an oversized message is truncated to capacity",
		tlen <= render.ERROR_MESSAGE_CAPACITY && trunc.truncated,
		fmt.tprintf("len={} cap={} truncated={}", tlen, render.ERROR_MESSAGE_CAPACITY, trunc.truncated))
	support.check(t, "truncated message is still readable",
		tlen > render.ERROR_MESSAGE_CAPACITY/2,
		fmt.tprintf("kept {} of {} bytes", tlen, len(long)))
	delete(long)

	// An unknown ordinal must degrade, never mislabel or trap. clay.h grows
	// members that this binding cannot name; a future ordinal must read as
	// UnknownError rather than as some other error's name.
	render.errors_clear()
	render.errors_handler(clay.ErrorData{
		errorType = cast(clay.ErrorType)(200),
		errorText = clay.MakeString("future clay error"),
		userData  = nil,
	})
	support.check(t, "an unmapped ordinal degrades to UnknownError",
		render.errors_records()[0].kind == "UnknownError",
		fmt.tprintf("kind={}", render.errors_records()[0].kind))

	// The plan's own acceptance case: an element opened and never closed must be
	// reported too, not just duplicate ids.
	render.errors_clear()
	clay.BeginLayout()
	// Deliberately unbalanced. Clay_EndLayout closes one element itself, so two
	// opens with zero closes is what leaves the stack non-empty and trips
	// UNBALANCED_OPEN_CLOSE (clay.h:4448-4457).
	clay._OpenElement()
	clay._OpenElement()
	unbalanced := clay.EndLayout(0)
	_ = unbalanced
	support.note(t, fmt.tprintf("  unbalanced frame: total={} latest={}",
		render.errors_total(), render.errors_latest()))
	support.check(t, "an unclosed element is reported too", render.errors_total() > 0,
		fmt.tprintf("total={} latest={}", render.errors_total(), render.errors_latest()))

	kinds := ""
	for r in render.errors_records() {
		kinds = fmt.tprintf("{}{},", kinds, r.kind)
	}
	support.check(t, "unbalanced open maps to UnbalancedOpenClose",
		render_contains_ci(kinds, "UnbalancedOpenClose"),
		fmt.tprintf("kinds={}", kinds))

	// The ring must be bounded: an error storm from a hostile or broken frame
	// must never grow memory without limit, and what it drops must be COUNTED.
	// Silent eviction is worse than a smaller ring.
	before := render.errors_count()
	k := 0
	for k < 40 {
		render_and_present(render_build_duplicate)
		k += 1
	}
	support.note(t, fmt.tprintf("  after 40 more duplicate frames: retained={} total={} dropped={}",
		render.errors_count(), render.errors_total(), render.errors_dropped()))
	support.check(t, "retention stays bounded (no unbounded growth)",
		render.errors_count() <= 8 && render.errors_count() >= before,
		fmt.tprintf("retained={} (window is {})", render.errors_count(), render.ERROR_RING_CAPACITY))
	support.check(t, "overflow is counted, not hidden", render.errors_dropped() > 0,
		fmt.tprintf("dropped={}", render.errors_dropped()))
}
