# termbox2 is a single-header terminal renderer (MIT). Upstream ships no build
# system we need, so we compile the `TB_IMPL` translation unit in-derivation.
#
# TB_OPT_ATTR_W 32 is MANDATORY: the default is 16, which silently quantises every
# theme colour (plan D4/D5 need TB_OUTPUT_TRUECOLOR). No ncurses/terminfo dep.
#
# ⚠️ Deliberately NO -Werror: termbox2 warns about ignored write()/read() results
# in its signal handler, which is intentional upstream.
{
  lib,
  stdenv,
  termbox2-src,
}:
stdenv.mkDerivation {
  pname = "termbox2";
  version = "0-unreleased-master";

  src = termbox2-src;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    cp $src/termbox2.h .
    printf '#define TB_IMPL\n#define TB_OPT_ATTR_W 32\n#include "termbox2.h"\n' > tb_impl.c

    $CC -c -std=c99 -O2 -fPIC -o tb_impl.o tb_impl.c
    ar rcs libtermbox2.a tb_impl.o

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 libtermbox2.a $out/lib/libtermbox2.a
    runHook postInstall
  '';

  meta = {
    description = "termbox2 terminal renderer, built as a static archive with 32-bit (truecolor) attributes";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
