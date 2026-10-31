# ezsocks-rs

A NixOS module for running ezsocks-rs, a small SOCKS5 proxy written in Rust, either in the default network namespace or inside `eznetns` network namespaces. Point browsers on other machines at an instance to send their traffic, DNS lookups included, through that namespace's VPN.

Built from [`kalken/ezsocks-rs`](https://github.com/kalken/ezsocks-rs), branch `develop`. It lives next to the Python [`ezsocks`](ezsocks.md) module, so instances can be moved over one at a time.

## ✨ Features

- SOCKS5 `CONNECT` without authentication; restrict who can reach the port with the firewall
- Happy Eyeballs (RFC 8305): IPv6 and IPv4 looked up in parallel and connection attempts raced, preferring IPv6; `family = "ipv4"` skips IPv6 completely
- Host name lookups cached for 60 seconds
- Data passed with `splice()`, never copied into the process; about 2 MB of memory per instance
- Runs with `DynamicUser`, no system users to manage

## 🚀 Quick Start

```nix
{
  services.ezsocks-rs.enable = true;
}
```

Instances in eznetns namespaces, named after the namespace:

```nix
{
  services.ezsocks-rs.instances = {
    surf = {
      enable = true;
      settings.listenHost = [ config.services.eznetns.instances.surf.veth.nsAddress ];
      settings.family = "ipv4";
    };
    # a second one in the same netns
    surf-alt = { enable = true; netns = "surf"; settings.listenPort = 1081; };
  };
}
```

## ⚙️ All Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `services.ezsocks-rs.enable` | bool | `false` | Run ezsocks-rs in the default network namespace (`ezsocks-rs.service`) |
| `services.ezsocks-rs.settings` | attrs | `{}` | Settings for that service (see below) |
| `services.ezsocks-rs.instances.<name>.enable` | bool | `false` | Run this instance (`ezsocks-rs-<name>.service`) |
| `services.ezsocks-rs.instances.<name>.netns` | null or str | `<name>` | eznetns instance to run in; `null` runs it in the default network namespace |
| `services.ezsocks-rs.instances.<name>.settings` | attrs | `{}` | Settings for this instance (see below) |

### Settings

| Option | Type | Default | Flag | Description |
|--------|------|---------|------|-------------|
| `listenHost` | list of str | `["127.0.0.1" "::1"]` | `--listen` | Addresses or host names to listen on; a host name listens on all of its addresses |
| `listenPort` | port | `1080` | `--listen` | Port to listen on |
| `family` | `"any"`, `"ipv4"` or `"ipv6"` | `"any"` | `--family` | Address families to connect out with |
| `threads` | int or `"auto"` | `1` | `--threads` | Worker threads; `"auto"` uses one per CPU core |
| `logLevel` | enum | `"WARNING"` | `--log-level` | `DEBUG`, `INFO`, `WARNING` or `ERROR`; `INFO` logs every connection with its destination |
| `dnsCacheTtl` | int | `60` | `--dns-cache-ttl` | Seconds to cache host name lookups; failed lookups are not cached; `0` disables |
| `handshakeTimeout` | int or float | `30` | `--handshake-timeout` | Seconds a client gets to send its request; `0` disables |
| `connectTimeout` | int or float | `30` | `--connect-timeout` | Seconds to connect to the destination; `0` disables |
| `keepaliveIdle` | int | `300` | `--keepalive` | Seconds of silence before TCP keepalive probes, so connections to vanished peers are dropped; `0` disables |

## 📝 Notes

- An instance with `netns` set is added to `services.eznetns.netnsService`, so eznetns runs it inside `/run/netns/<netns>` with that namespace's DNS. This needs `services.eznetns.enable`.
- An ezsocks and an ezsocks-rs instance in the same namespace can't both listen on the same address and port; give one a different `listenPort`, or disable the other.
- Services run with `LimitNOFILE=65536`: each proxied connection uses six file descriptors (two sockets, two pipes).
- In browsers, turn on remote DNS ("Proxy DNS when using SOCKS v5" in Firefox, `socks5h://` elsewhere), or names get looked up outside the namespace.
