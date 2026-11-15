{ pkgs, lib, qbittorrent-nox, rev ? "dev", ... }:
let
  ezqbit-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "ezqbit";
    rev = "74df2a6f0fe306eea2d3c7544cc562c31734e710";
    hash = "sha256-MOkZX4w6fWg2u6xYnXSbvzl18NqbVRc1Yo+f5a0WNUg=";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "ezqbit";
  version = rev;
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
