{ pkgs, lib, qbittorrent-nox, ... }:
let
  ezqbit-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "ezqbit";
    rev = "0c3052901040e9f1154958545f0d74085644e0d0";
    hash = "sha256-Xtr/Z/cw4wRMIFlFuMACTc8Uh1rrf/N0Mg0JqS44bX4=";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "ezqbit";
  version = "unstable-2026-10-05";
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
    description = "Flat alternative WebUI for qBittorrent, dark and light";
    homepage = "https://github.com/kalken/ezqbit";
    license = licenses.gpl3Plus;
    platforms = platforms.all;
  };
}
