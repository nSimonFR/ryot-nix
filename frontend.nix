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
  nodejs_24,
  yarn-berry_4,
  src,
  version,
}:

let
  inherit (yarn-berry_4) fetchYarnBerryDeps yarnBerryConfigHook;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "ryot-frontend";
  inherit version src;

  offlineCache = fetchYarnBerryDeps {
    inherit (finalAttrs) src;
    # Fixed-output: fetches every workspace's deps from the 744 KB yarn.lock.
    # All 3 @patch: entries are Yarn builtins (fsevents/resolve/typescript), so
    # no missing-hashes.json is required.
    hash = lib.fakeHash; # TODO: pin from the FOD build error
  };

  nativeBuildInputs = [
    nodejs_24
    yarn-berry_4
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

    # turbo is a root devDependency; build the frontend + its workspace libs
    # (@ryot/generated, @ryot/graphql, @ryot/ts-utils) via the dependency graph.
    yarn turbo run build --filter=@ryot/frontend

    # Prune node_modules to production deps for the frontend workspace (its deps
    # live in apps/frontend/node_modules due to hoistingLimits=workspaces).
    yarn workspaces focus @ryot/frontend --production

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
