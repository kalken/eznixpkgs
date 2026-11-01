# ezcage/default.nix
{ stdenv
, lib
, makeWrapper
, bash
, coreutils
, getent
, systemd
}:

stdenv.mkDerivation {
  pname = "ezcage";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ bash ];

  # sudo is not added to PATH: it must be the setuid wrapper from the system PATH
  installPhase = ''
    install -Dm755 ezcage.sh $out/bin/ezcage
    patchShebangs $out/bin/ezcage
    wrapProgram $out/bin/ezcage \
      --prefix PATH : ${lib.makeBinPath [ coreutils getent systemd ]}
  '';

  meta = with lib; {
    description = "Run a program that sees only the paths it is granted";
    license = licenses.gpl3;
    platforms = platforms.linux;
  };
}
