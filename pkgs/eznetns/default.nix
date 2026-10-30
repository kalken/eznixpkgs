{ pkgs, lib, ... }:
let
  eznetns-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "eznetns";
    rev = "93ce00ec5811160f2a14c00fe654e5364905bdb3";          # main branch
    hash = "sha256-a5uWI3fZppmdQk3wFr43zQyENG0XZrfioqES7c4yjM4=";
  };
in
pkgs.stdenv.mkDerivation rec {
  pname = "eznetns";
  version = "1.1.0";
  src = eznetns-src;
  # Python dependencies that are required at runtime
  propagatedBuildInputs = [
    (pkgs.python3.withPackages (pythonPackages: with pythonPackages; [
      #no dependencies
    ]))
  ];
  buildInputs = [ pkgs.bashInteractive ];
  
  dontUnpack = true;
  # Skip setuptools, no setup.py
  dontUseSetuptools = true;
  # Install phase: manually copy the script and make it executable
  
  nativeBuildInputs = [ pkgs.makeWrapper ];
  installPhase = ''
    install -Dm755 ${src}/bin/eznetns $out/bin/eznetns
    install -Dm755 ${src}/bin/ezwgen $out/bin/ezwgen
    wrapProgram $out/bin/eznetns --prefix PATH : ${lib.makeBinPath [
      pkgs.wireguard-tools
      pkgs.iproute2
      pkgs.nftables
      pkgs.gawk
    ]}
  '';
  # Meta data
  meta = with lib; {
    description = "A tool for managing netns";
    license = licenses.gpl2;
  };
}
