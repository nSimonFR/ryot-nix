#!/usr/bin/env bash
# Recompute Ryot's Nix hashes after Renovate bumps `version` in flake.nix.
#
# Renovate's customManager rewrites the `version = "X.Y.Z"` string in flake.nix,
# then runs this as a postUpgradeTask (arg $1 = the new version). Nix hashes
# can't be computed by Renovate, so we recompute them here, in dependency order:
#   1. src hash          — flake.nix, fetchFromGitHub IgnisDa/ryot (deterministic via nurl)
#   2. missing-hashes.json — regenerated from the new upstream yarn.lock
#   3. offlineCache hash — frontend.nix + templates.nix, the fetchYarnBerryDeps FOD
#
# Each of flake.nix / frontend.nix / templates.nix contains exactly ONE sha256
# literal, so the substitutions are unambiguous. Requires nurl, yarn-berry-fetcher,
# curl, and nix on PATH (the CI workflow installs them).
set -euo pipefail
cd "$(dirname "$0")/.."

ver="${1:-}"
if [ -z "$ver" ]; then
  ver=$(grep -oE 'version = "[^"]+"' flake.nix | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
echo ">> recomputing hashes for ryot v$ver"

# 1. src hash — no build needed; nurl fetches + hashes the tag directly.
newsrc=$(nurl "https://github.com/IgnisDa/ryot" "v$ver" 2>/dev/null \
           | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
[ -n "$newsrc" ] || { echo "ERROR: nurl returned no src hash for v$ver"; exit 1; }
sed -i -E "s#sha256-[A-Za-z0-9+/=]+#$newsrc#" flake.nix
echo ">> src hash        = $newsrc"

# 2. missing-hashes.json — the platform-binary hashes that yarn.lock doesn't
# self-describe; regenerate from the new tag's yarn.lock (idempotent if unchanged).
tmp=$(mktemp)
curl -fsSL "https://raw.githubusercontent.com/IgnisDa/ryot/v$ver/yarn.lock" -o "$tmp"
yarn-berry-fetcher missing-hashes "$tmp" > missing-hashes.json
rm -f "$tmp"
echo ">> regenerated missing-hashes.json"

# 3. offlineCache hash — build the FOD; on hash mismatch, capture the real hash
# and rewrite it in BOTH frontend.nix and templates.nix (same yarn.lock → same hash).
old_oc=$(grep -oE 'sha256-[A-Za-z0-9+/=]+' frontend.nix | head -1)
out=$(nix build ".#ryot-frontend.offlineCache" --no-link --print-out-paths 2>&1) || true
if printf '%s\n' "$out" | grep -q 'hash mismatch'; then
  got=$(printf '%s\n' "$out" | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' \
          | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
  [ -n "$got" ] || { printf '%s\n' "$out"; echo "ERROR: mismatch without a got: hash"; exit 1; }
  sed -i "s#$old_oc#$got#g" frontend.nix templates.nix
  echo ">> offlineCache    = $got (updated)"
  # confirm it now resolves
  nix build ".#ryot-frontend.offlineCache" --no-link >/dev/null
elif printf '%s\n' "$out" | grep -qE '^/nix/store/'; then
  echo ">> offlineCache    = $old_oc (unchanged)"
else
  printf '%s\n' "$out"
  echo "ERROR: offlineCache build failed for a reason other than a hash mismatch"
  exit 1
fi

echo ">> hash recompute complete for ryot v$ver"
