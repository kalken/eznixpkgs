{ pkgs, lib, ... }:
let
  qbit-dark-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "qbit-dark";
    rev = "b173cd084ad4c376ad09758eeae2ed1e9523c941";
    hash = "sha256-TnunwR/5F9U7VPcrb3t9HJHtRdv6rYy4gH4cEQk0QNA=";
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
