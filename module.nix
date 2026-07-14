# NixOS module for Ryot — self-hosted media & life tracker (docs.ryot.io).
#
# Usage in nic-os (or any NixOS flake):
#
#   inputs.ryot-nix.url = "github:nSimonFR/ryot-nix";
#   imports = [ inputs.ryot-nix.nixosModules.ryot ];
#   services.ryot = {
#     enable          = true;
#     frontendUrl     = "https://ryot.example.ts.net";
#     environmentFile = "/run/agenix/ryot-env";
#   };
#
# The environmentFile must export at least:
#   DATABASE_URL=postgresql://ryot:<password>@127.0.0.1:5432/ryot
#   SERVER_ADMIN_ACCESS_TOKEN=<32+ char random string>
#   SESSION_SECRET=<random string>            # frontend cookie signing
# (plus optional provider tokens, e.g. VIDEO_GAMES_TWITCH_CLIENT_ID/SECRET).
#
# Ryot v10 runs as THREE processes (mirrors the upstream container's
# ci/run-container.sh + ci/Caddyfile), wired here as three systemd units:
#   - ryot-backend : Rust axum/GraphQL server (BACKEND_PORT, default 5000)
#   - ryot-frontend: React-Router SSR server  (FRONTEND_PORT, default 3000)
#   - ryot-proxy   : Caddy, the real entrypoint (proxyPort, default 8000), which
#                    path-muxes the two and exposes the /_i/* integration webhook
#                    (Plex/Jellyfin auto-tracking) → backend /webhooks/integrations.
# The frontend's SSR calls the backend THROUGH the proxy (API_URL defaults to
# <proxy>/backend), so point reverse proxies / tailscale-serve at proxyPort.
#
# DB migrations are embedded in the backend and self-apply on boot, so there is
# no migrate oneshot — the app just needs a reachable PostgreSQL (provided by
# the host).
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.ryot;

  # Use the flake's own prebuilt package (what garnix builds for aarch64), so the
  # host never re-compiles the heavy Rust/Node build. Overridable via the option.
  defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.ryot;

  loopback = "127.0.0.1";
in
{
  options.services.ryot = {
    enable = lib.mkEnableOption "Ryot self-hosted media & life tracker";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "The combined Ryot derivation (backend + frontend + Caddyfile).";
    };

    frontendUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://ryot.example.ts.net";
      description = "Public URL Ryot is served from → FRONTEND_URL (absolute links, share URLs).";
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Loopback port for the Rust backend (BACKEND_PORT).";
    };
    frontendPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Loopback port for the React-Router SSR server (FRONTEND_PORT).";
    };
    proxyPort = lib.mkOption {
      type = lib.types.port;
      default = 8000;
      description = ''
        Port the Caddy proxy listens on — THE service entrypoint. Point your
        reverse proxy / tailscale-serve here (not at the backend/frontend).
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a KEY=VALUE secrets file (kept out of the world-readable Nix
        store). Supply DATABASE_URL, SERVER_ADMIN_ACCESS_TOKEN and SESSION_SECRET
        here, plus any optional provider tokens. Applied to backend + frontend.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ryot";
      description = "Writable state dir (backend apalis-sqlite job queue / caches).";
    };

    user = lib.mkOption { type = lib.types.str; default = "ryot"; };
    group = lib.mkOption { type = lib.types.str; default = "ryot"; };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { DISABLE_TELEMETRY = "true"; };
      description = "Extra environment variables merged into the backend service.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = lib.mkIf (cfg.user == "ryot") {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = false;
    };
    users.groups.${cfg.group} = lib.mkIf (cfg.group == "ryot") { };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
    ];

    # Shared hardening for all three units. PrivateUsers is forced OFF: the RPi5
    # kernel has no user namespaces (same gotcha as the pg-setup oneshots).
    systemd.services =
      let
        hardening = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;
          Restart = "on-failure";
          RestartSec = "5s";
          StateDirectory = "ryot";
          WorkingDirectory = cfg.stateDir;

          PrivateUsers = lib.mkForce false;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ cfg.stateDir ];
          ProtectHome = true;
          PrivateTmp = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          # AF_NETLINK is required by the Node frontend: react-router-serve calls
          # os.networkInterfaces() on listen (to print its startup URL), which uses
          # a netlink socket. Without it the frontend crash-loops with
          # "uv_interface_addresses returned ... EAFNOSUPPORT (97)".
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
          LockPersonality = true;
          RestrictRealtime = true;
        } // lib.optionalAttrs (cfg.environmentFile != null) {
          EnvironmentFile = cfg.environmentFile;
        };
      in
      {
        # ── backend: Rust axum + async-graphql, self-migrates on boot ─────────
        ryot-backend = {
          description = "Ryot backend (GraphQL server)";
          after = [ "network.target" "postgresql.service" ];
          requires = [ "postgresql.service" ];
          wantedBy = [ "multi-user.target" ];
          environment = {
            # Ryot's Rust config reads the backend bind port/host from the
            # SERVER_-prefixed env (ServerConfig, env_prefix="SERVER_"); a bare
            # BACKEND_PORT is ignored and the server falls back to 0.0.0.0:5000,
            # which the Caddy proxy (CADDY_BACKEND_TARGET below) can't reach → 502.
            SERVER_BACKEND_PORT = toString cfg.backendPort;
            SERVER_BACKEND_HOST = loopback;
            FRONTEND_URL = cfg.frontendUrl;
          } // cfg.settings;
          serviceConfig = hardening // {
            ExecStart = "${cfg.package}/bin/backend";
          };
        };

        # ── frontend: React-Router SSR; reaches the backend THROUGH the proxy ─
        ryot-frontend = {
          description = "Ryot frontend (React-Router SSR)";
          after = [ "network.target" "ryot-backend.service" ];
          wantedBy = [ "multi-user.target" ];
          environment = {
            NODE_ENV = "production";
            PORT = toString cfg.frontendPort; # react-router-serve bind
            FRONTEND_PORT = toString cfg.frontendPort;
            FRONTEND_HOST = loopback;
            API_URL = "http://${loopback}:${toString cfg.proxyPort}/backend";
          };
          serviceConfig = hardening // {
            ExecStart = "${cfg.package}/bin/ryot-frontend";
          };
        };

        # ── proxy: Caddy = the entrypoint (path-mux + /_i/* webhooks) ─────────
        ryot-proxy = {
          description = "Ryot proxy (Caddy)";
          after = [ "network.target" "ryot-backend.service" "ryot-frontend.service" ];
          wantedBy = [ "multi-user.target" ];
          environment = {
            PORT = toString cfg.proxyPort;
            CADDY_BACKEND_TARGET = "${loopback}:${toString cfg.backendPort}";
            CADDY_FRONTEND_TARGET = "${loopback}:${toString cfg.frontendPort}";
            XDG_CONFIG_HOME = cfg.stateDir;
            XDG_DATA_HOME = cfg.stateDir;
          };
          serviceConfig = hardening // {
            ExecStart = "${pkgs.caddy}/bin/caddy run --adapter caddyfile --config ${cfg.package}/etc/ryot/Caddyfile";
          };
        };
      };
  };
}
