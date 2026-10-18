package main

// PHASE 0 PLACEHOLDER — toolchain smoke test only.
//
// Its whole purpose is to prove that pkgs.odin compiles against *both* statically
// linked archives built in-derivation (nix/clay.nix, nix/termbox2.nix) and that
// `nix run .` executes the result (ISC-1). Real application logic starts in
// Phase 1; this file gets replaced.
//
// Clay's Odin binding resolves `foreign import Clay "linux/clay.a"` relative to
// clay.odin, which the package stages at clay-odin/clay.odin alongside
// clay-odin/linux/clay.a — hence the ../ import path from src/.
import clay "../clay-odin"
import termbox2 "../vendor/termbox2-odin"

import "core:fmt"

main :: proc() {
	fmt.println("herdr-session: toolchain OK")

	// Proves the Clay archive is linked (not just present on the search path).
	fmt.printf("  clay.MinMemorySize() = %v bytes\n", clay.MinMemorySize())

	// Proves the termbox2 archive is linked and its ABI is not garbled.
	fmt.printf("  tb_wcwidth('A')      = %v\n", termbox2.tb_wcwidth(u32('A')))
	fmt.printf("  tb_wcwidth(U+4E00)   = %v\n", termbox2.tb_wcwidth(0x4E00))
}
