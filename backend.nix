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
#   compile is slow and RAM-hungry. On the 4 GB Pi, stop heavy services first
#   (nixos-rebuild-safe) or build it on an x86 box and push to a binary cache.
# - crates/utils/env reads APP_VERSION + UNKEY_ROOT_KEY via env!() at COMPILE
#   time (not build.rs), so both must be present in the build environment or the
#   `env-utils` crate fails with "environment variable not defined at compile
#   time". Upstream CI sets APP_VERSION=<tag> and UNKEY_ROOT_KEY=<secret>;
#   UNKEY_ROOT_KEY is only used for Ryot's hosted licensing, so "" is correct
#   for a self-hosted (community) build. See ci main.yml build-backend step.
{
  lib,
  stdenv,
  makeRustPlatform,
  rust-bin,
  pkg-config,
  src,
  version,
  templates,
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

  # The notification crate embeds HTML via askama `#[template(path=...)]` at
  # compile time, but the repo .gitignore's every `templates/` dir so the source
  # tarball omits them. Drop the react-email-rendered HTML (see templates.nix)
  # into the crate before cargo build, mirroring upstream's `copy-templates`.
  postPatch = ''
    mkdir -p crates/services/notification/templates
    cp -a ${templates}/. crates/services/notification/templates/
  '';

  nativeBuildInputs = [ pkg-config ];

  # No tests in the release build path; the workspace test suite needs a live DB.
  doCheck = false;

  # Compile-time env!() vars read by crates/utils/env (see header note).
  # APP_VERSION matches upstream's tag format ("v<version>"); UNKEY_ROOT_KEY is
  # unused in self-hosted builds so an empty string is correct.
  env = {
    APP_VERSION = "v${version}";
    UNKEY_ROOT_KEY = "";

    # Disable upstream's release-profile whole-program LTO (lto=true,
    # codegen-units=1). That combo is a deliberately slow, very RAM-hungry
    # optimization — on the 4 GB Pi the final LTO link OOM-thrashes and pushes the
    # compile past 40 min. These CARGO_PROFILE_RELEASE_* env vars override the
    # Cargo.toml profile at build time; the binary is marginally larger / slightly
    # less optimized, which is irrelevant for a self-hosted tracker but cuts the
    # compile and its peak memory dramatically. Drop these to restore upstream LTO
    # if building on a big x86 box + pushing to a binary cache.
    CARGO_PROFILE_RELEASE_LTO = "false";
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
  };

  # Single-member workspace → the default build already yields just `backend`.
  meta = {
    description = "Ryot backend — axum + async-graphql GraphQL server";
    homepage = "https://github.com/IgnisDa/ryot";
    license = lib.licenses.gpl3Only;
    mainProgram = "backend";
    platforms = lib.platforms.linux;
  };
}
