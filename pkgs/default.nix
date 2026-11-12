# rev: the flake revision, used as the version of our own packages
rev:
let
  overlayDir = ./.;

  # Packages that take rev as their version
  versioned = [ "ezboot" "ezcage" "ezman" "eznetns" "ezproton" "ezqbit" "ezsensors" "ezsocks" ];

  autoOverlay = final: prev:
    let
      dirs = builtins.readDir overlayDir;
      subDirs = builtins.filter
        (name: dirs.${name} == "directory")
        (builtins.attrNames dirs);
    in
      builtins.listToAttrs (map (name: {
        inherit name;
        value = final.callPackage (overlayDir + "/${name}")
          (if builtins.elem name versioned then { inherit rev; } else { });
      }) subDirs);
in
{
  nixpkgs.overlays = [ autoOverlay ];
}
