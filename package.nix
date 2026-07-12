# Combined Ryot output: backend binary + frontend server + the upstream Caddyfile
# (pulled from the pinned source so the proxy routing stays in lockstep with the
# version). The NixOS module references this single package for all three units.
{
  lib,
  symlinkJoin,
  backend,
  frontend,
  src,
  version,
}:

symlinkJoin {
  name = "ryot-${version}";
  paths = [ backend frontend ];

  # $out/bin/{backend,ryot-frontend} come from the joined paths; add the proxy
  # config at a stable location the module can point Caddy at.
  postBuild = ''
    install -Dm644 ${src}/ci/Caddyfile $out/etc/ryot/Caddyfile
  '';

  meta = {
    description = "Ryot — self-hosted media & life tracker (backend + frontend + proxy config)";
    homepage = "https://github.com/IgnisDa/ryot";
    license = lib.licenses.gpl3Only;
    mainProgram = "backend";
    platforms = lib.platforms.linux;
  };
}
