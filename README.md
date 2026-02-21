# eznixpkgs

NixOS modules and packages. It should work with both stable and unstable.

## 🚀 Usage

Add the flake as an input in your `flake.nix`, and make sure `eznixpkgs` follows your `nixpkgs`:

```nix
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

### [ezconf](https://github.com/kalken/ezconf)
Configuration tool wrapped in nvim to make it easier to edit nix files.

### ezman
recursive version of nixos-option.

### [eznetns](https://github.com/kalken/eznetns)
eznetns is a command line helper to configure separated network environments (namespaces), and control which processes that make use of them. 

### [prettysocks](https://github.com/twisteroidambassador/prettysocks)
A proxy server that makes your eyeballs happy.

### [wg-tools](https://github.com/mullvad/wg-tools)
generates WireGuard®1 configuration files for all Mullvad relays.

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
