{
  description = "balatro-switch-rce: build environment for the Balatro savedata launcher";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems
          (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            # Build driver, metadata encoder and RPC client (stdlib only),
            # plus Pillow for the screenshot renderer (tools/screenshot.py).
            (pkgs.python3.withPackages (ps: [ ps.pillow ]))
            # Lua syntax checks, offline test harness and the stamp.lua
            # fingerprint cross-check.
            pkgs.luajit
          ];
        };
      });
    };
}
