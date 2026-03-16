# ezrouter

A simple NixOS module for router setup with VLANs, DHCPv4/DHCPv6, DNS, and firewall using `systemd-networkd` + `nftables`.

## ✨ Features

- Bridge + VLAN interfaces via `systemd-networkd`
- DHCPv4 server & DHCPv6 Prefix Delegation
- DNS via `systemd-resolved`
- Optional inter-VLAN isolation with `nftables`
- NAT for internal interfaces
- Native Firewall rules are used.
- **Smart defaults**: VLAN `address` and `subnetId` auto-derived from VLAN ID (only `id` is required)

## 🚀 Quick Start

```nix
{
  services.ezrouter = {
    # activate service
    enable = true;
    
    # external interface
    wan.device = "eth0";
    
    # internal interfaces
    bridge.devices = [ "eth1" ];

    # optional vlans (add one row per vlan)
    vlan.guests.id = 10;
  };
}
```

## ⚙️ All Options

### Global Settings

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `services.ezrouter.enable` | bool | `false` | Enable the ezrouter module |
| `services.ezrouter.debug` | bool | `false` | Enable debug logging (`SYSTEMD_LOG_LEVEL=debug`) for `systemd-networkd` |
| `services.ezrouter.isolateVlans` | bool | `true` | Block traffic between VLANs (inter-VLAN isolation) |
| `services.ezrouter.vlanFirewallPorts.allowedTCPPorts` | list of port | `[]` | TCP ports to open from all VLAN interfaces to router |
| `services.ezrouter.vlanFirewallPorts.allowedUDPPorts` | list of port | `[53 67]` | UDP ports to open from all VLAN interfaces to router (DNS + DHCP) |
| `services.ezrouter.trustedInterfaces` | list of str | `[bridge.name]` | Interfaces with no firewall restrictions |
| `services.ezrouter.internalInterfaces` | list of str | *auto* | Internal interfaces for NAT/masquerading (default: bridge + all VLANs) |

### WAN Settings (`services.ezrouter.wan`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `wan.device` | str | *required* | WAN interface name (e.g., `"eth0"`) |
| `wan.ipv6PrivacyExtensions` | str | `"no"` | Enable IPv6 privacy extensions (`"no"`, `"yes"`, `"kernel"`) |
| `wan.prefixHint` | int | `56` | DHCPv6 prefix delegation hint (e.g., `56` for `/56`, `64` for `/64`) |
| `wan.keepConfiguration` | enum | `"no"` | Keep WAN config when link goes down. Values: `"no"`, `"static"`, `"dynamic-on-stop"`, `"dynamic"`, `"yes"`. Use `"static"` or  `"dynamic-on-stop"` to retain addresses/routes across reboots while waiting for DHCPv6 lease renewal. |

### Bridge Settings (`services.ezrouter.bridge`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `bridge.name` | str | `"lan"` | Name of the bridge interface |
| `bridge.devices` | list of str | `[]` | Physical interfaces to attach to bridge |
| `bridge.address` | str | `"192.168.1.1"` | IPv4 address for the bridge |
| `bridge.netmask` | str | `"24"` | Netmask/CIDR for bridge address |
| `bridge.subnetId` | int | `1` | Subnet ID for DHCPv6 prefix delegation |
| `bridge.ipv6PrivacyExtensions` | str | `"no"` | Enable IPv6 privacy extensions |
| `bridge.enableDHCPv4` | bool | `true` | Enable DHCPv4 server on bridge |
| `bridge.enableDHCPv6` | bool | `true` | Enable DHCPv6 Prefix Delegation on bridge |
| `bridge.enableDNS` | bool | `true` | Advertise router as DNS server via DHCP on bridge |

### VLAN Settings (`services.ezrouter.vlan.<name>`)

> 💡 **Smart Defaults**: Only `id` is required. All other fields are optional and auto-derived from the VLAN ID.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `vlan.<name>.id` | int | *required* | VLAN ID (1–4094). Used to derive `address` and `subnetId` if not specified. |
| `vlan.<name>.address` | str | `"192.168.<id>.1"` | IPv4 address for the VLAN interface. Auto-derived from `id` if omitted (e.g., `id=30` → `192.168.30.1`). |
| `vlan.<name>.netmask` | str | `"24"` | Netmask/CIDR for VLAN address. |
| `vlan.<name>.subnetId` | int | `<id>` | Subnet ID for DHCPv6 prefix delegation. Defaults to match `id` if omitted. |
| `vlan.<name>.ipv6PrivacyExtensions` | str | `"no"` | Enable IPv6 privacy extensions. |
| `vlan.<name>.enableDHCPv4` | bool | `true` | Enable DHCPv4 server on this VLAN. |
| `vlan.<name>.enableDHCPv6` | bool | `true` | Enable DHCPv6 Prefix Delegation + RA on this VLAN. |
| `vlan.<name>.enableDNS` | bool | `true` | Advertise router as DNS server via DHCP on this VLAN. |

#### VLAN Example Patterns

```nix
# Minimal: ONLY specify VLAN ID
vlan.iot = { id = 30; };
# → address="192.168.30.1", subnetId=30, all services enabled

# Override specific defaults
vlan.cameras = {
  id = 50;
  address = "172.16.50.1";  # custom private subnet
  netmask = "23";            # larger subnet
};

# Disable services for a VLAN
vlan.dmz = {
  id = 99;
  enableDHCPv4 = false;
  enableDHCPv6 = false;
  enableDNS = false;
};
```

## 🔐 Firewall & NAT Behavior

- **NAT**: Applied to all interfaces in `internalInterfaces` (default: bridge + all VLANs)
- **Inter-VLAN isolation**: When `isolateVlans = true`, forwarding between internal interfaces is dropped *before* NAT rules
- **VLAN firewall ports**: `allowedTCPPorts` / `allowedUDPPorts` apply to **all VLAN interfaces** (not bridge/WAN)
- **Trusted interfaces**: Listed in `trustedInterfaces` bypass firewall restrictions (default: bridge only)

## 🌐 DNS Configuration

- `systemd-resolved` is enabled automatically
- DNS listeners (`DNSStubListenerExtra`) are added for:
  - Bridge interface (if `bridge.enableDNS = true`)
  - Each VLAN with `enableDNS = true`
- DHCP servers advertise the router's address as DNS when `enableDNS = true`

## 🛠️ Troubleshooting

```nix
services.ezrouter.debug = true;  # Enables SYSTEMD_LOG_LEVEL=debug
```

Then check logs:
```bash
journalctl -u systemd-networkd -f
journalctl -u systemd-resolved -f
nft list ruleset  # inspect firewall/NAT rules
```

## 📋 Requirements

- `systemd-networkd` (enabled automatically by the module)
- `nftables` firewall backend (enabled automatically)
- Kernel support for VLANs and bridge networking

## 🔄 Migration Notes (from older versions)

- **VLAN definitions are now minimal**: You **only** need to specify `id`. `address` and `subnetId` are optional and auto-derived.
- **`wan.keepConfiguration` is now an enum**: If you previously used `true`, replace with `"yes"` or `"static"` depending on desired behavior.
- **Firewall ports apply to VLANs only**: `vlanFirewallPorts` now affects VLAN interfaces explicitly, not the bridge.

---

*Minimal router config for NixOS — just works.* 🚀
