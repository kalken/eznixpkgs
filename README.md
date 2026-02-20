# eznixpkgs

NixOS modules and packages.

## 🚀 Usage

Add the flake as an input in your `flake.nix`, and make sure `eznixpkgs` follows your `nixpkgs`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    eznixpkgs = {
      url = "github:kalken/eznixpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, eznixpkgs, ... }: {
    nixosConfigurations.mymachine = nixpkgs.lib.nixosSystem {
      modules = [
        eznixpkgs.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

Then enable whichever modules you need in your `configuration.nix`:

```nix
{
  services.ezrouter.enable = true;
  services.ezrouter.wan.device ="eth0";
  services.ezrouter.lan.devices = ["eth1" "eth2"];
  services.eznetns.instances.myns.enable = true;
  services.prettysocks.enable = true;
}
```

## 📦 Modules

| Module | Description |
|--------|-------------|
| [ezrouter](https://github.com/kalken/eznixpkgs/blob/develop/modules/ezrouter.md) | Router setup with VLANs, DHCP, DNS, and firewall |
| [eznetns](https://github.com/kalken/eznixpkgs/blob/develop/modules/eznetns.md) | Named Linux network namespace management |
| [prettysocks](https://github.com/kalken/eznixpkgs/blob/develop/modules/prettysocks.md) | SOCKS5 proxy on `127.0.0.1:1080`, with optional per-namespace instances |
