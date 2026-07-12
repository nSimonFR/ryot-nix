# Ryot frontend — the React-Router 7 (SSR) Node app.
#
# Mirrors the repo Dockerfile's frontend stages, minus `turbo prune` (an image-
# size optimization we don't need — we build the target from the full workspace
# and let turbo's `--filter` pull in only its transitive deps):
#   1. yarnBerryConfigHook  → offline `yarn install` from a fixed-output cache.
#   2. turbo run build --filter=@ryot/frontend → Vite/React-Router build into
#      apps/frontend/build.
#   3. yarn workspaces focus @ryot/frontend --production → prune to runtime deps.
#
# Yarn Berry 4.1.1 (packageManager pin), nodeLinker: node-modules. The frontend
# workspace sets `installConfig.hoistingLimits = "workspaces"`, so its deps land
# in apps/frontend/node_modules (not hoisted to the root) — exactly what the
# Dockerfile copies and what react-router-serve needs at runtime.
#
# Output: $out/share/ryot-frontend/{build,node_modules,package.json} plus a
# `ryot-frontend` wrapper that runs the SSR server (react-router-serve).
{
  lib,
  stdenv,
  fetchFromGitHub,
  nodejs_24,
  yarn-berry_4,
  src,
  version,
}:

let
  # nixpkgs' yarn-berry_4 is 4.14.1, but Ryot pins yarn 4.1.1. A newer yarn treats
  # Ryot's version-8 lockfile as stale (lockfileNeedsRefresh = 8 < 9) and runs a
  # NETWORK resolution step — which fails in the sandbox (EAI_AGAIN). Pin yarn to
  # the exact 4.1.1 that wrote the lockfile so no refresh/resolution happens and
  # the install stays fully offline. (berry builds offline from its committed
  # zero-install cache, so no extra deps fetch.)
  yarnBerry = yarn-berry_4.overrideAttrs (_: {
    version = "4.1.1";
    src = fetchFromGitHub {
      owner = "yarnpkg";
      repo = "berry";
      tag = "@yarnpkg/cli/4.1.1";
      hash = "sha256-75bERA1uZeywMjYznFDyk4+AtVDLo7eIajVtWdAD/RA=";
    };
  });
  inherit (yarnBerry) fetchYarnBerryDeps yarnBerryConfigHook;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "ryot-frontend";
  inherit version src;

  # The config hook validates $missingHashes (a derivation-level var) against the
  # copy baked into offlineCache, so it must be set here too — not only inside
  # fetchYarnBerryDeps.
  missingHashes = ./missing-hashes.json;

  offlineCache = fetchYarnBerryDeps {
    inherit (finalAttrs) src;
    # Platform-specific optional binaries (e.g. @biomejs/cli-darwin-arm64,
    # @rollup/rollup-*, esbuild-*) have no self-describing hash in yarn.lock, so
    # the fetcher needs them supplied. Regenerate on bump with:
    #   yarn-berry-fetcher missing-hashes yarn.lock > missing-hashes.json
    missingHashes = ./missing-hashes.json;
    hash = "sha256-lqNKHtGSRyQkD2OK8pP9gnqq6+ASdshPaxeLrmxHroI=";
  };

  # Drop the yarnPath launcher pin so the (matching-4.1.1) nixpkgs yarn is used
  # rather than re-execing the project's committed, non-offline-patched binary.
  postPatch = ''
    substituteInPlace .yarnrc.yml \
      --replace-fail 'yarnPath: .yarn/releases/yarn-4.1.1.cjs' ""
  '';

  nativeBuildInputs = [
    nodejs_24
    yarnBerry
    yarnBerryConfigHook # runs `yarn install --immutable` from offlineCache
  ];

  env = {
    CI = "1";
    TURBO_TELEMETRY_DISABLED = "1";
    DO_NOT_TRACK = "1";
    # node-gyp (if any native addon rebuilds) resolves headers offline.
    npm_config_nodedir = "${nodejs_24}";
  };

  buildPhase = ''
    runHook preBuild

    # Invoke turbo directly (not via `yarn`) so no second lockfile check can reach
    # for the network. turbo is a root devDependency; --filter builds the frontend
    # plus its workspace libs (@ryot/generated, @ryot/graphql, @ryot/ts-utils).
    # We ship the full install rather than `yarn workspaces focus --production`
    # (which would trigger a second, network-touching resolve).
    ./node_modules/.bin/turbo run build --filter=@ryot/frontend

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    dest=$out/share/ryot-frontend
    mkdir -p "$dest"
    cp -a apps/frontend/build         "$dest/build"
    cp -a apps/frontend/node_modules  "$dest/node_modules"
    cp -a apps/frontend/package.json  "$dest/package.json"

    mkdir -p $out/bin
    cat > $out/bin/ryot-frontend <<EOF
    #!${stdenv.shell}
    cd $dest
    exec ${nodejs_24}/bin/node \
      $dest/node_modules/@react-router/serve/bin.js \
      $dest/build/server/index.js "\$@"
    EOF
    chmod +x $out/bin/ryot-frontend

    runHook postInstall
  '';

  # node_modules ships prebuilt native addons from the yarn cache; don't let
  # fixup mangle them.
  dontStrip = true;

  meta = {
    description = "Ryot frontend — React-Router 7 SSR server";
    homepage = "https://github.com/IgnisDa/ryot";
    license = lib.licenses.gpl3Only;
    mainProgram = "ryot-frontend";
    platforms = lib.platforms.linux;
  };
})
