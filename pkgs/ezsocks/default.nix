{ config, pkgs, lib, ezsources, ... }:

let
  # From the ezsocks input in flake.nix
  ezsocks-src = ezsources.ezsocks;
in
pkgs.stdenv.mkDerivation rec {
  pname = "ezsocks";
  version = "unstable-${lib.substring 0 8 ezsocks-src.lastModifiedDate}";
  src = ezsocks-src;

  dontUnpack = true;
  # Skip setuptools, no setup.py
  dontUseSetuptools = true;

  # Python dependencies that are required at runtime. Requires Python 3.11+
  # (uses stdlib tomllib for config file support).
  propagatedBuildInputs = [
    (pkgs.python3.withPackages (pythonPackages: with pythonPackages; [ async-stagger ]))
  ];

  # Install phase: manually copy the script and make it executable
  installPhase = ''
    install -Dm755 ${src}/ezsocks.py $out/bin/ezsocks
  '';
  # Meta data
  meta = with lib; {
    description = "A tool for managing SOCKS5 proxies";
    license = licenses.gpl3;
  };
}
