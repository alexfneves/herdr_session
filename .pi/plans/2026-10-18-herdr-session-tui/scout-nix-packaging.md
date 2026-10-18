# Scout: Nix packaging + config/theme facts for `herdr-session`

Scouted 2026-10-18 in `/home/alexfneves/gits/herdr_session` (devenv skeleton, greenfield Odin sources).
Everything marked **VERIFIED** was actually run on this machine, not read from docs.

TL;DR for the planner:

- `pkgs.odin` **exists** in the flake's current nixpkgs (`dev-2026-09`), prebuilt on cache.nixos.org. No overlay needed.
- There is **no** `pkgs.buildOdinPackage` in this nixpkgs. Use a plain `stdenv.mkDerivation` that shells out to `odin build`.
- Clay is zlib-licensed, single-header (`clay.h`), and **compiles cleanly with nix's GCC 16.2** (clang not required).
- End-to-end proven here: `gcc -c -DCLAY_IMPLEMENTATION -fPIC` → `ar rcs clay.a` → `odin build` → runs, prints Clay render commands.
- TOML: `Up05/toml_parser` (MIT) **compiles and parses under this exact Odin**. XDG: `os.user_config_dir` is built into Odin — no library needed.
- `herdr` itself is in nixpkgs (`0.9.3`) and is a runtime PATH dependency of the TUI.

---

## (a) Current flake assessment

`flake.nix` (1115 bytes) is the vanilla `devenv init` skeleton:

```nix
inputs = {
  nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
  systems.url = "github:nix-systems/default";
  devenv.url  = "github:cachix/devenv";
  devenv.inputs.nixpkgs.follows = "nixpkgs";
};
nixConfig = { extra-trusted-public-keys = "devenv.cachix.org-1:..."; extra-substituters = "https://devenv.cachix.org"; };
outputs = { self, nixpkgs, devenv, systems, ... }@inputs:
  let forEachSystem = nixpkgs.lib.genAttrs (import systems); in {
    devShells = forEachSystem (system: {
      default = devenv.lib.mkShell { inherit inputs pkgs; modules = [ {
        packages = [ pkgs.hello ];
        enterShell = ''hello'';
        processes.hello.exec = "hello";
      }; ]};
    });
  };
```

**VERIFIED** — `nix run .` fails today with exactly:

```
error: flake 'git+file:///home/alexfneves/gits/herdr_session' does not provide attribute
       'apps.x86_64-linux.default', 'defaultApp.x86_64-linux',
       'packages.x86_64-linux.default' or 'defaultPackage.x86_64-linux'
```

So the *only* thing missing for the user's `nix run .` requirement is `packages.<system>.default`
(or an `apps.<system>.default`). `nix flake show` confirms only `devShells` exists.

What exists that constrains us:

| Item | Status | Constraint |
|---|---|---|
| `nixpkgs` input | `cachix/devenv-nixpkgs/rolling` → wraps `NixOS/nixpkgs` rev `8edc0c72e3a38faf5434e40d1f19431125fe4b30` (`nixpkgs-unstable`), `lib.version = 26.11pre-git` | **Good enough** — `odin` is present. No input change required. |
| `devenv.inputs.nixpkgs.follows = "nixpkgs"` | already set | Single nixpkgs instance → devenv and our package share the same stdenv/LLVM. **Keep this.** |
| `systems` input | `nix-systems/default` (x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin) | Fine, but see musl/Windows notes in (g). |
| `.envrc` | nix-direnv 3.1.0 + `use flake . --no-pure-eval` | devenv only works with `--no-pure-eval` (see gotcha below). |
| `devenv` input | heavy (pulls nix, nixd, rust-overlay, ghostty, crate2nix…) | Only used for `devShells`. Does **not** constrain the package as long as the package is derived from `nixpkgs` directly. |

**VERIFIED GOTCHA (important):** `nix develop` and `nix flake show` **fail without `--no-pure-eval`**:

```
error: Failed assertions:
- devenv was not able to determine the current directory.
  See https://devenv.sh/guides/using-with-flakes/ how to use it with flakes.
```

Implication: `devShells.default` is *impure-eval-only*. Therefore the **package derivation must not
touch devenv at all** — build it straight from `nixpkgs.legacyPackages.${system}`. `nix run .` only
evaluates `packages.<sys>.default`, so the devenv breakage does not affect it (confirm after implementing).

Also drop `processes.hello.exec = "hello";` and `packages = [ pkgs.hello ]` from the devenv module —
`nix develop` currently starts a `hello` process.

---

## (b) Recommended flake shape (real attribute names)

`nix run .` resolution order: `apps.<sys>.default` → `defaultApp.<sys>` → `packages.<sys>.default` →
`defaultPackage.<sys>`. Shipping **`packages.<sys>.default`** is sufficient; add
`meta.mainProgram = "herdr-session"` so `nix run .` (and `nix run .#herdr-session`) pick the right
binary even if `bin/` ever contains more than one file.

Sketch (NOT written to the repo — planner's call):

```nix
outputs = { self, nixpkgs, devenv, systems, clay, odin-toml, ... }@inputs:
let
  forEachSystem = nixpkgs.lib.genAttrs (import systems);
  inherit (nixpkgs) lib;
  callPackage = pkgs: pkgs.callPackage ./nix/package.nix {
    clay-source = clay;          # raw source tree (flake=false input)
    toml-source = odin-toml;
  };
in {
  packages = forEachSystem (system:
    let pkgs = import nixpkgs { inherit system; };
    in {
      default = callPackage pkgs;
    });

  devShells = forEachSystem (system: {
    default = devenv.lib.mkShell {
      inherit inputs pkgs;
      modules = [ ./devenv.nix ];   # or inline
    };
  });
} // {
  # optional, keeps `nix run .#clay` usable during development
  overlays.default = final: prev: { herdr-session = callPackage final; };
};
```

Suggested devShell package set (`packages` inside the devenv module):

```
pkgs.odin        # compiler  (VERIFIED: dev-2026-09)
pkgs.ols         # VERIFIED: installs BOTH `ols` AND `odinfmt` (MIT) — LSP + formatter
pkgs.clang       # optional; only if you want to mirror upstream's build-clay-lib.sh exactly
pkgs.herdr       # runtime dep of the TUI (VERIFIED present: 0.9.3)
pkgs.openssh     # remote session paths
```

Keep `enterShell`/`processes` minimal. Suggest `packages = [ pkgs.odin pkgs.ols pkgs.herdr ]` and remove `hello`.

Note: `pkgs.odin` and `pkgs.ols` both `--set-default ODIN_ROOT ${odin}/share`. Don't override
`ODIN_ROOT` in the shell — it's already correct and the wrapper uses `--set-default` so a user-set
value still wins.

---

## (c) Odin in nixpkgs — verified facts

Source read: `pkgs/by-name/od/odin/package.nix` in nixpkgs rev `8edc0c72e3a38faf5434e40d1f19431125fe4b30`
(the `nixpkgs-src` behind this flake's `devenv-nixpkgs/rolling`).

| Fact | Value | How verified |
|---|---|---|
| Attribute exists | `pkgs.odin` — **YES** | `nix eval …legacyPackages.x86_64-linux.odin.version` → `dev-2026-09` |
| Package version | `dev-2026-09` | nix `version` attr |
| `odin version` reports | `dev-2026-10` | `odin version` on the built binary — **differs from the nixpkgs version string; don't assert on it in tests** |
| Upstream source | `fetchFromGitHub { owner = "odin-lang"; repo = "Odin"; tag = "dev-2026-09"; }` | package.nix |
| Built with | `llvmPackages.stdenv` (LLVM-based stdenv), `env.LLVM_CONFIG = llvm-config` | package.nix |
| Runtime closure seen | `llvm-21.1.8`, `llvm-binutils-21.1.8` downloaded as deps | `nix build` log |
| `nativeBuildInputs` | `makeBinaryWrapper`, `which`, `cmake` | `nix eval` of `nativeBuildInputs` |
| Install layout | `$out/bin/odin`; `$out/share/{base,core,vendor,shared}` | package.nix + store listing |
| Wrapper | `wrapProgram $out/bin/odin --prefix PATH : {bintools,llvm,clang,lld} --set-default ODIN_ROOT $out/share` | package.nix |
| **`pkgs.buildOdinPackage`** | **DOES NOT EXIST** (`nix eval` → `null`) | VERIFIED — no helper, hand-roll the derivation |
| Binary availability | **Prebuilt on cache.nixos.org** — `nix build github:cachix/devenv-nixpkgs/rolling#odin` copied a substituted path, no compile | VERIFIED |
| License | `lib.licenses.zlib` | package.nix |
| Platforms | `lib.platforms.unix`; **`broken = stdenv.hostPlatform.isMusl`** | package.nix → exclude musl systems |
| Vendor libs prebuilt by the package | cgltf, stb, miniaudio, kb_text_shape, box2d (built in installPhase) | package.nix |
| Patches applied | `darwin-remove-impure-links.patch` (drops `/usr/local/lib`, `/opt/homebrew/lib`, `/opt/local/lib` from darwin link line), `system-raylib.patch`, `box2d-no-network.patch` | package.nix |
| `vendor/raylib/{linux,macos,wasm,windows}` | **deleted** in postPatch (pure system-raylib instead) — irrelevant to us, we don't use raylib | package.nix |

Also present and **NOT what you want**: `pkgs.odin2` = "Odin 2 Free Synthesizer" — an unrelated JUCE audio
plugin from `TheWaveWarden/odin2` (GPL3, x86_64-linux only). Do not confuse it with the Odin language.

### Approaches for packaging an Odin project here

1. **`stdenv.mkDerivation` + `odin build` (recommended, and the only realistic one since `buildOdinPackage` is absent).**
   `nativeBuildInputs = [ odin ]`. `buildPhase: odin build . -out:herdr-session …`, `installPhase: install -Dm755`.
2. `-collection:<name>=<dir>` is Odin's library-collection mechanism and maps `name:X` → `<dir>/X`
   (**VERIFIED**: `foreign import "clay:clay.a"` with `-collection:clay=/tmp/coll` resolved to `/tmp/coll/clay.a`).
   It works, but for a *package* you need `<dir>/<pkgname>/`. The simpler pattern that needs **zero patching**
   of the vendored binding is to build `clay.a` into the source copy at the path the binding already hard-codes
   (`<pkgdir>/linux/clay.a`). Recommend that.
3. `pkgs.odinPackages` / `callPackage`-style Odin sets: do not exist.
4. `mod.pkg` / odinpkg: Odin's `mod.pkg` JSON manifest exists (the TOML lib ships one) but there is no
   nix integration for it. Vendor sources as flake inputs instead.

**VERIFIED: no HOME dependency.** `odin build` succeeds with `HOME=/homeless-shelter` and with `HOME`
completely unset (`env -i PATH=… odin build .` produced a working binary). So a sandboxed nix build
does not need `export HOME=$TMPDIR` for the compiler itself. (Harmless to set anyway.)

**VERIFIED: link driver.** Odin invokes **clang** as the link driver on Linux (link errors surface as
`clang: error: linker command failed`), using the clang/lld/bintools that `pkgs.odin`'s wrapper puts on
`PATH`. So our derivation does **not** need to add clang explicitly — `odin` brings it.

---

## (d) Clay C side under Nix — build + link plan

### Source + license

| | |
|---|---|
| Repo | https://github.com/nicbarker/clay (`main`, 18.3k stars) |
| **License** | **zlib / libpng license** (`spdx_id: Zlib`), `Copyright (c) 2024 Nic Barker`. Full text in `LICENSE.md` (891 bytes). |
| Canonical C source | **`clay.h` at the repository root** — single header, 303,701 bytes on `main` |
| Version marker inside header | `// VERSION: 0.14` |
| `main` commit | `e6cc36941ab2af5d81107617039d6f527a1c660b` (2026-05-20) |
| Latest git tag | `v0.14` (released 2025-06-06) — `main` is ahead of the newest tag |
| `clay.h` sha256 (main) | `54aef6d5f96b14e296bebb6db4a755543e98fd7e6c188411afb2f22a4b4f7728` |
| Odin binding | `bindings/odin/clay-odin/clay.odin` (14,709 bytes), sha256 `24a146cca991c327a12476e2c37e108b263ea2ab287110f657900819e95ff41d` |
| Binding == experiment copy? | **YES — byte-identical** to `/home/alexfneves/gits/tui_experiment/clay-odin/clay.odin` (same sha256). The experiment tracks current upstream. |
| Also in repo | `bindings/odin/build-clay-lib.sh`, `bindings/odin/README.md`, `odinfmt.json` (`character_width=180`, `sort_imports=true`, `tabs=true`), `ols.json`, `examples/terminal-example` (relevant prior art for a TUI renderer) |

**Attribution requirement (zlib):** keep `LICENSE.md` shipped with the vendored copy, do not misrepresent
origin, and mark altered files as altered. If we patch `clay.odin`'s `foreign import` line, that counts as
an altered source version and must be plainly marked. A `LICENSES/clay.md` + `NOTICE` entry in the repo is
the clean way. zlib is compatible with Apache-2/MIT-style licensing of the wrapper; nixpkgs spelling is
`lib.licenses.zlib` — and `pkgs.odin` is also zlib, so `meta.license = lib.licenses.zlib` for the whole
package is defensible (or `lib.licenses.asl20` for our code + zlib for vendored bits via `license = [ … ]`).

### C standard / compiler requirements

From the header itself:

```c
#if !( (defined(__cplusplus) && __cplusplus >= 202002L)
    || (defined(__STDC__) && __STDC__ == 1 && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L)
    || defined(_MSC_VER) || defined(__OBJC__) )
#error "Clay requires C99, C++20, or MSVC"
#endif
```

- Only includes: `<stdint.h>`, `<stdbool.h>`, `<stddef.h>`, plus `<emmintrin.h>` (x86_64) or
  `<arm_neon.h>` (aarch64). **No libc/POSIX headers.**
- SIMD can be turned off with `-DCLAY_DISABLE_SIMD`.
- Has C23-awareness (`#if __STDC_VERSION__ >= 202311L` → `CLAY__DEFAULT_STRUCT {}` vs `{0}`) so C23 is
  handled too, but **C99 is the floor**.
- `CLAY_PACKED_ENUM` uses `enum __attribute__((__packed__))` — GCC and Clang both fine.

### VERIFIED compile matrix (this machine, nixpkgs GCC 16.2.0)

Command pattern: `cp clay.h clay.c; $CC -c -DCLAY_IMPLEMENTATION -ffreestanding -fPIC -O2 clay.c`

| Flags | Result |
|---|---|
| `gcc` default std (gnu17) | ✅ OK, no output |
| `gcc -std=c99 -Wall` | ✅ compiles; only `-Wunused-variable` warnings (3) |
| `gcc -std=c11 -Wall -Wextra` | ✅ compiles; unused-var/unused-param/sign-compare/missing-field-initializer warnings only |
| clang | **not available in this shell to test** (devenv shell has no clang on PATH). Upstream's own script uses clang. Both are fine in principle; **we verified GCC**, which is what nix `stdenv.cc` is here (`gcc-wrapper 16.2.0`). |

So: **no specific C standard flag is required** (default works); pass `-std=c99` for explicitness. Warnings
are upstream-clean-enough; do **not** use `-Werror`.

Undefined symbols in the object: `memcpy`, `memset`, `__stack_chk_fail`, `_GLOBAL_OFFSET_TABLE_`.
→ the archive is not freestanding at link time; it needs libc. That is fine — **Odin links libc anyway**
(verified: resulting binary dynamically links `libc.so.6` + `libm.so.6` from nix glibc).

### VERIFIED end-to-end build+run under Nix

```bash
# 1. C side, with nixpkgs GCC 16.2
cp clay.h clay.c
gcc -c -std=c99 -DCLAY_IMPLEMENTATION -ffreestanding -fPIC -O2 -o clay.o clay.c
ar rcs clay.a clay.o                       # 193 KB archive

# 2. place at the path the upstream binding hard-codes:  clay-odin/linux/clay.a
# 3. odin build (pkgs.odin dev-2026-09)
odin build . -out:./herdrtest              # linked OK
./herdrtest
#   clay MinMemorySize = 5785280 bytes (5649.69 KiB)
#   render commands: 0        <- empty/decor-less tree; layout ran without error
#   clay_had_error=false
ldd ./herdrtest
#   libm.so.6 -> /nix/store/…-glibc-2.44-25/lib/libm.so.6
#   libc.so.6 -> /nix/store/…-glibc-2.44-25/lib/libc.so.6
```

**Clay's default static memory requirement is 5,785,280 bytes (~5.5 MiB)** via `clay.MinMemorySize()`.
Budget the arena accordingly (`make([]u8, clay.MinMemorySize())`).

### Recommended Clay build in the derivation

```nix
# nix/clay.nix  — builds the static lib from the vendored clay source
{ lib, stdenv, clay-src }:
stdenv.mkDerivation (finalAttrs: {
  pname = "clay";
  version = "0.14";
  inherit (clay-src) src;
  phases = [ "buildPhase" "installPhase" ];
  buildPhase = ''
    runHook preBuild
    cp ${clay-src}/clay.h clay.c
    $CC -c -std=c99 -DCLAY_IMPLEMENTATION -ffreestanding -fPIC -O2 -o clay.o clay.c
    ${stdenv.cc.bintools.bintools}/bin/ar rcs libclay.a clay.o
    runHook postBuild
  '';
  installPhase = ''install -Dm644 libclay.a $out/lib/libclay.a'';
})
```

and in the app derivation, copy the header/archive into the expected binding layout before `odin build`:

```bash
mkdir -p clay-odin/linux
cp ${clay-src}/bindings/odin/clay-odin/clay.odin clay-odin/clay.odin
cp ${clay}/lib/libclay.a clay-odin/linux/clay.a      # binding: foreign import Clay "linux/clay.a"
odin build . -out:herdr-session
```

`-fPIC` is **safe and required-ish**: PIC objects link into both PIE and non-PIE executables. Upstream
builds with `-fPIC` on every platform. Position-independent concerns are handled by Odin/nix defaults.

**Vendoring recommendation: fetch from GitHub as a flake input, do not commit the sources.**
Clay has **no flake** in-repo, so declare it `flake = false`:

```nix
clay = { url = "github:nicbarker/clay/v0.14"; flake = false; };  # or a pinned main rev
```
This gives reproducibility via `flake.lock` + narHash, avoids committing 300 KB of third-party code, and
keeps attribution honest as long as `LICENSE.md` from the tarball is referenced/shipped.
Committing is also acceptable but then you must vendor `LICENSE.md` too and mark any edits.

**Do NOT reuse the prebuilt `clay.a`/`clay.lib`/`clay.o` from
`/home/alexfneves/gits/tui_experiment/clay-odin/{linux,macos,macos-arm64,windows,windows}`** —
those are untracked-by-nix, unverifiable, arch-specific blobs. Rebuild them in the derivation.

---

## (e) TOML config + XDG in Odin

### Config location — VERIFIED resolution

Odin's `core:os` has **built-in XDG Base Directory support** (`core/os/user.odin` + `core/os/user_posix.odin`).
No third-party library is needed.

```odin
dir, err := os.user_config_dir(context.allocator)  // VERIFIED
```
Resolution on Linux (`_xdg_lookup("XDG_CONFIG_HOME", "/.config", …)`): `$XDG_CONFIG_HOME` if set and
non-empty, else `$HOME/.config`, else error `.No_HOME_Variable`.
Note: `_xdg_lookup` routes keys ending in `_DIR` through `~/.config/user-dirs.dirs`; `XDG_CONFIG_HOME`
does not, so it's a plain env lookup + fallback.

Other XDG dirs available: `os.user_data_dir`, `os.user_cache_dir`, `os.user_state_dir`, `os.user_log_dir`,
`os.user_home_dir`. Path joining: `os.join_path({...}, alloc)` or `filepath.join` (from `core:path/filepath`)
— both return `(joined, err)`. There is **no** `os.path_join`.

**VERIFIED working snippet:**

```
cfg_dir, cerr := os.user_config_dir(context.allocator)
cfg_path, _   := os.join_path({cfg_dir, "herdr_session.toml"}, context.allocator)
table, err    := toml.parse_file(cfg_path, context.allocator)
if err.type != .None { … }
# ran with XDG_CONFIG_HOME=/tmp/fakecfg → resolved /tmp/fakecfg/herdr_session.toml ✓
# theme = catppuccin-latte (ok=true)
# poll_seconds = 5 (ok=true)
# remotes len=2
# missing key ok=false val=""
```

> **Design note for the planner:** the requirement says `~/.config/herdr_session.toml`.
> XDG-correct would be `$XDG_CONFIG_HOME/herdr_session/config.toml`. Using
> `os.user_config_dir(...) ++ "/herdr_session.toml"` honours XDG *and* the user's literal filename.
> Recommend that, and flag if the planner wants the directory-based layout instead.

### Parser recommendation: `Up05/toml_parser`

| | |
|---|---|
| Repo | https://github.com/Up05/toml_parser (default branch `main`) |
| Stars / activity | 65 ★, last push 2026-05-25 (most popular Odin TOML parser by a wide margin) |
| License | **MIT** |
| Spec | **TOML 1.1.0** (claims); validated against `toml-test` v2 via `run-tests.bash` |
| Nixpkgs? | **Not packaged** → vendor via `fetchFromGitHub`/`fetchzip` flake input, or `git clone` into `vendor/toml` |
| **Compiles under odin dev-2026-09** | ✅ **VERIFIED** (see snippet above — parsed strings, ints, nested tables, arrays) |
| Files | `toml.odin` (public API), `tokenizer.odin`, `validator.odin`, `parser.odin`, `misc.odin`, `unmarshal.odin`, `dates/` (RFC-3339), `main.odin` marked `#+private` so it's excluded from library builds |
| Reflection | has `unmarshal_table(value, table)` with `toml:"key"` struct tags |

API shape (verified against the sources):

```odin
parse_file :: proc(filename: string, allocator := context.allocator) -> (^Table, Error)
parse_data :: proc(data: []u8, original_filename := "untitled data", allocator) -> (^Table, Error)
parse      :: proc(text: string, filename: string, allocator) -> (^Table, Error)

// generic, but ONLY for types in the `Type` union:
get      :: proc($T: typeid, section: ^Table, path: ..string) -> (T, bool)
             where intrinsics.type_is_variant_of(Type, T)
get_panic:: proc($T: typeid, section: ^Table, path: ..string) -> T
// typed helpers — USE THESE (the generic one errors out for plain `int`):
get_i64 / get_f64 / get_bool / get_string / get_date / get_list / get_table
   and *_panic variants
deep_delete  :: proc(type: Type, allocator) -> runtime.Allocator_Error
delete_error :: proc(err: ^Error)   // filename is only sliced, not freed
```

**API gotchas hit during verification (spell these out for the worker):**
1. `Error` is a **struct**, not an optional: check `err.type != .None`, not `err != nil`.
   `Error :: struct { type: ErrorType; line: int; file: string; more: Builder; formatted: Builder }`.
2. `toml.get(int, …)` **fails to compile** (`'where' clause evaluated to false`) — use `get_i64`.
3. `parse_data` takes `[]u8`, not `string`.
4. `get_list` returns `^^List`/`[dynamic]Type`-ish — use `len(lst^)`, not `lst^.length`.
5. Memory is manual: `deep_delete(toml.Type(table))` frees recursively.
6. Author's own caveat in the README: *"Some tests fail because of how odin formats floats & non-printable
   characters, cba to fix that"*. Not a fully-conforming TOML 1.1 implementation.

Alternatives considered:

| Repo | License | Stars | Last push | Verdict |
|---|---|---|---|---|
| `mkozhukh/odin-toml` | MIT | 3 | 2025-08-20 | "comprehensive parser/**serialiser**" — the only one that can *write* TOML. Consider if we must persist config; otherwise unproven. |
| `Hyperquader-Coders/odin-tomlc` | NOASSERTION | 0 | 2026-10-16 | Bindings to `tomlc17`, self-declared **unmaintained, superseded by amber-toml**. Skip. |
| `lumixing/odin_toml`, `TheMoxyFoxy/odin-toml`, `loafoflead/odin-toml` | mixed/none | 0 | stale | Skip. |

**Recommendation:** `Up05/toml_parser` for reading. For **saving the chosen theme**, either (i) hand-write
the one-line TOML (`theme = "…"` is trivially emittable) — recommended, avoids a serialiser dependency — or
(ii) add `mkozhukh/odin-toml` purely for writing. Note: whichever parser is used, saving config must not
clobber unknown keys the user added by hand; a template-preserving write (or writing only the keys we own)
should be a planner decision.

**XDG: roll nothing.** `os.user_config_dir` already implements the spec.
(`dogue/odin-xdg` exists — 0 stars, last push 2024-01 — unnecessary.)

---

## (f) Theme table (name → 16 hex colors), with sources

Slot model (proposed, consistent across all themes; Clay's `Color` is `[4]f32` in 0–255 so hex maps directly):

`bg, bgAlt, bgCrust, surface, surfaceAlt, fg, fgDim, fgMuted, border, accent, red, green, yellow, blue, magenta, cyan`

### Theme list to ship

Required: `catppuccin-latte` (**NOT** the default, per the user).
The **default theme is an open decision** — not specified by the user. `catppuccin-mocha` is the
conventional "goes with anything" pick; `gruvbox-dark` is the other common default. **Planner must choose.**

Suggested names (kebab-case, filter-friendly for the theme list UI):

`catppuccin-mocha`, `catppuccin-macchiato`, `catppuccin-frappe`, `catppuccin-latte`,
`gruvbox-dark`, `gruvbox-light`, `tokyonight-night`, `tokyonight-storm`, `tokyonight-moon`,
`tokyonight-day`, `dracula`, `nord`, `everforest-medium-dark`, `everforest-medium-light`,
`rose-pine`, `rose-pine-moon`, `rose-pine-dawn`, `solarized-dark`, `solarized-light`

### Catppuccin (all four flavors) — source: `catppuccin/palette` `palette.json`, **palette version 1.8.0**
(https://raw.githubusercontent.com/catppuccin/palette/main/palette.json). Each flavor has **26** named colors
(16 accents + 10 neutrals); full set below, and the 16-slot mapping after.

| Slot | latte 🌻 | frappe 🪴 | macchiato 🌺 | mocha 🌿 |
|---|---|---|---|---|
| rosewater | `#dc8a78` | `#f2d5cf` | `#f4dbd6` | `#f5e0dc` |
| flamingo | `#dd7878` | `#eebebe` | `#f0c6c6` | `#f2cdcd` |
| pink | `#ea76cb` | `#f4b8e4` | `#f5bde6` | `#f5c2e7` |
| mauve | `#8839ef` | `#ca9ee6` | `#c6a0f6` | `#cba6f7` |
| red | `#d20f39` | `#e78284` | `#ed8796` | `#f38ba8` |
| maroon | `#e64553` | `#ea999c` | `#ee99a0` | `#eba0ac` |
| peach | `#fe640b` | `#ef9f76` | `#f5a97f` | `#fab387` |
| yellow | `#df8e1d` | `#e5c890` | `#eed49f` | `#f9e2af` |
| green | `#40a02b` | `#a6d189` | `#a6da95` | `#a6e3a1` |
| teal | `#179299` | `#81c8be` | `#8bd5ca` | `#94e2d5` |
| sky | `#04a5e5` | `#99d1db` | `#91d7e3` | `#89dceb` |
| sapphire | `#209fb5` | `#85c1dc` | `#7dc4e4` | `#74c7ec` |
| blue | `#1e66f5` | `#8caaee` | `#8aadf4` | `#89b4fa` |
| lavender | `#7287fd` | `#babbf1` | `#b7bdf8` | `#b4befe` |
| text | `#4c4f69` | `#c6d0f5` | `#cad3f5` | `#cdd6f4` |
| subtext1 | `#5c5f77` | `#b5bfe2` | `#b8c0e0` | `#bac2de` |
| subtext0 | `#6c6f85` | `#a5adce` | `#a5adcb` | `#a6adc8` |
| overlay2 | `#7c7f93` | `#949cbb` | `#939ab7` | `#9399b2` |
| overlay1 | `#8c8fa1` | `#838ba7` | `#8087a2` | `#7f849c` |
| overlay0 | `#9ca0b0` | `#737994` | `#6e738d` | `#6c7086` |
| surface2 | `#acb0be` | `#626880` | `#5b6078` | `#585b70` |
| surface1 | `#bcc0cc` | `#51576d` | `#494d64` | `#45475a` |
| surface0 | `#ccd0da` | `#414559` | `#363a4f` | `#313244` |
| base | `#eff1f5` | `#303446` | `#24273a` | `#1e1e2e` |
| mantle | `#e6e9ef` | `#292c3c` | `#1e2030` | `#181825` |
| crust | `#dce0e8` | `#232634` | `#181926` | `#11111b` |

Proposed 16-slot mapping for the four Catppuccin themes (same mapping for each flavor):

| Slot | latte | frappe | macchiato | mocha |
|---|---|---|---|---|
| bg | `#eff1f5` | `#303446` | `#24273a` | `#1e1e2e` |
| bgAlt | `#e6e9ef` | `#292c3c` | `#1e2030` | `#181825` |
| bgCrust | `#dce0e8` | `#232634` | `#181926` | `#11111b` |
| surface | `#ccd0da` | `#414559` | `#363a4f` | `#313244` |
| surfaceAlt | `#bcc0cc` | `#51576d` | `#494d64` | `#45475a` |
| fg | `#4c4f69` | `#c6d0f5` | `#cad3f5` | `#cdd6f4` |
| fgDim | `#6c6f85` | `#a5adce` | `#a5adcb` | `#a6adc8` |
| fgMuted | `#9ca0b0` | `#737994` | `#6e738d` | `#6c7086` |
| border | `#bcc0cc` | `#51576d` | `#494d64` | `#45475a` |
| accent | `#8839ef` (mauve) | `#ca9ee6` | `#c6a0f6` | `#cba6f7` |
| red | `#d20f39` | `#e78284` | `#ed8796` | `#f38ba8` |
| green | `#40a02b` | `#a6d189` | `#a6da95` | `#a6e3a1` |
| yellow | `#df8e1d` | `#e5c890` | `#eed49f` | `#f9e2af` |
| blue | `#1e66f5` | `#8caaee` | `#8aadf4` | `#89b4fa` |
| magenta | `#ea76cb` (pink) | `#f4b8e4` | `#f5bde6` | `#f5c2e7` |
| cyan | `#179299` (teal) | `#81c8be` | `#8bd5ca` | `#94e2d5` |

### Other palettes

**gruvbox-dark** — source: `morhetz/gruvbox` `gruvbox_256palette.sh` (canonical XResource values)
```
bg        #282828   (dark0)      bgAlt   #32302f  (dark0_medium)   bgCrust #1d2021 (dark0_hard)
surface   #3c3836   (dark1)      sfcAlt  #504945  (dark2)
fg        #ebdbb2   (fg1)        fgDim   #d5c4a1  (fg2)            fgMuted #a89984 (fg4)
border    #504945   (dark2)      accent  #d79921
red       #fb4934   green #b8bb26  yellow  #fabd2f  blue    #83a598
magenta   #d3869b   cyan  #8ec07c  orange  #fe8019  gray    #928374
```

**gruvbox-light** — same source ("bright" dark-variant accents for light backgrounds)
```
bg #fbf1c7 (light0)  bgAlt #f9f5d7 (light0_h)  bgCrust #f2e5bc (light1)
surface #ebdbb2 (light2)  surfaceAlt #d5c4a1 (light3)
fg #3c3836  fgDim #504945  fgMuted #7c6f64  border #d5c4a1
accent #b57614
red #9d0006  green #79740e  yellow #b57614  blue #076678
magenta #8f3f71  cyan #427b58  orange #af3a03
```
(Neutral mid-grays available: `#928374`, `#a89984`, `#bdae93`.)

**tokyonight-night** — source: `folke/tokyonight.nvim` `lua/tokyonight/colors/night.lua` (= `storm.lua` + overrides)
```
bg #1a1b26  bgAlt #16161e  bgCrust #0C0E14  surface #292e42 (bg_highlight)  surfaceAlt #3b4261 (fg_gutter)
fg #c0caf5  fgDim #a9b1d6  fgMuted #565f89 (comment)  border #3b4261
accent #7aa2f7 (blue)
red #f7768e  green #9ece6a  yellow #e0af68  blue #7aa2f7  magenta #bb9af7  cyan #7dcfff
orange #ff9e64  purple #9d7cd8  terminal_black #414868
```
**tokyonight-storm** — same file set, `storm.lua`:
```
bg #24283b  bgAlt #1f2335  bgCrust #1b1e2d  surface #292e42  surfaceAlt #3b4261
fg #c0caf5  fgDim #a9b1d6  fgMuted #565f89  border #3b4261
red #f7768e  green #9ece6a  yellow #e0af68  blue #7aa2f7  magenta #bb9af7  cyan #7dcfff
```
**tokyonight-moon** — `moon.lua`:
```
bg #222436  bgAlt #1e2030  bgCrust #191B29  surface #2f334d  surfaceAlt #444a73
fg #c8d3f5  fgDim #828bb8  fgMuted #636da6  border #3b4261
red #ff757f  green #c3e88d  yellow #ffc777  blue #82aaff  magenta #c099ff  cyan #86e1fc
```
`tokyonight-day` exists but is generated at runtime by colour inversion (`Util.invert`) — **no static hex list**.
Skip or derive; flag as unknown.

**dracula** — source: `dracula/dracula-theme` README "Color Palette (OSS)"

Official colours (all of them):
```
Background   #282a36   Current Line #44475a   Selection #44475a   Foreground #f8f8f2
Comment      #6272a4   Cyan         #8be9fd   Green     #50fa7b   Orange     #ffb86c
Pink         #ff79c6   Purple       #bd93f9   Red       #ff5555   Yellow     #f1fa8c
```
Proposed 16-slot mapping:
```
bg #282a36  bgAlt #44475a  bgCrust #44475a  surface #44475a  surfaceAlt #6272a4
fg #f8f8f2  fgDim #969cbf (derived: comment lightened)  fgMuted #6272a4  border #6272a4
red #ff5555  green #50fa7b  yellow #f1fa8c  blue #8be9fd  magenta #ff79c6  cyan #8be9fd
accent #bd93f9  orange #ffb86c  purple #bd93f9
```
⚠️ **Dracula's official palette only defines 11 named colors**, so several slots must be reused or
derived. There are **no official `bgAlt`/`bgCrust`/`fgDim`** values; the ones above are derived
(`#44475a` current-line reused, `fgDim` lightened from `#6272a4`) and are **not upstream-authoritative**.
Official alt variant **"Alucard"** (light) is documented in the same README:
`bg #fffbeb, currentLine #6c664b, selection #cfcfde, fg #1f1f1f, comment #6c664b,
cyan #036a96, green #14710a, orange #a34d14, pink #a3144d, purple #644ac9, red #cb3a2a, yellow #846e15`.

**nord** — source: `nordtheme/nord` `src/nord.scss` (`$nord0` … `$nord15`). **Exactly 16 colors — maps perfectly.**
```
nord0 #2e3440  nord1 #3b4252  nord2 #434c5e  nord3 #4c566a
nord4 #d8dee9  nord5 #e5e9f0  nord6 #eceff4
nord7 #8fbcbb  nord8 #88c0d0  nord9 #81a1c1  nord10 #5e81ac
nord11 #bf616a nord12 #d08770 nord13 #ebcb8b nord14 #a3be8c nord15 #b48ead
→ bg nord0 · bgAlt nord1 · bgCrust #242933(derived) or nord1 · surface nord2 · surfaceAlt nord3
  fg nord5 · fgDim nord4 · fgMuted nord3 · border nord3 · accent nord8
  red nord11 · green nord14 · yellow nord13 · blue nord9 · magenta nord15 · cyan nord7
```

**everforest (medium, dark)** — source: `sainnhe/everforest` `palette.md`
```
bg #2D353B (bg0)  bgAlt #232A2E (bg_dim)  bgCrust #1E2326 (hard bg0 — different contrast flavour)
surface #343F44 (bg1)  surfaceAlt #3D484D (bg2)
fg #D3C6AA (fg)  fgDim #9DA9A0 (grey2)  fgMuted #859289 (grey1)  border #475258 (bg3)
accent #A7C080 (green)
red #E67E80  green #A7C080  yellow #DBBC7F  blue #7FBBB3  magenta #D699B6  cyan #83C092  orange #E69875
```
Light (medium) foregrounds: `fg #5C6A72`, accents `#F85552 #F57D26 #DFA000 #8DA101 #35A77C #3A94C5 #DF69BA`,
greys `#A6B0A0 #939F91 #829181`; light `bg` variants `#FDF6E3 #EFEBD4 #E6E2CC #E0DCC7`.
Note everforest's *hard/medium/soft* contrast levels = their "flavors"; the table above is **medium dark**.

**rose-pine** — source: `rose-pine/palette` `palette.json` (official, 12 roles per variant)
```
main:  base #191724  surface #1f1d2e  overlay #26233a  muted #6e6a86  subtle #908caa  text #e0def4
       love #eb6f92  gold #f6c177  rose #ebbcba  pine #31748f  foam #9ccfd8  iris #c4a7e7
moon:  base #232136  surface #2a273f  overlay #393552  muted #6e6a86  subtle #908caa  text #e0def4
       love #eb6f92  gold #f6c177  rose #ea9a97  pine #3e8fb0  foam #9ccfd8  iris #c4a7e7
dawn:  base #faf4ed  surface #fffaf3  overlay #f2e9e1  muted #9893a5  subtle #797593  text #464261
       love #b4637a  gold #ea9d34  rose #d7827e  pine #286983  foam #56949f  iris #907aa9
→ 12 roles; map bg=base, bgAlt=surface, bgCrust=overlay(dawn: base), surface=surface, surfaceAlt=overlay,
  fg=text, fgDim=subtle, fgMuted=muted, border=overlay, accent=iris,
  red=love, yellow=gold, blue=pine, cyan=foam, magenta=rose, green≈iris or foam  ⚠️ no green — see unknowns
```

**solarized-dark / solarized-light** — source: `altercation/solarized` README palette table
(official, **exactly 16 colors — maps perfectly**). Light mode = swap the monotone pairs
(base03↔base3, base02↔base2, base01↔base1, base00↔base0); accents are identical in both modes.

| Name | Hex | | Name | Hex |
|---|---|---|---|---|
| base03 | `#002b36` | | yellow | `#b58900` |
| base02 | `#073642` | | orange | `#cb4b16` |
| base01 | `#586e75` | | red | `#dc322f` |
| base00 | `#657b83` | | magenta | `#d33682` |
| base0 | `#839496` | | violet | `#6c71c4` |
| base1 | `#93a1a1` | | blue | `#268bd2` |
| base2 | `#eee8d5` | | cyan | `#2aa198` |
| base3 | `#fdf6e3` | | green | `#859900` |

```
dark:  bg base03 · bgAlt base02 · bgCrust #001f27(derived) or base03 · surface base02 · surfaceAlt base01
       fg base0 · fgDim base01 · fgMuted base00 · border base01
light: bg base3  · bgAlt base2  · bgCrust #e8e2cc(derived) or base2 · surface base2 · surfaceAlt base1
       fg base00 · fgDim base01 · fgMuted base1 · border base1
accents (both modes): red #dc322f green #859900 yellow #b58900 blue #268bd2 magenta #d33682 cyan #2aa198
```

### Naming note
The user wrote "catputin-latte"/"catputcin" in prose. Ship the **canonical spelling `catppuccin-latte`**
(matches the Catppuccin project). If the planner wants forgiving filtering, add an alias list
(`latte`, `catpuccin`, `catppuccin`) rather than a wrong canonical name.

---

## (g) Unknowns / risks

**Packaging**
1. **Default theme is unspecified.** `catppuccin-latte` is explicitly *not* the default; the actual default
   is an open planner decision. Must be a compiled-in constant *and* overridable by config.
2. **`nix develop` / `nix flake show` fail without `--no-pure-eval`** (verified: "devenv was not able to
   determine the current directory"). Keep the package derivation fully independent of devenv. Re-verify
   `nix run .` after adding `packages`.
3. **No `pkgs.buildOdinPackage`** — hand-rolled `stdenv.mkDerivation`. No community reference for
   Odin+Clay-in-nix exists in nixpkgs.
4. **`pkgs.odin` is `dev-*`, not a release.** `odin version` reports `dev-2026-10` while nixpkgs labels it
   `dev-2026-09`. Don't assert version strings in tests. Odin moves fast; a future nixpkgs bump can break
   syntax/API (see #5).
5. **Language-syntax landmines hit while verifying** (the `tui_experiment` predates some of these; treat it as
   loose guidance only): `..` range is **removed** (use `..<` / `..=`); `-o:` is *optimization mode*, output
   is `-out:`; `proc "c"` procs have **no Odin `context`** (an error handler cannot allocate / `fmt` there).
6. **Musl / Windows:** `pkgs.odin` is `broken` on musl; `platforms = lib.platforms.unix`. `import systems`
   includes darwin (fine) but not Windows. If the flake's system list must stay `nix-systems/default`, expect a
   eval-time or build-time failure on musl hosts — consider `lib.filterSystems`/explicit system list.
7. **Do NOT reuse prebuilt `clay.a`/`clay.lib`/`clay.o` blobs** from the experiment; rebuild per-arch in nix.
8. **`clang` is not on PATH in the current devenv shell** (only gcc 16.2). Verified gcc path; if someone
   wants byte-identical-to-upstream objects they'd need to add `pkgs.clang`. **Unknown:** whether a
   clang-built `clay.a` links with odin (very likely fine, untested here).
9. **Runtime PATH deps.** The TUI shells out to `herdr` (`herdr session list --json | attach | stop | delete`)
   and likely `ssh` for remotes. `nix run .` will NOT have them unless the derivation wraps them in.
   `pkgs.herdr` exists (0.9.3), but the user's installed profile is **0.8.2** (per constraints doc) — CLI drift
   risk on `--json` output shape. Decide: (a) `makeWrapper` adding `herdr`/`openssh` to PATH (self-contained
   but pins a version different from the user's), or (b) assume them from the environment (matches how
   `herdr-cycle.sh` works today). **Recommend (b) + a clear error if missing**, since the user manages `herdr`
   via home-manager.
10. **`clay` flake input has no flake** — must be declared `flake = false`; `v0.14` is the latest tag but
    `main` is ahead (last commit 2026-05-20). Pin choice: tag `v0.14` (stable, matches the header's
    `VERSION: 0.14`) vs current `main` rev (matches the binding in this repo's experiment). The binding
    sha256 currently matches **main**.

**Config / TOML**
11. **`Up05/toml_parser` is not fully `toml-test`-clean** by the author's own admission (float/non-printable
    formatting). Acceptable for a small config, but don't rely on round-trip fidelity.
12. **No TOML *writer* chosen.** Config must persist the selected theme. Options: hand-emit the single
    `theme = "…"` line (safe) vs pull `mkozhukh/odin-toml` for full serialisation. Also: preserving
    user-added unknown keys on save is unaddressed.
13. **Config filename vs XDG layout** — `~/.config/herdr_session.toml` (literal requirement) vs
    `$XDG_CONFIG_HOME/herdr_session/config.toml` (spec-idiomatic). Both work with `os.user_config_dir`; needs
    an explicit decision.
14. **No TOML schema frozen yet** (theme key name, remote list key, whether remotes come from `~/.ssh/config`
    instead). Per the constraints doc, the `localhost` test remote must be isolated behind one env var /
    deletable fixture — so remote hosts must come from config or `~/.ssh/config`, never a constant.

**Themes**
15. **Slot model needs freezing.** Palettes have different cardinalities: nord 16 ✓, solarized 16 ✓,
    catppuccin 26 (map down), dracula 11 (map up), rose-pine 12 (**no green channel at all**), everforest 17-ish.
    Rose-Pine in particular has no green — the mapping must either reuse `iris`/`foam` for "green" or drop
    rose-pine from the ship list. Same class of problem for dracula's missing `bgAlt`/`bgCrust`/`fgDim`.
16. **`tokyonight-day` has no static palette** — it's produced by runtime colour inversion in the nvim plugin.
    Skip it or hand-derive hex values (unverified against upstream).
17. **Colour model in Clay is `[4]c.float` 0–255**, not 0.0–1.0. Any conversion from stored hex must match
    what the terminal renderer expects (ANSI 24-bit truecolor `\e[38;2;r;g;bm`). Unknown whether the renderer
    will need *fallback* handling for 8/16-colour-only terminals.

---

## Appendix — verification commands actually run

```bash
# odin present + version
nix eval --raw --impure --expr 'let p=(builtins.getFlake "github:cachix/devenv-nixpkgs/rolling").legacyPackages.x86_64-linux; in p.odin.version'
# → dev-2026-09    (buildOdinPackage → null)
nix build github:cachix/devenv-nixpkgs/rolling#odin --no-link   # substituted from cache.nixos.org
/nix/store/4ycdn…-odin-dev-2026-09/bin/odin version             # → dev-2026-10

# clay compiles with nix gcc
gcc --version   # gcc (GCC) 16.2.0
cp clay.h clay.c && gcc -c -std=c99 -DCLAY_IMPLEMENTATION -ffreestanding -fPIC -O2 -o clay.o clay.c   # OK
nm -u clay.o   # U memcpy, memset, __stack_chk_fail, _GLOBAL_OFFSET_TABLE_

# full link + run
odin build . -out:./herdrtest && ./herdrtest   # clay MinMemorySize = 5785280 bytes; clay_had_error=false
ldd ./herdrtest                               # nix glibc 2.44-25 libc + libm

# sandbox sanity
env -i PATH="$PATH" HOME=/homeless-shelter odin build . -out:./t1   # OK
env -i PATH="$PATH"                          odin build . -out:./t2   # OK

# toml + xdg
XDG_CONFIG_HOME=/tmp/fakecfg ./tomltest
#   /tmp/fakecfg/herdr_session.toml · theme=catppuccin-latte · poll_seconds=5 · remotes len=2 · missing ok=false

# flake status
nix run .            # → error: … does not provide … 'packages.x86_64-linux.default'
nix develop .        # → error: devenv was not able to determine the current directory.
```

### Citations
- Odin package: nixpkgs `pkgs/by-name/od/odin/package.nix`, rev `8edc0c72e3a38faf5434e40d1f19431125fe4b30`; upstream https://github.com/odin-lang/Odin (tag `dev-2026-09`), https://odin-lang.org
- Odin `ols`/`odinfmt`: nixpkgs `pkgs/by-name/ol/ols/package.nix` → https://github.com/DanielGavin/ols (MIT)
- herdr: nixpkgs `pkgs/by-name/he/herdr/package.nix` → https://github.com/herdrdev/herdr v0.9.3 (Apache-2.0)
- Clay: https://github.com/nicbarker/clay — `clay.h` (root), `LICENSE.md` (zlib), `bindings/odin/{README.md,build-clay-lib.sh,clay-odin/clay.odin}`
- Catppuccin: https://github.com/catppuccin/palette `palette.json` v1.8.0
- Gruvbox: https://github.com/morhetz/gruvbox `gruvbox_256palette.sh`
- TokyoNight: https://github.com/folke/tokyonight.nvim `lua/tokyonight/colors/{night,storm,moon,day}.lua`
- Dracula: https://github.com/dracula/dracula-theme README (spec: https://draculatheme.com/spec)
- Nord: https://github.com/nordtheme/nord `src/nord.scss`
- Everforest: https://github.com/sainnhe/everforest `palette.md`
- Rosé Pine: https://github.com/rose-pine/palette `palette.json`
- Solarized: https://github.com/altercation/solarized README (https://ethanschoonover.com/solarized/)
- Odin TOML: https://github.com/Up05/toml_parser (MIT); alt https://github.com/mkozhukh/odin-toml (MIT)
- Odin XDG: `core/os/user.odin` + `core/os/user_posix.odin` in the `pkgs.odin` `$out/share` tree
