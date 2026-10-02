{ pkgs, lib, ... }:
let
  qbit-dark-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "qbit-dark";
    rev = "fa1f5a4841e9f7dae8f98614278b6aadab0f0024";
    hash = "sha256-Og1c51uNtJv4bR+GbF2+Sg93jblpUHKVciEBpfBLpiA=";
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
