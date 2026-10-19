#!/usr/bin/env bash
# Local fast build (dev only) — mirrors nix/package.nix's odin invocation.
export PATH=/nix/store/4ycdn03zvpadrpwb7c43gnr0gr23k597-odin-dev-2026-09/bin:$PATH
odin build src -out:/tmp/hs-local -o:speed -vet -extra-linker-flags=-Wl,--library-path,/ "$@"
