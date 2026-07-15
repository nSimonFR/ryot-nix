{
  description = "Nix packaging for Ryot — the self-hosted media & life tracker (IgnisDa/ryot)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    # Ryot pins Rust 1.93.1 (rust-toolchain.toml); nixpkgs stable lags, so pull
    # the exact channel from rust-overlay.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { self, nixpkgs, flake-parts, rust-overlay, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { system, ... }:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
          };

          # Single source of truth for the upstream tag + tarball, shared by the
          # backend (Rust) and frontend (Node) derivations so they never drift.
          version = "10.4.0";
          src = pkgs.fetchFromGitHub {
            owner = "IgnisDa";
            repo = "ryot";
            rev = "v${version}";
            hash = "sha256-MGUz4hzj2OezwUiH3RMxz17fOOz37I3o7STAq8MF1hk=";
          };

          templates = pkgs.callPackage ./templates.nix { inherit src version; };
          backend = pkgs.callPackage ./backend.nix { inherit src version templates; };
          frontend = pkgs.callPackage ./frontend.nix { inherit src version; };
          ryot = pkgs.callPackage ./package.nix { inherit src version backend frontend; };
        in
        {
          packages = {
            inherit backend frontend ryot templates;
            ryot-backend = backend;
            ryot-frontend = frontend;
            ryot-templates = templates;
            default = ryot;
          };
        };

      flake = {
        nixosModules.ryot = import ./module.nix self;
        nixosModules.default = self.nixosModules.ryot;
      };
    };
}
