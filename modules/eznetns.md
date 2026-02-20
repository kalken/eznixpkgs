# eznetns

A NixOS module for managing isolated network namespaces with port forwarding, per-instance firewalls, and service integration via systemd.

## Features

- Create isolated network namespaces (netns) with custom configuration
- Port forwarding via systemd-socket-proxyd (TCP/UDP)
- Per-instance nftables firewall with default secure rules
- Custom /etc files per namespace (nsswitch.conf, resolv.conf, etc.)
- Run existing systemd services inside network namespaces
- Hash-based config change detection for automatic reloads
- automatically setup wireguard files

## Wireguard
eznetns can automatically setup wireguard files it finds in /etc/eznetns/<name>/wireguard/. Put them there either manually or declaratively. Remember wireguard files are born in the default namespace and moved into the correct netns. Thus the names should be unique. A good naming standard is **wg0-nameofnetns.conf**. Any file not ending with extension .conf will be ignored.

## Quick Start

```nix
{
  services.eznetns = {
    enable = true;

    instances.torrent = {
      enable = true;
      
      
      # Forward port 8080 on host to 127.0.0.1:9091 in netns.
      portForwards = [
        {
          listenStreams = [ "0.0.0.0:8080" ];
          target = "127.0.0.1:9091";
        }
      ];
      
      # open port 9091 for incomming traffic
      firewall.extraInputRules = ''
        tcp dport 9091 accept
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

## All Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `services.eznetns.enable` | bool | false | Enable the eznetns module |
| `services.eznetns.package` | package | pkgs.eznetns | The eznetns package to use |
| `services.eznetns.instances.<name>.enable` | bool | false | Enable this netns instance |
| `services.eznetns.instances.<name>.portForwards` | list | [] | Port forwarding rules |
| `services.eznetns.instances.<name>.portForwards[].listenStreams` | list of str | [] | TCP addresses/ports |
| `services.eznetns.instances.<name>.portForwards[].listenDatagrams` | list of str | [] | UDP addresses/ports |
| `services.eznetns.instances.<name>.portForwards[].target` | str | required | Destination address:port inside netns |
| `services.eznetns.instances.<name>.portForwards[].*` | any | - | Extra attrs passed to socketConfig |
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
- Port forwards use eznetns-<name>-forward-*.socket + .service pairs with systemd-socket-proxyd
- Config files stored in /etc/eznetns/<name>/ (nftables.conf, nsswitch.conf, etc.)
- Services mapped via netnsService get NetworkNamespacePath=/run/netns/<name> and bind mounts
- Default firewall drops input/forward except established connections, ICMP, and loopback
- Set nftables = "..."; to provide complete custom firewall and bypass defaults
- Config changes trigger reloads via CONFIG_HASH environment variable

Isolate services with their own network stack - simple, declarative, systemd-native.
