{ pkgs, lib, qbittorrent-nox, ... }:
let
  ezqbit-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "ezqbit";
    rev = "9db6cbfdd102b77925757c0883da87c5f3b6b8bf";
    hash = "sha256-76zlFXMrYAi7Y0+KEVuE2c00vVUM0p0A3XPzEzN/tPE=";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "ezqbit";
  version = "unstable-2026-10-03";
  src = ezqbit-src;

  # The repo only holds the theme CSS; build.sh combines it with the stock
  # WebUI files from the qBittorrent source. Override qbittorrent-nox if
  # services.qbittorrent.package is set to something else.
  installPhase = ''
    runHook preInstall
    sh ./build.sh ${qbittorrent-nox.src}/src/webui/www $out/share/ezqbit
    runHook postInstall
  '';

  meta = with lib; {
    description = "Flat dark alternative WebUI for qBittorrent";
    homepage = "https://github.com/kalken/ezqbit";
    license = licenses.gpl3Plus;
    platforms = platforms.all;
  };
}
