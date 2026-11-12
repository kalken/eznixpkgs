# ezproton/default.nix
{ lib
, python3
, makeWrapper
, rev ? "dev"
}:

let
  python = python3;
in
python.pkgs.buildPythonApplication {
  pname   = "ezproton";
  version = rev;

  src = ./.;

  format = "other";

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp ezproton.py $out/bin/ezproton
    chmod +x $out/bin/ezproton
    substituteInPlace $out/bin/ezproton --replace-fail '@version@' "$version"
    patchShebangs $out/bin/ezproton
  '';

  meta = with lib; {
    description = "Installs the latest Proton-GE and/or CachyOS Proton into Steam's compatibilitytools.d, always presented as GE-Proton-Latest / Proton-CachyOS-Latest";
    homepage    = "https://github.com/GloriousEggroll/proton-ge-custom";
    license     = licenses.gpl3;
    platforms   = platforms.linux;
  };
}
