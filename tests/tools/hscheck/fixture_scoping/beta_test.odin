package scoping_fixture

import "core:fmt"
import "core:testing"

import support "../../../support"

// beta_test.odin — the group a DIFFERENT row owns. 5 assertions + fallout.
//
// The fallout below is a miniature of the real theme_hygiene_test bug
// (2 verbs, 3 arguments). It exists so rule 7's scoping can be proven:
// this marker must be attributed to beta and must NOT make alpha's gate run
// go red. A rule that fails the wrong suite is worse than no rule at all --
// it trains people to ignore the red.

@(test)
beta_mixed :: proc(t: ^testing.T) {
	support.eq(t, "beta assertion 1", "d", "d")
	support.eq(t, "beta assertion 2", "e", "e")
	support.eq(t, "beta assertion 3", "f", "f")
	support.eq(t, "beta assertion 4", "g", "g")
	support.eq(t, "beta assertion 5", "h", "h")
	// 2 verbs, 3 args -> guaranteed `%!(EXTRA ...)`.
	fmt.eprintfln("beta detail {} {}", 1, 2, 3)
}
