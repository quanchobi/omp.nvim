{
  description = "omp.nvim: send editor context to a running omp session from Neovim";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      version = "0.4.0";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Sources the checks need; docs and Nix files don't invalidate them.
      testSrc = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./lua
          ./plugin
          ./extension
          ./tests
          ./.luacheckrc
          ./.stylua.toml
        ];
      };
      check =
        pkgs: name: inputs: script:
        pkgs.runCommand "omp-nvim-${name}" { nativeBuildInputs = inputs; } ''
          cp -r ${testSrc} src && chmod -R u+w src && cd src
          export HOME=$TMPDIR
          ${script}
          touch $out
        '';
    in
    {
      overlays.default = final: prev: {
        vimPlugins = prev.vimPlugins.extend (
          _: _: { omp-nvim = final.callPackage ./nix/package.nix { inherit version; }; }
        );
      };

      packages = forAllSystems (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.omp-nvim;
        omp-nvim = pkgs.callPackage ./nix/package.nix { inherit version; };
      });

      # Installs the bridge into omp's extension dirs (programs.omp-nvim).
      homeModules.default = import ./nix/hm-module.nix self;
      # Adds the Neovim plugin (plugins.omp-nvim).
      nixvimModules.default = import ./nix/nixvim-module.nix self;

      checks = forAllSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        lua-tests = check pkgs "lua-tests" [
          pkgs.neovim-unwrapped
          pkgs.git
        ] "nvim --headless --clean -l tests/run.lua";
        bridge-tests = check pkgs "bridge-tests" [ pkgs.bun ] "bun test tests/bridge.test.ts";
        lint = check pkgs "lint" [
          pkgs.stylua
          pkgs.luajitPackages.luacheck
        ] "stylua --check . && luacheck lua plugin tests";
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim-unwrapped
            pkgs.git
            pkgs.bun
            pkgs.stylua
            pkgs.luajitPackages.luacheck
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
