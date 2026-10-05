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
- Optional WireGuard config rotation with ezwgen, on a timer and on demand
- Route selected clients or whole networks through a netns, IPv4 and IPv6

## Wireguard
eznetns can automatically setup wireguard files it finds in **/etc/eznetns/nameofnetns/wireguard/**. Put them there either manually or declaratively. Remember wireguard files are born in the default namespace and moved into the correct netns. Thus the names should be unique. A good naming standard is **wg0-nameofnetns.conf**. Any file not ending with extension .conf will be ignored.

### Rotating the WireGuard config

`ezwgen` builds a WireGuard config by picking a random template and merging your settings (private key and so on) into it. The module can run it for you and reload the interface:

```nix
services.eznetns.instances.surf.wireguard.wg0-surf.rotate = {
  interval = "daily";                   # optional, leave out for manual only
  # source = "/root/.config/ezwgen";    # the default, same as ezwgen itself
};
```

This expects the folder `/root/.config/ezwgen/surf/wg0-surf/` (templates) and writes `/etc/eznetns/surf/wireguard/wg0-surf.conf`. The settings file `/root/.config/ezwgen/surf/wg0-surf.conf` is optional; without it the chosen template is used unchanged. If no config can be generated the service fails instead of reloading the old one.

- Change the config by hand at any time: `systemctl start eznetns-surf-rotate-wg0-surf`
- See when the timer fires next: `systemctl list-timers 'eznetns-*'`
- `source` is read at runtime and never copied to the nix store. Keep it outside your configuration repository: with a flake, anything git tracks is copied into the world-readable nix store, private keys included.

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
- A systemd-networkd config that marks the host end of the veth as unmanaged, so networkd's built-in rules for `ve-*` container interfaces do not replace its addresses.

Things to know:

- **Masquerading on the host hides the client address.** With `networking.nat` and no `externalInterface`, everything from the internal interfaces is masqueraded, including what goes into the netns. The module warns about this. With ezrouter this is handled by `services.ezrouter.wan.masqueradeOnly`, which is on by default.
- **Custom `nftables`.** If the instance sets a complete `nftables` config, accept the forwarded ports yourself: `iifname "host0" tcp dport 8080 accept`.
- **Host forward filtering.** The NixOS firewall accepts DNAT'd connections when `networking.firewall.filterForward` is on. A custom forward chain with policy drop needs `ct status dnat accept`.
- **Connections from the host itself** are not forwarded unless `fromHost = true`, and never when made to `127.0.0.1`. The host can always connect to `veth.nsAddress` directly.
- **UDP.** A service bound to `0.0.0.0` has to reply from the address it was contacted on (most servers do). If replies get lost, bind it to `veth.nsAddress`.
- **Forwarding.** On a host with several networks and no forward filtering, enabling IP forwarding lets it route between them.

## Routing clients through a netns

Clients can be sent through a netns as a whole, so they use its tunnel without any proxy settings. They are selected by the interface they are connected to, by MAC address, or both:

```nix
services.eznetns.instances.surf.route = {
  interfaces = [ "vpn" ];                  # everyone on this VLAN / interface
  macs       = [ "aa:bb:cc:dd:ee:01" ];    # single computers, on any interface
};
```

Both selectors cover IPv4 and IPv6, since they do not depend on the client's addresses.

How it works:

- The host marks the packets of the selected clients as they arrive and routes them to the netns over the veth pair. Traffic to the host itself and to its directly connected networks keeps using the normal routes.
- The netns forwards that traffic, masquerades it out through its default route (the tunnel) and routes the replies back over the veth.
- The clients may leave **only** through the netns. The host firewall drops anything else they try to forward, also while the netns is stopped or the tunnel is down, so they never fall back to the WAN.
- Their DNS lookups go through the netns as well. Queries they send to the host (the usual case, since the router is their DNS server) are redirected to the nameserver of the netns, which is the `DNS =` entry of its WireGuard config. Nothing needs to be configured for this.

Things to know:

- **Requirements.** `networking.nftables.enable`, `networking.firewall.enable` and `networking.firewall.filterForward` (all set by ezrouter). The module refuses to build otherwise, because it could not keep the clients from leaking.
- **IPv6.** Clients keep the IPv6 addresses the router gives them; their IPv6 traffic is masqueraded into the tunnel like IPv4. If the tunnel has no IPv6, their IPv6 connections fail and they fall back to IPv4.
- **MAC addresses.** A device that randomises its MAC address (phones often do, per network) only matches while it uses the listed one. Turn that off on the device, or put it on a routed interface instead.
- **DNS.** With `route.redirectDns` (on by default) lookups sent to the host are answered through the tunnel, over IPv4; DNS over IPv6 to the host is refused so clients fall back to IPv4. If the netns is down or its `resolv.conf` has no IPv4 nameserver, lookups fail rather than go out another way. Names only the router knows (for example ezrouter static lease names) do not resolve for routed clients. Lookups sent to any other DNS server are simply routed through the netns. Set `route.redirectDns = false` to let the host answer as for other clients.
- **Other internal networks.** Because of the firewall rule, routed clients can no longer be routed to other networks behind the router (for example another VLAN). Port forwards into a netns still work.
- **Custom `nftables`.** If the instance sets a complete `nftables` config, allow the forwarding yourself: `iifname "host0" oifname != "host0" accept` in the forward chain.
- **systemd-networkd** is told not to remove routing rules it did not create (`ManageForeignRoutingPolicyRules = false`).

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
| `services.eznetns.instances.<name>.wireguard.<interface>.rotate` | null or submodule | null | Rotate this interface's config with ezwgen, see [Rotating the WireGuard config](#rotating-the-wireguard-config) |
| `services.eznetns.instances.<name>.wireguard.<interface>.rotate.source` | str | /root/.config/ezwgen | Folder with `<name>/<interface>.conf` and `<name>/<interface>/` templates |
| `services.eznetns.instances.<name>.wireguard.<interface>.rotate.pattern` | str | . | Only pick templates whose file name contains this text |
| `services.eznetns.instances.<name>.wireguard.<interface>.rotate.interval` | null or str | null | systemd calendar expression for the timer, null for manual only |
| `services.eznetns.instances.<name>.route.interfaces` | list of str | [] | Host interfaces whose clients are routed through this netns (IPv4 and IPv6), see [Routing clients through a netns](#routing-clients-through-a-netns) |
| `services.eznetns.instances.<name>.route.macs` | list of str | [] | MAC addresses of single clients routed through this netns (IPv4 and IPv6) |
| `services.eznetns.instances.<name>.route.redirectDns` | bool | true | Answer DNS queries routed clients send to the host through the netns, using its nameserver |
| `services.eznetns.instances.<name>.veth.hostInterface` | str | ve-<name> | Host end of the veth pair (max 15 characters) |
| `services.eznetns.instances.<name>.veth.nsInterface` | str | host0 | Netns end of the veth pair |
| `services.eznetns.instances.<name>.veth.hostAddress` | str | 10.200.N.1 | Address of the host end (N derived from the instance name) |
| `services.eznetns.instances.<name>.veth.nsAddress` | str | 10.200.N.2 | Address of the netns end, target of nat forwards |
| `services.eznetns.instances.<name>.veth.hostAddress6` | str | fd7a:657a:N::1 | IPv6 address of the host end, only used with `route.*` |
| `services.eznetns.instances.<name>.veth.nsAddress6` | str | fd7a:657a:N::2 | IPv6 address of the netns end, only used with `route.*` |
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
- Nat port forwards and client routing are set up by eznetns-<name>.service itself; the veth pair only exists for instances that use one of them
- Config files stored in /etc/eznetns/<name>/ (nftables.conf, nsswitch.conf, etc.)
- Services mapped via netnsService get NetworkNamespacePath=/run/netns/<name> and bind mounts
- Default firewall drops input/forward except established connections, ICMP, and loopback
- Set nftables = "..."; to provide complete custom firewall and bypass defaults
- Config changes trigger reloads via CONFIG_HASH environment variable

Isolate services with their own network stack - simple, declarative, systemd-native.
