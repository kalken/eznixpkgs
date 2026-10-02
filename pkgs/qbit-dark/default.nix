{ pkgs, lib, ... }:
let
  qbit-dark-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "qbit-dark";
    rev = "f456e5fdd6cf7ef83ddf2c04430dfb935d4360b1";
    hash = "sha256-zNQyvVGnbhTgwKRl+9HCqIkSrfib6ClDpJiTWUypBI4=";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "qbit-dark";
  version = "unstable-2026-10-03";
  src = qbit-dark-src;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/qbit-dark
    cp -r public private $out/share/qbit-dark/
    runHook postInstall
  '';

  meta = with lib; {
    description = "Dark alternative WebUI for qBittorrent";
    homepage = "https://github.com/kalken/qbit-dark";
    license = licenses.gpl3Plus;
    platforms = platforms.all;
  };
}
