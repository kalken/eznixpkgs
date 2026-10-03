{ pkgs, lib, qbittorrent-nox, ... }:
let
  qbit-dark-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "qbit-dark";
    rev = "5bb947474092f5de48491db676f4f85ba874ebe3";
    hash = "sha256-RIDCQF33weZg2OPQMb/nZHkJ9marBs8s9nnUtDfgM8I=";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "qbit-dark";
  version = "unstable-2026-10-03";
  src = qbit-dark-src;

  # The repo only holds the theme CSS; build.sh combines it with the stock
  # WebUI files from the qBittorrent source. Override qbittorrent-nox if
  # services.qbittorrent.package is set to something else.
  installPhase = ''
    runHook preInstall
    sh ./build.sh ${qbittorrent-nox.src}/src/webui/www $out/share/qbit-dark
    runHook postInstall
  '';

  meta = with lib; {
    description = "Dark alternative WebUI for qBittorrent";
    homepage = "https://github.com/kalken/qbit-dark";
    license = licenses.gpl3Plus;
    platforms = platforms.all;
  };
}
