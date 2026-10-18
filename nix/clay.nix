# Clay is a single-header C library (zlib license). We compile the implementation
# translation unit here so nothing prebuilt ever enters this repository (ISC-A-9).
#
# Flags are the ones verified against nixpkgs GCC 16.2:
#   -std=c99        Clay's C99 floor
#   -ffreestanding  Clay does not depend on a hosted C runtime
#   -fPIC           linked into the final executable from a static archive
#
# ⚠️ Deliberately NO -Werror: Clay emits unused-variable warnings under -Wall and
# the upstream source is not ours to fix.
{
  lib,
  stdenv,
  clay-src,
}:
stdenv.mkDerivation {
  pname = "clay";
  version = "0.14";

  src = clay-src;

  # No configure/test phase applies to a hand-rolled archive build.
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    cp $src/clay.h .
    printf '#define CLAY_IMPLEMENTATION\n#include "clay.h"\n' > clay_impl.c

    $CC -c -std=c99 -ffreestanding -fPIC -O2 -o clay_impl.o clay_impl.c
    ar rcs libclay.a clay_impl.o

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 libclay.a $out/lib/libclay.a
    runHook postInstall
  '';

  meta = {
    description = "Clay layout engine, built as a static archive for the Odin binding";
    license = lib.licenses.zlib;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
