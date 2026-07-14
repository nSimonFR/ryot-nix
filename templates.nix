# Ryot email templates — the compile-time HTML the Rust backend embeds.
#
# The backend's notification-service crate does `#[template(path = "generic.html")]`
# (askama), reading HTML from crates/services/notification/templates/ AT COMPILE
# TIME. Those HTML files are NOT in the source tree: the repo .gitignore ignores
# every `templates/` dir, and the files are generated from React-Email `.tsx`
# sources in libs/transactional (`email export` → out/, then copy-templates → the
# notification crate). fetchFromGitHub therefore ships the crate without them and
# `cargo build` fails with `template "generic.html" not found`.
#
# This derivation reproduces upstream's generation step (libs/transactional
# `build` = `email export`) using the same offline yarn workspace as frontend.nix,
# and exposes the rendered HTML in $out. backend.nix copies $out into the crate's
# templates dir before building.
{
  lib,
  stdenv,
  applyPatches,
  nodejs_24,
  yarn-berry_4,
  src,
  version,
}:

let
  inherit (yarn-berry_4) fetchYarnBerryDeps yarnBerryConfigHook;

  # Same v8→v9 lockfile relabel as frontend.nix (see the rationale there): lets
  # nixpkgs' yarn 4.14.1 install fully offline instead of a network re-resolve.
  lockV9Src = applyPatches {
    inherit src;
    name = "ryot-src-lock-v9-templates";
    postPatch = ''
      sed -i '/^__metadata:/{n;s/^  version: 8$/  version: 9/}' yarn.lock
    '';
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "ryot-email-templates";
  inherit version;
  src = lockV9Src;

  missingHashes = ./missing-hashes.json;

  # Identical offline cache to frontend.nix — the whole workspace is installed, so
  # @ryot/transactional's deps (react-email, @react-email/components) are present.
  offlineCache = fetchYarnBerryDeps {
    inherit (finalAttrs) src;
    missingHashes = ./missing-hashes.json;
    hash = "sha256-dehAH4W/uDurdCPFkwlgSkpciodslojWd0TxCTUb0L8=";
  };

  postPatch = ''
    substituteInPlace .yarnrc.yml \
      --replace-fail 'yarnPath: .yarn/releases/yarn-4.1.1.cjs' ""
  '';

  nativeBuildInputs = [
    nodejs_24
    yarn-berry_4
    yarnBerryConfigHook
  ];

  env = {
    CI = "1";
    TURBO_TELEMETRY_DISABLED = "1";
    DO_NOT_TRACK = "1";
    YARN_ENABLE_IMMUTABLE_INSTALLS = "false";
    npm_config_nodedir = "${nodejs_24}";
  };

  buildPhase = ''
    runHook preBuild

    # `email export` (the @ryot/transactional `build` script) renders emails/*.tsx
    # → libs/transactional/out/*.html. Invoke turbo directly (not via yarn) so no
    # second lockfile check reaches for the network.
    ./node_modules/.bin/turbo run build --filter=@ryot/transactional

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -a libs/transactional/out/. $out/
    # sanity: the backend needs at least generic.html
    test -f $out/generic.html || { echo "ERROR: generic.html not rendered"; ls -la $out; exit 1; }
    runHook postInstall
  '';

  dontStrip = true;

  meta = {
    description = "Ryot email templates (react-email → HTML) for the backend's askama compile-time include";
    homepage = "https://github.com/IgnisDa/ryot";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
})
