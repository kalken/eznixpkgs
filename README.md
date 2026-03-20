# eznixpkgs

NixOS modules and packages. It should work with both stable and unstable.

## 🚀 Usage

Add the flake as an input in your `flake.nix`, and make sure `eznixpkgs` follows your `nixpkgs`:

```
{
  description = "NixOS configuration";

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
| --- | --- |
| [ezrouter](https://github.com/kalken/eznixpkgs/blob/master/modules/ezrouter.md) | Router setup with VLANs, DHCP, DNS, and firewall |
| [eznetns](https://github.com/kalken/eznixpkgs/blob/master/modules/eznetns.md) | Named Linux network namespace management |
| [prettysocks](https://github.com/kalken/eznixpkgs/blob/master/modules/prettysocks.md) | SOCKS5 proxy on `127.0.0.1:1080`, with optional per-namespace instances |
| [ezprotonge-steam](https://github.com/kalken/eznixpkgs/blob/master/modules/ezprotonge-steam.md) | Automatically installs the latest Proton-GE into Steam's compatibilitytools.d |

## 🛠 Programs

| Program | Description |
| --- | --- |
| [ezconf](https://github.com/kalken/eznixpkgs/blob/master/modules/ezconf.md) | A configuration tool wrapped in nvim to make it easier to edit nix files. |

## 📦 Packages

```
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    ezman
    eznetns
    ezsensors
    ezprotonge-steam
    prettysocks
    wg-tools
  ];
}
```

| Package | Description |
| --- | --- |
| [ezman](https://github.com/kalken/eznixpkgs/blob/master/pkgs/ezman/ezman.sh) | Recursive version of `nixos-option`. |
| [eznetns](https://github.com/kalken/eznetns) | A command line helper to configure separated network environments (namespaces), and control which processes make use of them. |
| [ezsensors](https://github.com/kalken/eznixpkgs/blob/master/pkgs/ezsensors/ezsensors.sh) | Simple script to get temperature readings from `/sys`. |
| [ezprotonge-steam](https://github.com/kalken/eznixpkgs/blob/master/pkgs/ezprotonge-steam/ezprotonge-steam.py) | Automatically installs the latest Proton-GE into Steam's compatibilitytools.d. |
| [prettysocks](https://github.com/twisteroidambassador/prettysocks) | A proxy server that makes your eyeballs happy. |
| [wg-tools](https://github.com/mullvad/wg-tools) | Generates WireGuard® configuration files for Mullvad. |
