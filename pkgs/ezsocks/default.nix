{ config, pkgs, lib, ... }:

let
  ezsocks-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "ezsocks";
    rev = "c575114539f74d4b705728f651a074307a303318";          # develop branch
    hash = "sha256-8M1V+9QxjlIxzrLnJwE+RRbDcCmZtM5cikyPO/zHWas=";
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
