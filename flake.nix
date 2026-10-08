# eznixpkgs/flake.nix
{
  description = "NixOS modules and packages";
  
  outputs = { self, nixpkgs }: {
    nixosModules = {
      default = { 
        imports = [ 
          ./modules 
          ./pkgs
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
