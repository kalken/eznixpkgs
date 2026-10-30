{ pkgs, lib, ... }:
let
  eznetns-src = pkgs.fetchFromGitHub {
    owner = "kalken";
    repo = "eznetns";
    rev = "1349cdd7677cada0a90a0dfbd2e90b2b61b7639c";          # develop branch
    hash = "sha256-pCCXgPrDxZ/IWfD/GqbEmTM06dfT0BpAzvsu7jx9IQQ=";
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
