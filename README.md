# ryot-nix

Nix packaging + NixOS module for [Ryot](https://github.com/IgnisDa/ryot) — the
self-hosted media & life tracker — built **from source** (upstream ships
container-only; Ryot is not in nixpkgs).

Pinned upstream: **v10.3.18**.

## What this builds

Ryot v10 is three cooperating processes (mirroring the upstream container's
`ci/run-container.sh` + `ci/Caddyfile`):

| Unit            | What                                          | Default port |
|-----------------|-----------------------------------------------|--------------|
| `ryot-backend`  | Rust (axum + async-graphql) GraphQL server    | 5000         |
| `ryot-frontend` | React-Router 7 SSR server (Node)              | 3000         |
| `ryot-proxy`    | Caddy — the entrypoint, path-muxes the two    | 8000         |

Point your reverse proxy at **`ryot-proxy`** (`proxyPort`). It exposes the
`/_i/*` integration webhook (Plex/Jellyfin auto-tracking) and `/backend*`
GraphQL. DB migrations are embedded in the backend and self-apply on boot.

Outputs: `packages.<system>.{ryot,ryot-backend,ryot-frontend}` and
`nixosModules.ryot`.

## Build details

- **Backend**: `rustPlatform.buildRustPackage`, Rust `1.93.1` via `rust-overlay`
  (pinned in `rust-toolchain.toml`), `cargoLock.lockFile` read from the fetched
  source (zero git deps → no `outputHashes`). rustls throughout (no OpenSSL).
  The `lto=true`/`codegen-units=1` release profile makes this a **heavy compile
  — build on a real builder (garnix / x86), not a 4 GB Pi**.
- **Frontend**: Yarn Berry 4.1.1 offline build via
  `yarn-berry_4.{fetchYarnBerryDeps,yarnBerryConfigHook}`, `turbo run build
  --filter=@ryot/frontend`, then `yarn workspaces focus --production`.

## Usage

```nix
{
  inputs.ryot-nix.url = "github:nSimonFR/ryot-nix";

  # in your NixOS config:
  imports = [ inputs.ryot-nix.nixosModules.ryot ];
  services.ryot = {
    enable          = true;
    frontendUrl     = "https://ryot.example.ts.net";
    environmentFile = "/run/agenix/ryot-env";   # see below
  };
}
```

`environmentFile` (KEEP OUT OF THE NIX STORE) must export at least:

```sh
DATABASE_URL=postgresql://ryot:<password>@127.0.0.1:5432/ryot
SERVER_ADMIN_ACCESS_TOKEN=<32+ char random string>
SESSION_SECRET=<random string>
# optional, for video-game metadata:
# VIDEO_GAMES_TWITCH_CLIENT_ID=...
# VIDEO_GAMES_TWITCH_CLIENT_SECRET=...
```

PostgreSQL (≥15) must be provided by the host.

## Bumping

1. Update `version` + the `src` hash in `flake.nix`.
2. Refresh `offlineCache.hash` in `frontend.nix` (yarn deps FOD).
3. The backend `cargoLock` follows the source automatically.
4. Re-sync nothing else — the Caddyfile is pulled from the pinned source.
