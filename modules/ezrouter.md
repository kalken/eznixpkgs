# ezrouter

A simple NixOS module for router setup with VLANs, DHCPv4/DHCPv6, DNS, and firewall using `systemd-networkd` + `nftables`.

## ✨ Features

- Bridge + VLAN interfaces
- DHCPv4 server & DHCPv6 prefix delegation
- DNS via `systemd-resolved`
- Optional inter-VLAN isolation
- NAT + firewall with `nftables`

## 🚀 Quick Start

```nix
{
  services.ezrouter = {
    enable = true;
    wan.device = "eth0";  # WAN interface

    bridge = {
      address = "192.168.1.1/24";
      devices = [ "eth1" "eth2" ];  # LAN ports
    };

    vlan.guests = {
      id = 10;
      address = "192.168.10.1/24";
      subnetId = 10;
    };
  };
}
```

## ⚙️ All Options

### Global Settings

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `services.ezrouter.enable` | bool | `false` | Enable the ezrouter module |
| `services.ezrouter.debug` | bool | `false` | Enable verbose systemd-networkd logs |
| `services.ezrouter.isolateVlans` | bool | `true` | Block traffic between VLANs |

### WAN Settings

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `services.ezrouter.wan.device` | str | *required* | Physical WAN interface name (e.g., "eth0") |

### Bridge Settings (LAN)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `services.ezrouter.bridge.address` | str | `"192.168.1.1"` | IP address/CIDR for the bridge |
| `services.ezrouter.bridge.devices` | list | `[]` | List of physical interfaces to add to bridge |
| `services.ezrouter.bridge.enableDHCPv4` | bool | `true` | Enable DHCPv4 server on bridge |
| `services.ezrouter.bridge.enableDHCPv6` | bool | `true` | Enable DHCPv6 Prefix Delegation on bridge |
| `services.ezrouter.bridge.enableDNS` | bool | `true` | Enable DNS resolver on bridge |

### VLAN Settings (`services.ezrouter.vlan.<name>`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `vlan.<name>.id` | int | *required* | VLAN ID (1-4094) |
| `vlan.<name>.address` | str | *required* | IP address/CIDR for the VLAN interface |
| `vlan.<name>.subnetId` | int | *required* | Subnet ID (used for DHCP ranges) |
| `vlan.<name>.enableDHCPv4` | bool | `true` | Enable DHCPv4 server on this VLAN |
| `vlan.<name>.enableDHCPv6` | bool | `true` | Enable DHCPv6 Prefix Delegation on this VLAN |
| `vlan.<name>.enableDNS` | bool | `true` | Enable DNS resolver on this VLAN |

## 📝 Notes

- Automatically enables `systemd-networkd` and `systemd-resolved`.
- Firewall uses `nftables`; NAT is applied to internal interfaces automatically.
- Set `debug = true` to troubleshoot network interface issues.

*Minimal router config for NixOS — just works.* 🚀
