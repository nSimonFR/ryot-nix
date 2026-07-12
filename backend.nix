# Ryot backend — the Rust (axum + async-graphql) server binary.
#
# Upstream ships this as a pre-cross-compiled artifact copied into the Docker
# image (see the repo Dockerfile's `artifact` stage); here we compile it from
# source. The Cargo workspace has a single member (apps/backend → bin `backend`),
# so a plain workspace build produces exactly the one binary we want.
#
# Notes:
# - Rust 1.93.1 is pinned by rust-toolchain.toml; provided via rust-overlay.
# - TLS is rustls end-to-end (reqwest/sqlx/sea-orm features) → NO OpenSSL, so no
#   openssl buildInput and no OPENSSL_* env needed.
# - The lone build.rs (crates/utils/env) just calls dotenv_build::output, which
#   emits cargo directives and tolerates a missing .env → no build-time config.
# - Allocator is tikv-jemallocator (jemalloc vendored & built by the crate; the
#   stdenv C toolchain covers it).
# - DB migrations are embedded (crates/migrations, sea-orm-migration) and run at
#   startup, so there is nothing DB-related at build time.
# - Release profile sets lto=true + codegen-units=1 (upstream Cargo.toml): the
#   compile is slow and RAM-hungry — build it on a real builder (garnix/x86),
#   never on a 4 GB Pi.
{
  lib,
  stdenv,
  makeRustPlatform,
  rust-bin,
  pkg-config,
  src,
  version,
}:

let
  rustToolchain = rust-bin.stable."1.93.1".default;
  rustPlatform = makeRustPlatform {
    cargo = rustToolchain;
    rustc = rustToolchain;
  };
in
rustPlatform.buildRustPackage {
  pname = "ryot-backend";
  inherit version src;

  cargoLock = {
    lockFile = "${src}/Cargo.lock";
  };

  nativeBuildInputs = [ pkg-config ];

  # No tests in the release build path; the workspace test suite needs a live DB.
  doCheck = false;

  # Single-member workspace → the default build already yields just `backend`.
  meta = {
    description = "Ryot backend — axum + async-graphql GraphQL server";
    homepage = "https://github.com/IgnisDa/ryot";
    license = lib.licenses.gpl3Only;
    mainProgram = "backend";
    platforms = lib.platforms.linux;
  };
}
