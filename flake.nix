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
  };
}
