{
  imports = builtins.concatLists (map
    (f: [ (./. + "/${f}") ])
    (builtins.filter
      (name: name != "default.nix" && builtins.match ".*\\.nix" name != null)
      (builtins.attrNames (builtins.readDir ./.))
    )
  );
}
