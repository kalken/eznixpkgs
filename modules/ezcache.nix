{ config, lib, ... }:
let
  cfg = config.eznixpkgs.cache;
in {
  options.eznixpkgs.cache.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Download eznixpkgs packages that are built on GitHub (such as
      ezsocks-rs) from the kalken.cachix.org binary cache instead of
      compiling them. Used in addition to cache.nixos.org.
    '';
  };

  config = lib.mkIf cfg.enable {
    # extra-*, so the default cache.nixos.org stays in place
    nix.settings.extra-substituters = [ "https://kalken.cachix.org" ];
    nix.settings.extra-trusted-public-keys = [ "kalken.cachix.org-1:R4z1JqA48iPrdcZInmnW7Jb8eFFlEcOzHZzyQimXgsI=" ];
  };
}
