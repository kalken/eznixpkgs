{ config, pkgs, lib, ... }:

let
  wg-tools-src = pkgs.fetchFromGitHub {
    owner = "mullvad";
    repo = "wg-tools";
    rev = "c85b7ed35bdb6e0bd38fa24481819088fa6a68c5";            # Or specific commit hash/tag
    hash = "sha256-ODrNsSsajqebPxi1+uGtxv43/RE7AAl76AfiPdPdRX4=";     # Nix will tell you the correct hash on first build
  };
in
pkgs.stdenv.mkDerivation rec {
  pname = "wg-tools";
  version = "1.1.3";
  src = wg-tools-src;
  
  # Python dependencies that are required at runtime
  propagatedBuildInputs = [
    (pkgs.python3.withPackages (pythonPackages: with pythonPackages; [
      cryptography
    ]))
  ];
  
  dontUnpack = true;
  # Skip setuptools, no setup.py
  dontUseSetuptools = true;
  # Install phase: manually copy the script and make it executable
  
  installPhase = ''
    install -Dm755 ${src}/wg-mullvad.py $out/bin/wg-mullvad
  '';
  
  # Meta data
  meta = with lib; {
    description = "A tool for managing mullvad WireGuard files";
    license = licenses.gpl3;
  };
}
