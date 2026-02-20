# ezrouter

A simple NixOS module for router setup with VLANs, DHCPv4/DHCPv6, DNS, and firewall using `systemd-networkd` + `nftables`.

## ✨ Features

- Bridge + VLAN interfaces via `systemd-networkd`
- DHCPv4 server & DHCPv6 Prefix Delegation
- DNS via `systemd-resolved`
- Optional inter-VLAN isolation with `nftables`
- NAT for internal interfaces

## 🚀 Quick Start

```nix
{
  imports = [ ./modules/ezrouter.nix ];

  services.ezrouter = {
    enable = true;
    wan.device = "eth0";

    bridge = {
      address = "192.168.1.1";
      devices = [ "eth1" "eth2" ];
    };

    vlan.guests = {
      id = 10;
      address = "192.168.10.1";
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
| `services.ezrouter.debug` | bool | `false` | Enable debug logging for `systemd-networkd` |
| `services.ezrouter.isolateVlans` | bool | `true` | Block traffic between VLANs (inter-VLAN isolation) |
| `services.ezrouter.vlanFirewallPorts.allowedTCPPorts` | list of port | `[]` | TCP ports to open on all VLAN interfaces |
| `services.ezrouter.vlanFirewallPorts.allowedUDPPorts` | list of port | `[53 67]` | UDP ports to open on all VLAN interfaces |
| `services.ezrouter.trustedInterfaces` | list of str | `[bridge.name]` | Interfaces with no firewall restrictions |
| `services.ezrouter.internalInterfaces` | list of str | *auto* | Internal interfaces for NAT (auto: bridge + all VLANs) |

### WAN Settings (`services.ezrouter.wan`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `wan.device` | str | *required* | WAN interface name (e.g., `"eth0"`) |
| `wan.ipv6PrivacyExtensions` | str | `"no"` | Enable IPv6 privacy extensions (`"no"`, `"yes"`, `"kernel"`) |
| `wan.prefixHint` | int | `56` | DHCPv6 prefix delegation hint (e.g., `56` for `/56`, `64` for `/64`) |
| `wan.keepConfiguration` | bool | `false` | Keep WAN config when link goes down |

### Bridge Settings (`services.ezrouter.bridge`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `bridge.name` | str | `"lan"` | Name of the bridge interface |
| `bridge.devices` | list of str | `[]` | Physical interfaces to attach to bridge |
| `bridge.address` | str | `"192.168.1.1"` | IP address for the bridge |
| `bridge.netmask` | str | `"24"` | Netmask/CIDR for bridge address |
| `bridge.subnetId` | int | `1` | Subnet ID for DHCPv6 prefix delegation |
| `bridge.ipv6PrivacyExtensions` | str | `"no"` | Enable IPv6 privacy extensions |
| `bridge.enableDHCPv4` | bool | `true` | Enable DHCPv4 server on bridge |
| `bridge.enableDHCPv6` | bool | `true` | Enable DHCPv6 Prefix Delegation on bridge |
| `bridge.enableDNS` | bool | `true` | Enable DNS listener on bridge address |

### VLAN Settings (`services.ezrouter.vlan.<name>`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `vlan.<name>.id` | int | *required* | VLAN ID (1–4094) |
| `vlan.<name>.address` | str | *required* | IP address for the VLAN interface |
| `vlan.<name>.netmask` | str | `"24"` | Netmask/CIDR for VLAN address |
| `vlan.<name>.subnetId` | int | *required* | Subnet ID for DHCPv6 prefix delegation |
| `vlan.<name>.ipv6PrivacyExtensions` | str | `"no"` | Enable IPv6 privacy extensions |
| `vlan.<name>.enableDHCPv4` | bool | `true` | Enable DHCPv4 server on this VLAN |
| `vlan.<name>.enableDHCPv6` | bool | `true` | Enable DHCPv6 Prefix Delegation on this VLAN |
| `vlan.<name>.enableDNS` | bool | `true` | Enable DNS listener on this VLAN address |

## 📝 Notes

- Requires `systemd-networkd` (enabled automatically).
- Firewall uses `nftables`; NAT is applied to `internalInterfaces`.
- Inter-VLAN isolation drops forwarding between internal interfaces (before NAT rules).
- Set `debug = true` to enable `SYSTEMD_LOG_LEVEL=debug` for troubleshooting.
- DNS listeners are added via `DNSStubListenerExtra` for each enabled interface.

*Minimal router config for NixOS — just works.* 🚀
