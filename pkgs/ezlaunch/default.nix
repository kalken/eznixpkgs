# ezlaunch/default.nix
{
  lib,
  writeShellApplication,
  umu-launcher,
  fzf,
  yad,
  icoutils,
  xdg-utils,
  desktop-file-utils,
  findutils,
  coreutils,
  gnugrep,
  gnused,
}:

writeShellApplication {
  name = "ezlaunch";

  runtimeInputs = [
    umu-launcher
    fzf
    yad
    icoutils
    xdg-utils
    desktop-file-utils
    findutils
    coreutils
    gnugrep
    gnused
  ];

  text = builtins.readFile ./ezlaunch.sh;

  meta = with lib; {
    description = "Install and launch Windows programs and games with Proton, with start menu entries and per-program settings";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "ezlaunch";
  };
}
