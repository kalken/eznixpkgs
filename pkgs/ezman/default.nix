{ stdenv
, lib
, makeWrapper
, bash
, gnugrep
, gnused
, coreutils
, nixos-option
, rev ? "dev"
}:

stdenv.mkDerivation {
  pname = "ezman";
  version = rev;

  src = ./.;

  # Tools needed to BUILD the package
  nativeBuildInputs = [ makeWrapper ];

  # Tools the script needs to RUN at runtime
  buildInputs = [ bash gnugrep gnused coreutils nixos-option ];

  installPhase = ''
    mkdir -p $out/bin
    cp ezman.sh $out/bin/ezman
    chmod +x $out/bin/ezman
    substituteInPlace $out/bin/ezman --replace-fail '@version@' "$version"
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
