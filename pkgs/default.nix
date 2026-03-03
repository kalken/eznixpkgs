{ inputs, ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      ezconf      = final.callPackage ./ezconf { configLua = ./ezconf/config.lua; };
      eznetns     = final.callPackage ./eznetns { };
      prettysocks = final.callPackage ./prettysocks { };
      wg-tools    = final.callPackage ./wg-tools  { };
      ezsensors = final.callPackage ./ezsensors  { };
      ezman = final.callPackage ./ezman  { };
    })
  ];
}

