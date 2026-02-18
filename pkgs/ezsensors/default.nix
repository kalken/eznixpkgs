# ezsensors/default.nix
{ stdenv
, lib
, makeWrapper
, bash
, coreutils
, gnugrep
}:

stdenv.mkDerivation {
  pname = "ezsensors";
  version = "0.1.0";

  src = ./.;

  # Tools needed to BUILD the package
  nativeBuildInputs = [ makeWrapper ];

  # Tools the script needs to RUN at runtime
  # - bash: for bash-specific features (shopt, local, [[ ]], printf)
  # - coreutils: for basename, cat, echo, printf
  # - gnugrep: ensures consistent regex behavior if script is extended
  buildInputs = [ bash coreutils gnugrep ];

  installPhase = ''
    mkdir -p $out/bin
    cp ezsensors.sh $out/bin/ezsensors
    chmod +x $out/bin/ezsensors
    patchShebangs $out/bin/ezsensors
  '';

  # Wrap the program to inject dependencies into PATH
  postInstall = ''
    wrapProgram $out/bin/ezsensors \
      --prefix PATH : ${lib.makeBinPath [ bash coreutils gnugrep ]}
  '';

  meta = with lib; {
    description = "Display CPU temperature from thermal_zone sensors";
    license = licenses.gpl3;
    platforms = platforms.linux; # Reads from /sys/class/thermal (Linux-specific)
  };
}
