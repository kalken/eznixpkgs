# ezproton-launcher/default.nix
{
  lib,
  stdenvNoCC,
  python3,
  qt6,
  makeWrapper,
  umu-launcher,
  fzf,
  icoutils,
  desktop-file-utils,
}:

let
  # PySide6 is the only library besides Python's own
  python = python3.withPackages (ps: [ ps.pyside6 ]);
in
stdenvNoCC.mkDerivation {
  pname = "ezproton-launcher";
  version = builtins.substring 0 7 (baseNameOf "${./.}"); # hash of this folder, changes only when the package does

  src = ./ezproton_launcher.py;
  dontUnpack = true;

  nativeBuildInputs = [
    makeWrapper
    qt6.wrapQtAppsHook
  ];
  # The Wayland platform plugin, found through the Qt wrapper arguments
  buildInputs = [
    qt6.qtbase
    qt6.qtwayland
  ];

  dontWrapQtApps = true;

  installPhase = ''
    runHook preInstall
    install -Dm644 $src $out/share/ezproton-launcher/ezproton_launcher.py
    runHook postInstall
  '';

  postFixup = ''
    makeWrapper ${python.interpreter} $out/bin/ezproton-launcher \
      --add-flags $out/share/ezproton-launcher/ezproton_launcher.py \
      --prefix PATH : ${
        lib.makeBinPath [
          umu-launcher
          fzf
          icoutils
          desktop-file-utils
        ]
      } \
      "''${qtWrapperArgs[@]}"
  '';

  meta = with lib; {
    description = "Install and launch Windows programs and games with Proton, with a Qt window, start menu entries and per-program settings";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "ezproton-launcher";
  };
}
