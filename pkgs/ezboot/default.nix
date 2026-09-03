{ stdenv
, lib
, makeWrapper
, bash
, coreutils
, gawk
, cryptsetup
, systemd
, luksName ? null
, bootPath ? "/boot"
, keyFileName ? ".ezboot.key"
, masterKeyPath ? "/var/lib/ezboot/master.key"
}:

stdenv.mkDerivation {
  pname = "ezboot";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ bash coreutils gawk cryptsetup systemd ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp ezboot.sh $out/bin/ezboot
    chmod +x $out/bin/ezboot
    patchShebangs $out/bin/ezboot

    runHook postInstall
  '';

  postInstall = ''
    wrapProgram $out/bin/ezboot \
      --prefix PATH : ${lib.makeBinPath [ bash coreutils gawk cryptsetup systemd ]} \
      ${lib.optionalString (luksName != null) "--set EZBOOT_LUKS_NAME ${lib.escapeShellArg luksName}"} \
      --set EZBOOT_BOOT_PATH ${lib.escapeShellArg bootPath} \
      --set EZBOOT_KEY_NAME ${lib.escapeShellArg keyFileName} \
      --set EZBOOT_MASTER_KEY ${lib.escapeShellArg masterKeyPath}
  '';

  meta = with lib; {
    description = "Temporarily unlock a LUKS root with a one-time boot-partition key for a single reboot";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
