{ pkgs, lib, ... }:
let
  qbit-dark-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "qbit-dark";
    rev = "b0757b3e5168813b6e7cb3dc26a6fd3540cf6b86";
    hash = "sha256-891Vr20hVOxOadgudSKaan7tMtrvI7jDSDWUZYFEDqQ=";
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
