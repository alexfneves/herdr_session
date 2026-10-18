# herdr-session — hand-rolled because `pkgs.buildOdinPackage` does not exist in
# nixpkgs (verified: null). Nothing here touches devenv, so `nix build`/`nix run`
# stay green even though `nix develop` needs --no-pure-eval in this repo.
#
# Layout note: Clay's Odin binding hard-codes `foreign import Clay "linux/clay.a"`,
# resolved relative to clay.odin *itself*. So we stage exactly
#   clay-odin/clay.odin          (copied verbatim from the clay input)
#   clay-odin/linux/clay.a       (our in-derivation archive)
# with zero patching of upstream source. Same trick for termbox2's archive.
{
  lib,
  stdenv,
  odin,
  clay,
  clay-src,
  termbox2,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "herdr-session";
  version = "0.1.0";

  # Only the sources go into the store — not .pi plans, docs or devenv caches.
  src = lib.cleanSourceWith {
    src = ../.;
    filter = path: _type:
      let
        root = toString ../.;
        rel = lib.removePrefix (root + "/") (toString path);
      in
      rel == "src" || rel == "vendor" || lib.any (p: lib.hasPrefix p rel) [ "src/" "vendor/" ];
  };

  nativeBuildInputs = [ odin ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    # Clay's Odin binding resolves `foreign import Clay "linux/clay.a"` relative to
    # clay.odin itself, so stage the upstream binding next to our in-derivation archive
    # in the layout it expects. Zero patching of upstream source.
    mkdir -p clay-odin/linux
    cp ${clay-src}/bindings/odin/clay-odin/clay.odin clay-odin/clay.odin
    cp ${clay}/lib/libclay.a clay-odin/linux/clay.a

    mkdir -p vendor/termbox2-odin/lib
    cp ${termbox2}/lib/libtermbox2.a vendor/termbox2-odin/lib/libtermbox2.a

    # `-o:speed` is this Odin's optimisation flag. (`-out:` sets the output path;
    # `-mode:release` no longer exists in pkgs.odin dev-2026-09.) `-vet` is on so an
    # unused import or dead branch cannot reach the build.
    #
    # `--library-path,/` is required, not cosmetic: Odin emits these archives as
    # `-l:<absolute path>`, which GNU ld resolves by *joining* each -L dir with the
    # name, so it needs `/` in the search path. The nix cc-wrapper drops a bare
    # `-L/`, so we pass the long option form (verified: `-Wl,-L/` fails,
    # `-Wl,--library-path,/` links).
    odin build src -out:herdr-session -o:speed -vet -extra-linker-flags=-Wl,--library-path,/

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 herdr-session $out/bin/herdr-session
    runHook postInstall
  '';

  meta = {
    description = "Keyboard-driven herdr session manager TUI (Odin + Clay + termbox2)";
    license = lib.licenses.asl20;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "herdr-session";
  };
})
