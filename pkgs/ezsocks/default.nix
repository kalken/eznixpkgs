{ config, pkgs, lib, ... }:

let
  ezsocks-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "ezsocks";
    rev = "92a7df4c1a90cef7d6ab3968afc2271704a34681";          # develop branch
    hash = "sha256-uj05hbcBEEYCvkEloBh/ikHBk6hKWnBoSINIqks3QD8=";
  };
in
pkgs.stdenv.mkDerivation rec {
  pname = "ezsocks";
  version = "unstable-2026-10-30";
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
