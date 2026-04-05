{ inputs, ... }:
let
  overlayDir = ./.;

  autoOverlay = final: prev:
    let
      dirs = builtins.readDir overlayDir;
      subDirs = builtins.filter
        (name: dirs.${name} == "directory")
        (builtins.attrNames dirs);
    in
      builtins.listToAttrs (map (name: {
        inherit name;
        value = final.callPackage (overlayDir + "/${name}") { };
      }) subDirs);
in
{
  nixpkgs.overlays = [ autoOverlay ];
}
