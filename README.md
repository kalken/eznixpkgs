# eznixpkgs

NixOS modules and packages. It should work use with both stable and unstable (only unstable tested).

## 🚀 Usage

Add the flake as an input in your `flake.nix`, and make sure `eznixpkgs` follows your `nixpkgs`:

```nix
{
{
  description = "NixOS configuration with flattened inputs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    eznixpkgs.url = "github:kalken/eznixpkgs";
    eznixpkgs.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs: {
    nixosConfigurations.mymachine = inputs.nixpkgs.lib.nixosSystem {
      modules = [
        inputs.eznixpkgs.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

Then enable whichever modules you need in your `configuration.nix`:

## 📦 Modules

| Module | Description |
|--------|-------------|
| [ezrouter](/modules/ezrouter.md) | Router setup with VLANs, DHCP, DNS, and firewall |
| [eznetns](/modules/eznetns.md) | Named Linux network namespace management |
| [prettysocks](/modules/prettysocks.md) | SOCKS5 proxy on `127.0.0.1:1080`, with optional per-namespace instances |

## 📦 Packages
```

{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    ezconf
    ezman
    eznetns
    ezsensors
    prettysocks
    wg-tools
  ];
}
```
