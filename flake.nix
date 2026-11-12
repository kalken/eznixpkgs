# eznixpkgs/flake.nix
{
  description = "NixOS modules and packages";

  # No nixpkgs.follows: ezsocks-rs is built with its own pinned nixpkgs, so its
  # build is the same on every machine and can come from the binary cache.
  inputs.ezsocks-rs.url = "github:kalken/ezsocks-rs/master";

  outputs = { self, nixpkgs, ezsocks-rs }: let
    # The flake revision as the version of our own packages, so it follows every commit.
    rev = self.shortRev or self.dirtyShortRev or "dev";
    pkgs = import ./pkgs rev;
  in {
    nixosModules = {
      default = {
        imports = [
          ./modules
          pkgs
        ];
        nixpkgs.overlays = [
          (final: prev: { ezsocks-rs = ezsocks-rs.packages.${final.stdenv.hostPlatform.system}.default; })
        ];
      };
    };

    # The modules that also work under nix-darwin (ezcage with its package from ./pkgs).
    # Not ./modules as a whole: the rest are built on systemd, networkd and the like.
    darwinModules = {
      default = { imports = [ ./modules/ezsh.nix ./modules/ezcage.nix pkgs ]; };
      ezsh    = ./modules/ezsh.nix;
      ezcage  = { imports = [ ./modules/ezcage.nix pkgs ]; };
    };
  };
}
