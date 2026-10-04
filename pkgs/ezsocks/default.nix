{ config, pkgs, lib, ... }:

let
  ezsocks-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "ezsocks";
    rev = "6f45eb4a6a8e1ade08ff2ee2bb820c43b52f05a4";          # master branch
    hash = "sha256-RSJlU2gu5BzPqIjxnLtq7XnshIqOUWFmgopcOct1Z5w=";
  };
in
pkgs.stdenv.mkDerivation rec {
  pname = "ezsocks";
  version = "unstable-2026-10-04";
  src = ezsocks-src;

  dontUnpack = true;
  # Skip setuptools, no setup.py
  dontUseSetuptools = true;

  # Python dependencies that are required at runtime. Requires Python 3.11+
  # (uses stdlib tomllib for config file support). uvloop is optional
  # upstream (script falls back to asyncio.run if missing) but is included
  # here since it's the whole point of the performance branch.
  propagatedBuildInputs = [
    (pkgs.python3.withPackages (pythonPackages: with pythonPackages; [ async-stagger uvloop ]))
  ];

  # Install phase: manually copy the script and make it executable
  installPhase = ''
    install -Dm755 ${src}/prettysocks.py $out/bin/ezsocks
  '';
  # Meta data
  meta = with lib; {
    description = "A tool for managing SOCKS5 proxies";
    license = licenses.gpl3;
  };
}
