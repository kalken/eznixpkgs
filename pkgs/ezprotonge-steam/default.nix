# ezprotonge-steam/default.nix
{ lib
, python3
, makeWrapper
}:

let
  python = python3;
in
python.pkgs.buildPythonApplication {
  pname   = "ezprotonge-steam";
  version = "1.0.0";

  src = ./.;

  format = "other";

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp ezprotonge.py $out/bin/ezprotonge-steam
    chmod +x $out/bin/ezprotonge-steam
    patchShebangs $out/bin/ezprotonge-steam
  '';

  meta = with lib; {
    description = "Installs the latest Proton-GE into Steam's compatibilitytools.d, always presented as GE-Proton-Latest";
    homepage    = "https://github.com/GloriousEggroll/proton-ge-custom";
    license     = licenses.gpl3;
    platforms   = platforms.linux;
  };
}
