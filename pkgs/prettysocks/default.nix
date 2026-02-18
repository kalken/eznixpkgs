{ config, pkgs, lib, ... }:

let
  prettysocks-src = pkgs.fetchFromGitHub {
    owner = "twisteroidambassador";
    repo = "prettysocks";
    rev = "5fb37d9a6004c0cf5aa08521e09a3de1e2d984ed";          # Or specific commit hash/tag
    hash = "sha256-Grt2tEB43xchX2Hw8H1T/elSGw3CvCEtyZuRWLvePIg=";     # Nix will tell you the correct hash on first build
  };
in
pkgs.stdenv.mkDerivation rec {
  pname = "prettysocks";
  version = "1.0.0";
  src = prettysocks-src;
  
  dontUnpack = true;
  # Skip setuptools, no setup.py
  dontUseSetuptools = true;
  
  # Python dependencies that are required at runtime
  propagatedBuildInputs = [
    (pkgs.python3.withPackages (pythonPackages: with pythonPackages; [ async-stagger ]))
  ];
  
  #postFixup = ''
  #substituteInPlace $out/bin/prettysocks \
  #  --replace "USE_BUILTIN_HAPPY_EYEBALLS = False" "USE_BUILTIN_HAPPY_EYEBALLS = True"
  #'';
  # Install phase: manually copy the script and make it executable
  installPhase = ''
    install -Dm755 ${src}/prettysocks.py $out/bin/prettysocks
  '';
  # Meta data
  meta = with lib; {
    description = "A tool for managing SOCKS5 proxies";
    license = licenses.mit;
  };
}
