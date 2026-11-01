# eznixpkgs/flake.nix
{
  description = "NixOS modules and packages";

  # No nixpkgs.follows: ezsocks-rs is built with its own pinned nixpkgs, so its
  # build is the same on every machine and can come from the binary cache.
  inputs.ezsocks-rs.url = "github:kalken/ezsocks-rs/master";

  # Sources of packages and modules that live in their own repos: only their
  # files, not flakes. A machine's `nix flake update` moves them to the latest
  # commit; to try a local checkout on one machine:
  #   nixos-rebuild switch --flake /etc/nixos --override-input eznixpkgs/eznetns path:/path/to/eznetns
  inputs.eznetns = { url = "github:kalken/eznetns/develop"; flake = false; };
  inputs.ezsocks = { url = "github:kalken/ezsocks/develop"; flake = false; };
  inputs.ezqbit  = { url = "github:kalken/ezqbit/develop";  flake = false; };
  inputs.ezsh    = { url = "github:kalken/ezsh/master";     flake = false; };

  outputs = inputs@{ self, nixpkgs, ezsocks-rs, ... }:
    let
      # pkgs.ezsources: the sources above, for pkgs/ and modules/
      sources = {
        nixpkgs.overlays = [
          (final: prev: { ezsources = { inherit (inputs) eznetns ezsocks ezqbit ezsh; }; })
        ];
      };
    in {
      nixosModules = {
        default = {
          imports = [
            ./modules
            ./pkgs
            sources
          ];
          nixpkgs.overlays = [
            (final: prev: { ezsocks-rs = ezsocks-rs.packages.${final.stdenv.hostPlatform.system}.default; })
          ];
        };
      };

      # The modules that also work under nix-darwin (ezcage with its package from ./pkgs).
      # Not ./modules as a whole: the rest are built on systemd, networkd and the like.
      darwinModules = {
        default = { imports = [ ./modules/ezsh.nix ./modules/ezcage.nix ./pkgs sources ]; };
        ezsh    = { imports = [ ./modules/ezsh.nix sources ]; };
        ezcage  = { imports = [ ./modules/ezcage.nix ./pkgs ]; };
      };
    };
}
