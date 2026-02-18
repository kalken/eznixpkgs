{ stdenv
, lib
, makeWrapper
, bash
, gnugrep
, gnused
, coreutils
, nixos-option
}:

stdenv.mkDerivation {
  pname = "ezman";
  version = "0.1.0";

  src = ./.;

  # Tools needed to BUILD the package
  nativeBuildInputs = [ makeWrapper ];

  # Tools the script needs to RUN at runtime
  buildInputs = [ bash gnugrep gnused coreutils nixos-option ];

  installPhase = ''
    mkdir -p $out/bin
    cp ezman.sh $out/bin/ezman
    chmod +x $out/bin/ezman
    patchShebangs $out/bin/ezman
  '';

  # Wrap the program to inject dependencies into PATH
  postInstall = ''
    wrapProgram $out/bin/ezman \
      --prefix PATH : ${lib.makeBinPath [
        bash
        gnugrep
        gnused
        coreutils
        nixos-option
      ]}
  '';

  meta = with lib; {
    description = "Recursive nixos-option inspector with colored output";
    license = licenses.gpl3;
    platforms = platforms.linux; # nixos-option is Linux/NixOS-specific
  };
}
