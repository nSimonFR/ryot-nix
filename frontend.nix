# Ryot frontend — the React-Router 7 (SSR) Node app.
#
# Mirrors the repo Dockerfile's frontend stages, minus `turbo prune` (an image-
# size optimization we don't need — we build the target from the full workspace
# and let turbo's `--filter` pull in only its transitive deps):
#   1. yarnBerryConfigHook  → offline `yarn install` from a fixed-output cache.
#   2. turbo run build --filter=@ryot/frontend → Vite/React-Router build into
#      apps/frontend/build.
#
# Yarn Berry, nodeLinker: node-modules. The frontend workspace sets
# `installConfig.hoistingLimits = "workspaces"`, so its deps land in
# apps/frontend/node_modules (not hoisted to the root) — exactly what the
# Dockerfile copies and what react-router-serve needs at runtime.
#
# Output: $out/share/ryot-frontend/{build,node_modules,package.json} plus a
# `ryot-frontend` wrapper that runs the SSR server (react-router-serve).
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

  # Version skew: nixpkgs' yarn-berry_4 is 4.14.1, but Ryot's lockfile was written
  # by yarn 4.1.1 and is `__metadata.version: 8`. yarn 4.14.1 targets lockfile
  # version 9, so it treats v8 as stale (lockfileNeedsRefresh) and runs a NETWORK
  # resolution step → EAI_AGAIN in the sandbox. Downgrading yarn to 4.1.1 is not
  # an option (nixpkgs' berry-4 offline patch doesn't apply to 4.1.1). Instead
  # relabel the lockfile v8→v9: the v8→v9 delta is only added .yarnrc settings
  # (approvedGitRepositories, enableScripts), not lockfile-entry format, so the
  # existing resolutions stay valid — and 4.14.1 now sees a current lockfile and
  # installs fully offline. The anchor (line after `__metadata:`) avoids touching
  # any package whose version happens to be `8`.
  lockV9Src = applyPatches {
    inherit src;
    name = "ryot-src-lock-v9";
    postPatch = ''
      sed -i '/^__metadata:/{n;s/^  version: 8$/  version: 9/}' yarn.lock
    '';
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "ryot-frontend";
  inherit version;
  src = lockV9Src;

  # The config hook validates $missingHashes (a derivation-level var) against the
  # copy baked into offlineCache, so it must be set here too — not only inside
  # fetchYarnBerryDeps.
  missingHashes = ./missing-hashes.json;

  offlineCache = fetchYarnBerryDeps {
    inherit (finalAttrs) src; # the v9-relabelled tree, so the config hook's
    # source-vs-offline yarn.lock consistency check passes.
    # Platform-specific optional binaries (e.g. @biomejs/cli-darwin-arm64,
    # @rollup/rollup-*, esbuild-*) have no self-describing hash in yarn.lock, so
    # the fetcher needs them supplied. Regenerate on bump with:
    #   yarn-berry-fetcher missing-hashes yarn.lock > missing-hashes.json
    missingHashes = ./missing-hashes.json;
    hash = "sha256-dehAH4W/uDurdCPFkwlgSkpciodslojWd0TxCTUb0L8="; # offline output embeds the v9 yarn.lock
  };

  # Drop the yarnPath launcher pin so the nixpkgs yarn (offline-patched) is used
  # rather than re-execing the project's committed, non-patched 4.1.1 binary.
  postPatch = ''
    substituteInPlace .yarnrc.yml \
      --replace-fail 'yarnPath: .yarn/releases/yarn-4.1.1.cjs' ""

    # Serve the SSR frontend under the /ryot/ sub-path (fronted by the nic-os
    # single 443 Tailscale-Funnel front-proxy; Ryot's SPA has no runtime base
    # support so this must be baked in at build time). React-Router 7 `basename`
    # + matching Vite `base`, both trailing-slash. Touches only *.config.ts, NOT
    # yarn.lock, so the offlineCache/missingHashes FOD hashes stay valid.
    substituteInPlace apps/frontend/react-router.config.ts \
      --replace-fail 'ssr: true,' 'ssr: true, basename: "/ryot/",'
    substituteInPlace apps/frontend/vite.config.ts \
      --replace-fail 'export default defineConfig({' 'export default defineConfig({ base: "/ryot/",'
  '';

  nativeBuildInputs = [
    nodejs_24
    yarn-berry_4
    yarnBerryConfigHook # runs `yarn install --immutable` from offlineCache
  ];

  env = {
    CI = "1";
    TURBO_TELEMETRY_DISABLED = "1";
    DO_NOT_TRACK = "1";
    # `CI=1` makes yarn enable immutable installs, which rejects the offline yarn's
    # in-place rewrite of the typescript builtin-compat @patch checksum (a purely
    # local recompute — the offline-patched yarn hashes it differently than the
    # yarn that wrote the lock). Allow that rewrite; it needs no network.
    YARN_ENABLE_IMMUTABLE_INSTALLS = "false";
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

    # The @ryot/* workspace deps are bundled into build/server by Vite at build
    # time (the upstream container ships these same node_modules symlinks dangling
    # and runs fine), so their now-broken links are unused at runtime. Drop all
    # broken symlinks so the store path is self-contained (stdenv noBrokenSymlinks).
    find "$dest/node_modules" -xtype l -delete

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
