{ pkgs, lib, qbittorrent-nox, ... }:
let
  ezqbit-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "ezqbit";
    rev = "80dcceeff89e48e6219bd0e598b0bb69b5b97275";
    hash = "sha256-Yd7D+j9W/VdkTg7IYnODdJ4dd5ZpLWQoI/j4x/o0CSU=";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "ezqbit";
  version = "unstable-2026-10-04";
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
