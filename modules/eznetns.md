# eznetns

A NixOS module for managing isolated network namespaces with port forwarding, per-instance firewalls, and service integration via systemd.

## Features

- Create isolated network namespaces (netns) with custom configuration
- Port forwarding via systemd-socket-proxyd (TCP/UDP)
- Routed port forwarding (`mode = "nat"`) that keeps the real client address
- Per-instance nftables firewall with default secure rules
- Custom /etc files per namespace (nsswitch.conf, resolv.conf, etc.)
- Run existing systemd services inside network namespaces
- Hash-based config change detection for automatic reloads
- automatically setup wireguard files

## Wireguard
eznetns can automatically setup wireguard files it finds in **/etc/eznetns/nameofnetns/wireguard/**. Put them there either manually or declaratively. Remember wireguard files are born in the default namespace and moved into the correct netns. Thus the names should be unique. A good naming standard is **wg0-nameofnetns.conf**. Any file not ending with extension .conf will be ignored.

## Quick Start

```nix
{
  services.eznetns = {
    enable = true;

    instances.torrent = {
      enable = true;
      
      
      # Forward port 8081 on host to 127.0.0.1:8080 in netns.
      portForwards = [
        {
          listenStreams = [ "0.0.0.0:8081" ];
          target = "127.0.0.1:8080";
        }
      ];
      
      # open port 49152 from internet to netns
      firewall.extraInputRules = ''
        tcp dport 49152 accept
      '';
    };
    
    # WireGuard config file in /etc/eznetns/torrent/wireguard/wg0-torrent.conf
    configFiles."wireguard/wg0-torrent.conf" = {
      content = ''
        [Interface]
        Address = 10.0.0.2/24
        PrivateKey = YOUR_PRIVATE_KEY
        DNS = 1.1.1.1

        [Peer]
        PublicKey = SERVER_PUBLIC_KEY
        Endpoint = vpn.example.com:51820
        AllowedIPs = 0.0.0.0/0
      '';
    };
    
    # make a specifik systemd-service start inside the netns (enable the service in nixos as usual first)
    netnsService."qbittorrent.service" = "torrent";
  };
}
```

## Port forward modes

Each entry in `portForwards` has a `mode`:

| | `"proxy"` (default) | `"nat"` |
|---|---|---|
| How | systemd-socket-proxyd relays the connection | DNAT on the host, routed into the netns over a veth pair |
| Client address seen by the service | `127.0.0.1` | The real client address |
| Service must listen on | The address in `target` (usually `127.0.0.1`) | `0.0.0.0` or `veth.nsAddress` |
| `target` | `address:port` in the netns, required | Port only, defaults to the listen port |
| Restrict by interface / source | Socket options such as `BindToDevice` | `interfaces`, `allowedSources` |
| IP version | IPv4 and IPv6 | IPv4 only |

```nix
services.eznetns.instances.torrent = {
  enable = true;

  portForwards = [
    # proxy: the service sees 127.0.0.1
    { listenStreams = [ "0.0.0.0:9090" ]; target = "127.0.0.1:9090"; }

    # nat: the service sees who is connecting
    {
      mode = "nat";
      interfaces = [ "br0" "vlan30" ];        # optional, default: all interfaces
      allowedSources = [ "192.168.30.0/24" ]; # optional, default: any source
      listenStreams = [ "8080" ];             # "port" or "ipv4:port"
      listenDatagrams = [ "6881" ];
    }
  ];
};
```

What an instance with `nat` forwards sets up:

- A veth pair between the host (`ve-<name>`) and the netns (`host0`), with addresses from `veth.hostAddress` / `veth.nsAddress`. The defaults are derived from the instance name; read them with `config.services.eznetns.instances.<name>.veth.nsAddress`.
- DNAT rules on the host in the nftables table `ip eznetns-<name>`. They only match traffic addressed to the host itself, never traffic routed through it. The table is loaded when the instance starts and removed when it stops.
- Connection marking in the netns (table `ip eznetns-nat`) and a routing rule, so replies to forwarded connections go back over the veth. Everything the service initiates itself keeps using the normal routes of the netns (the VPN).
- Accept rules for the forwarded ports in the generated netns firewall.
- IPv4 forwarding on the host (`net.ipv4.conf.all.forwarding`).

Things to know:

- **Masquerading on the host hides the client address.** With `networking.nat` and no `externalInterface`, everything from the internal interfaces is masqueraded, including what goes into the netns. The module warns about this. With ezrouter, set `services.ezrouter.wan.masqueradeOnly = true`.
- **Custom `nftables`.** If the instance sets a complete `nftables` config, accept the forwarded ports yourself: `iifname "host0" tcp dport 8080 accept`.
- **Host forward filtering.** The NixOS firewall accepts DNAT'd connections when `networking.firewall.filterForward` is on. A custom forward chain with policy drop needs `ct status dnat accept`.
- **Connections from the host itself** are not forwarded unless `fromHost = true`, and never when made to `127.0.0.1`. The host can always connect to `veth.nsAddress` directly.
- **UDP.** A service bound to `0.0.0.0` has to reply from the address it was contacted on (most servers do). If replies get lost, bind it to `veth.nsAddress`.
- **Forwarding.** On a host with several networks and no forward filtering, enabling IP forwarding lets it route between them.

## All Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `services.eznetns.enable` | bool | false | Enable the eznetns module |
| `services.eznetns.package` | package | pkgs.eznetns | The eznetns package to use |
| `services.eznetns.instances.<name>.enable` | bool | false | Enable this netns instance |
| `services.eznetns.instances.<name>.portForwards` | list | [] | Port forwarding rules |
| `services.eznetns.instances.<name>.portForwards[].listenStreams` | list of str | [] | TCP addresses/ports |
| `services.eznetns.instances.<name>.portForwards[].listenDatagrams` | list of str | [] | UDP addresses/ports |
| `services.eznetns.instances.<name>.portForwards[].target` | null or str | null | proxy: destination address:port inside netns (required). nat: destination port, defaults to the listen port |
| `services.eznetns.instances.<name>.portForwards[].mode` | "proxy" or "nat" | "proxy" | See [Port forward modes](#port-forward-modes) |
| `services.eznetns.instances.<name>.portForwards[].interfaces` | list of str | [] | nat only: host interfaces to forward from (empty = all) |
| `services.eznetns.instances.<name>.portForwards[].allowedSources` | list of str | [] | nat only: source addresses/networks to forward (empty = any) |
| `services.eznetns.instances.<name>.portForwards[].fromHost` | bool | false | nat only: also forward connections made by the host itself |
| `services.eznetns.instances.<name>.portForwards[].*` | any | - | proxy only: extra attrs passed to socketConfig |
| `services.eznetns.instances.<name>.veth.hostInterface` | str | ve-<name> | Host end of the veth pair (max 15 characters) |
| `services.eznetns.instances.<name>.veth.nsInterface` | str | host0 | Netns end of the veth pair |
| `services.eznetns.instances.<name>.veth.hostAddress` | str | 10.200.N.1 | Address of the host end (N derived from the instance name) |
| `services.eznetns.instances.<name>.veth.nsAddress` | str | 10.200.N.2 | Address of the netns end, target of nat forwards |
| `services.eznetns.instances.<name>.veth.prefixLength` | int | 30 | Prefix length of the veth addresses |
| `services.eznetns.instances.<name>.nftables` | null or str | null | Complete nftables config |
| `services.eznetns.instances.<name>.nsswitch` | str | standard | Content of /etc/nsswitch.conf |
| `services.eznetns.instances.<name>.configFiles` | attrs | {} | Extra files in /etc/eznetns/<name>/ |
| `services.eznetns.instances.<name>.configFiles.<file>.content` | str | required | File content |
| `services.eznetns.instances.<name>.configFiles.<file>.mode` | str | 0644 | File permissions |
| `services.eznetns.instances.<name>.configFiles.<file>.user` | str | root | File owner |
| `services.eznetns.instances.<name>.configFiles.<file>.group` | str | root | File group |
| `services.eznetns.instances.<name>.firewall.enable` | bool | true | Enable nftables firewall |
| `services.eznetns.instances.<name>.firewall.extraInputRules` | str | "" | Extra rules for input chain |
| `services.eznetns.instances.<name>.firewall.extraForwardRules` | str | "" | Extra rules for forward chain |
| `services.eznetns.netnsService."<service>.service"` | str | required | eznetns instance name |

## Notes

- Each netns instance creates a oneshot eznetns-<name>.service for setup/reload/teardown
- Proxy port forwards use eznetns-<name>-forward-*.socket + .service pairs with systemd-socket-proxyd
- Nat port forwards are set up by eznetns-<name>.service itself; the veth pair only exists for instances that have one
- Config files stored in /etc/eznetns/<name>/ (nftables.conf, nsswitch.conf, etc.)
- Services mapped via netnsService get NetworkNamespacePath=/run/netns/<name> and bind mounts
- Default firewall drops input/forward except established connections, ICMP, and loopback
- Set nftables = "..."; to provide complete custom firewall and bypass defaults
- Config changes trigger reloads via CONFIG_HASH environment variable

Isolate services with their own network stack - simple, declarative, systemd-native.
