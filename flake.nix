# eznixpkgs/flake.nix
{
  description = "Shared NixOS modules and packages";
  
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };
  
  outputs = { self, nixpkgs }: {
    nixosModules = {
      default = { 
        imports = [ 
          ./modules 
          ./pkgs
        ]; 
      };
    };
  };
}
