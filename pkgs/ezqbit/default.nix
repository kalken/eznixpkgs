{ pkgs, lib, qbittorrent-nox, ... }:
let
  ezqbit-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "ezqbit";
    rev = "63b70ceb86dad0ad0ed126c769e2dbb3dee96beb";
    hash = "sha256-o1z8Mx0J7Rx33O5OFqdWWVAXUuu5MwtlRJH22wcpCl4=";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "ezqbit";
  version = builtins.substring 0 7 ezqbit-src.rev;
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
