# ezcage/default.nix
{
  stdenv,
  lib,
  makeWrapper,
  bash,
  coreutils,
  getent,
  systemd,
  socat,
}:

let
  # Linux: systemd units with namespaces. macOS: the built-in sandbox (sandbox-exec).
  script = if stdenv.hostPlatform.isDarwin then "ezcage-darwin.sh" else "ezcage.sh";
  runtimeDeps =
    if stdenv.hostPlatform.isDarwin then
      [ coreutils ]
    else
      [
        coreutils
        getent
        socat
        systemd
      ];
in
stdenv.mkDerivation {
  pname = "ezcage";
  version = builtins.substring 0 7 (baseNameOf "${./.}"); # hash of this folder, changes only when the package does

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ bash ];

  # sudo is not added to PATH: it must be the setuid wrapper from the system PATH
  installPhase = ''
    install -Dm755 ${script} $out/bin/ezcage
    ${lib.optionalString (!stdenv.hostPlatform.isDarwin) ''
      # sudo runs the wrapper, not the wrapped script ($0)
      substituteInPlace $out/bin/ezcage --replace-fail '@self@' "$out/bin/ezcage"
    ''}
    substituteInPlace $out/bin/ezcage --replace-fail '@version@' "$version"
    patchShebangs $out/bin/ezcage
    wrapProgram $out/bin/ezcage \
      --prefix PATH : ${lib.makeBinPath runtimeDeps}
  '';

  meta = with lib; {
    description = "Run a program that sees only the paths it is granted";
    license = licenses.gpl3;
    platforms = platforms.linux ++ platforms.darwin;
  };
}
