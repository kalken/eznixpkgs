# eznixpkgs/flake.nix
{
  description = "NixOS modules and packages";

  # No nixpkgs.follows: ezsocks-rs is built with its own pinned nixpkgs, so its
  # build is the same on every machine and can come from the binary cache.
  inputs.ezsocks-rs.url = "github:kalken/ezsocks-rs/develop";

  outputs = { self, nixpkgs, ezsocks-rs }: {
    nixosModules = {
      default = {
        imports = [
          ./modules
          ./pkgs
        ];
        nixpkgs.overlays = [
          (final: prev: { ezsocks-rs = ezsocks-rs.packages.${final.stdenv.hostPlatform.system}.default; })
        ];
      };
    };

    # The modules that also work under nix-darwin. Not ./modules as a whole: the rest are
    # built on systemd, networkd and the like.
    darwinModules = {
      default = { imports = [ ./modules/ezsh.nix ]; };
      ezsh    = ./modules/ezsh.nix;
    };
  };
}
