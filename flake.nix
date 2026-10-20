{
  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    systems.url = "github:nix-systems/default";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";

    # Neither upstream ships a flake.
    clay = {
      url = "github:nicbarker/clay/e6cc36941ab2af5d81107617039d6f527a1c660b";
      flake = false;
    };
    termbox2 = {
      # Pinned by REV, not by branch. This used to track `/master`, which meant
      # `nix flake update` silently moved the renderer under a project whose only
      # job is to paint on it — and the README's "fully pinned" claim was only
      # true of flake.lock, not of the input itself. Pinning the rev here makes
      # the pin explicit and intentional: moving termbox2 is now a deliberate edit
      # to this file rather than a side effect of an update command.
      url = "github:termbox/termbox2/48cda6f83a4a1a98d3546beafe55b31a5861c21d";
      flake = false;
    };
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs =
    {
      self,
      nixpkgs,
      devenv,
      systems,
      ...
    }@inputs:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);

      # Linux only (plan D6): pkgs.odin is broken on musl and this project targets
      # glibc Linux exclusively.
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];

      # Built per-system but shared with the package derivation so there is exactly one
      # nixpkgs instance in this flake (devenv follows `nixpkgs` too).
      libclay = system: nixpkgs.legacyPackages.${system}.callPackage ./nix/clay.nix {
        clay-src = inputs.clay;
      };

      libtermbox2 = system: nixpkgs.legacyPackages.${system}.callPackage ./nix/termbox2.nix {
        termbox2-src = inputs.termbox2;
      };
    in
    {
      # The package derivation is intentionally independent of devenv: `nix develop`
      # and `nix flake show` cannot evaluate devenv in this repo without
      # --no-pure-eval, and `nix build` must not inherit that problem.
      packages = nixpkgs.lib.genAttrs linuxSystems (system: {
        default = nixpkgs.legacyPackages.${system}.callPackage ./nix/package.nix {
          clay = libclay system;
          clay-src = inputs.clay;
          termbox2 = libtermbox2 system;
        };

        clayLib = libclay system;
        termbox2Lib = libtermbox2 system;
      });

      devShells = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              {
                # https://devenv.sh/reference/options/
                packages = [ pkgs.hello ];

                enterShell = ''
                  hello
                '';

                processes.hello.exec = "hello";
              }
            ];
          };
        }
      );
    };
}
