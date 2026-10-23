package support

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// ─────────────────────────────────────────────────────────────────────────────
// sentinel.odin — how a suite makes "nothing HERDR_* reached the child" a
// MEASUREMENT instead of an absence of evidence.
//
// THE DEFECT THIS EXISTS FOR (found by the gate, not by a shell)
//
// Every "the scrub worked" assertion has two ways to pass: the scrub removed
// the HERDR_* entries, or there was nothing to remove. Only one of those is a
// test. The pre-fix version of `alu_child_sees_no_herdr_namespace` closed
// that hole by reading its OWN inherited HERDR_ENV — which made the
// non-vacuity of the assertion depend on how the binary happened to be
// launched. The gate strips the whole HERDR_* namespace from every suite
// (`base_env` above, and rightly: a leaked HERDR_SESSION makes a child
// believe it IS the developer's session), so under the gate that borrowed
// premise was simply false and the suite went red for a reason that had
// nothing to do with the product.
//
// THE FIX, WHICH IS NOT "SKIP WHEN UNSET"
//
// Skipping when HERDR_ENV is absent would reintroduce exactly the vacuous
// pass this guard exists to block. Stopping the gate from stripping would
// remove a load-bearing safety rule. Both wrong for the same reason: the
// premise belongs to the test, so the test should SUPPLY it.
//
// Arm a sentinel HERDR_* pair, verify it landed by reading it BACK (not by
// trusting set_env's return), assert it is armed HERE, and then assert the
// child does not carry it. Both halves can fail:
//
//   arm the sentinel and let the leak through   -> "leaked=[]" goes RED
//   do not arm / set_env refuses / wrong value -> the premise goes RED
//
// UNSAFE arm values are the whole hazard, so the values are chosen to be
// inert: SCRATCH_PROBE_SESSION is under SCRATCH_PREFIX, so even if the scrub
// failed outright the worst a child could be pointed at is a scratch name no
// suite ever creates — never a live session. Restore is exact: "unset" and
// "set but empty" are kept distinct, because flattening them hands every
// later test in the binary a session that does not exist.
// ─────────────────────────────────────────────────────────────────────────────

// The sentinel names. Both are inside the HERDR_ namespace, so a scrub that
// only covers the three keys herdr happens to read today would still leak.
SCRATCH_PROBE_ENV :: "HERDR_ENV"
SCRATCH_PROBE_ENV_VALUE :: "1"
SCRATCH_PROBE_SESSION :: "HERDR_SESSION"
SCRATCH_PROBE_SESSION_VALUE :: "hs-t-scrub-probe"

// Sentinels is the full armed set, so a suite can assert on the SET rather
// than on a hand-copied list of two.
SCRATCH_SENTINELS : []KV = {
	KV{key = SCRATCH_PROBE_ENV,     val = SCRATCH_PROBE_ENV_VALUE},
	KV{key = SCRATCH_PROBE_SESSION, val = SCRATCH_PROBE_SESSION_VALUE},
}

// Scrub_Probe is one armed/unarmed cycle. `armed` is the read-back of every
// sentinel, so a set_env that reported success but did not land cannot leave
// the suite asserting on a premise that is not true.
Scrub_Probe :: struct {
	saves : [dynamic]KV,  // what was there before, by key ("" + absent both tracked by had_)
	hads  : [dynamic]bool,
	armed : bool,
}

// probe_arm writes every sentinel into THIS process and records what was
// there before. On any failure it disarms what it already wrote and returns
// with armed = false rather than half-arming.
probe_arm :: proc(p: ^Scrub_Probe) {
	for s in SCRATCH_SENTINELS {
		prev, had := os.lookup_env(s.key, context.allocator)
		append(&p.saves, KV{key = s.key, val = prev})
		append(&p.hads, had)
		if e := os.set_env(s.key, s.val); e != nil {
			probe_disarm(p)
			return
		}
	}

	p.armed = probe_armed(p)
	if !p.armed { probe_disarm(p) }
}

// probe_armed re-reads every sentinel from the live environment. It answers
// "is the scrub's job actually queued?", which is the only question that
// makes a later leaked==[] worth anything.
probe_armed :: proc(p: ^Scrub_Probe) -> bool {
	if len(SCRATCH_SENTINELS) == 0 { return false }
	for s in SCRATCH_SENTINELS {
		got, ok := os.lookup_env(s.key, context.allocator)
		if !ok || got != s.val { return false }
	}
	return true
}

// probe_disarm puts back EXACTLY what was there, including "unset". This is
// a restore, not a delete: a suite that unsets a value the launcher set has
// changed the experiment it was supposedly only observing.
probe_disarm :: proc(p: ^Scrub_Probe) {
	i := len(p.saves)
	for i > 0 {
		i -= 1
		k := p.saves[i].key
		if i < len(p.hads) && p.hads[i] {
			os.set_env(k, p.saves[i].val)
		} else {
			os.unset_env(k)
		}
	}
	delete(p.saves)
	delete(p.hads)
	p.armed = false
}

// probe_sentinel_in answers "did this NAME=VALUE pair show up in the
// captured child environment?". Used to prove the check is falsifiable: the
// same string that armed the parent must be absent from the child.
probe_sentinel_in :: proc(captured: string, key: string, val: string) -> bool {
	line := fmt.tprintf("{}={}", key, val)
	return strings.contains(captured, line)
}

//-----------------------------------------------------------------------------
// Counted assertions built on the probe
//-----------------------------------------------------------------------------

// check_probe_armed asserts the premise. Its failure message is written for
// someone who has never seen this file: it names what must be true and why the
// rest of the suite is meaningless without it.
check_probe_armed :: proc(t: ^testing.T, label: string, armed: bool) {
	check(t, fmt.tprintf("{} — a HERDR_* sentinel is armed HERE", label), armed,
		fmt.tprintf("{}={} {}={} must both be readable in this process, or the child-side check has nothing to scrub",
			SCRATCH_PROBE_ENV, SCRATCH_PROBE_ENV_VALUE,
			SCRATCH_PROBE_SESSION, SCRATCH_PROBE_SESSION_VALUE))
}
