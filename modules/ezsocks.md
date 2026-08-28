# ezsocks

A simple NixOS module for running EzSocks as a systemd service, either in the default network namespace or inside isolated named network namespaces via `eznetns`.

Built from [`kalken/ezsocks`](https://github.com/kalken/ezsocks), branch `master` — a fork of [`twisteroidambassador/prettysocks`](https://github.com/twisteroidambassador/prettysocks) with worker-process support and a TOML config file.

> **Renamed from `prettysocks`**: the package and module used to be called `prettysocks`. `services.prettysocks.*` options still work and are forwarded to `services.ezsocks.*` with a deprecation warning; update your config when convenient.

## ✨ Features

- Default-namespace service with configurable user/group
- Per-namespace instances bound to `eznetns-<name>.service`
- Automatic system user and group provisioning
- Namespace-scoped DNS and NSS via bind-mounted `resolv.conf` / `nsswitch.conf`
- Multi-process worker support (`SO_REUSEPORT`) for spreading load across CPU cores
- Runs on `uvloop` for a faster event loop (falls back to stdlib `asyncio` if unavailable, but the package always includes it)
- Full proxy tuning (Happy Eyeballs parameters, relay buffer size, listen backlog, log level) exposed as Nix options, written to a generated TOML config file per service
- Listens on `127.0.0.1:1080` and `[::1]:1080` (SOCKS5) by default

## 🚀 Quick Start

```nix
{
  services.ezsocks = {
    enable = true;
  };
}
```

Or with a named network namespace instance:

```nix
{
  services.ezsocks.instances.myns = {
    enable = true;
  };
}
```

With custom settings, e.g. running 4 worker processes and listening on all interfaces:

```nix
{
  services.ezsocks = {
    enable = true;
    settings = {
      listenHost = [ "0.0.0.0" "::" ];
      workerProcesses = 4;
    };
  };
}
```

## ⚙️ All Options

### Global Settings

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `services.ezsocks.enable` | bool | `false` | Enable EzSocks in the default network namespace |
| `services.ezsocks.user` | str | `"ezsocks"` | User under which to run the default-namespace service |
| `services.ezsocks.group` | str | `"proxy"` | Group under which to run the default-namespace service |
| `services.ezsocks.settings` | attrs | `{}` | EzSocks proxy settings for the default-namespace service (see below) |
| `services.ezsocks.instances` | attrs | `{}` | Per-network-namespace EzSocks instances |

### Instance Settings (`services.ezsocks.instances.<name>`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `instances.<name>.enable` | bool | `false` | Enable this EzSocks instance in its network namespace |
| `instances.<name>.user` | str | `"ezsocks"` | User under which to run this instance (a dedicated `ezsocks-<name>` system user is created) |
| `instances.<name>.group` | str | `"nogroup"` | Group under which to run this instance |
| `instances.<name>.settings` | attrs | `{}` | EzSocks proxy settings for this instance (see below) |

### Proxy Settings (`settings`, shared by the default service and each instance)

| Option | Type | Default | TOML key | Description |
|--------|------|---------|----------|--------------|
| `listenHost` | list of str | `["127.0.0.1" "::1"]` | `listen_host` | Addresses to listen on |
| `listenPort` | port | `1080` | `listen_port` | Port to listen on |
| `listenBacklog` | int | `1024` | `listen_backlog` | Backlog for the listening socket(s) |
| `logLevel` | enum | `"WARNING"` | `log_level` | One of `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL` |
| `useBuiltinHappyEyeballs` | bool | `false` | `use_builtin_happy_eyeballs` | Use Python's built-in Happy Eyeballs implementation instead of `async-stagger` |
| `resolutionDelay` | float | `0.05` | `resolution_delay` | (async-stagger only) Delay in seconds before resolving the next address family (RFC 8305 §8) |
| `firstAddressFamilyCount` | int | `1` | `first_address_family_count` | Addresses of the first resolved family to try before interleaving (RFC 8305 §8) |
| `connectionAttemptDelay` | float | `0.25` | `connection_attempt_delay` | Delay in seconds between successive connection attempts (RFC 8305 §8) |
| `workerProcesses` | int or `"auto"` | `"auto"` | `worker_processes` | Number of worker processes sharing the listen port via `SO_REUSEPORT`; `"auto"` uses one per CPU core |
| `relayBufferSize` | int | `131072` | `relay_buffer_size` | Buffer size, in bytes, used to relay data between downstream and upstream connections |

## 📝 Notes

- Enabling `services.ezsocks.enable` creates an `ezsocks.service` unit and provisions the configured user and group automatically.
- Each entry in `instances` creates an `ezsocks-<name>.service` unit with a dedicated `ezsocks-<name>` system user.
- Instance services run inside `/run/netns/<name>` and are bound to `eznetns-<name>.service`; if the namespace goes down, the instance stops with it. The namespace can be of any kind.
- Namespace-local DNS resolution is provided by bind-mounting `/etc/eznetns/<name>/resolv.conf` and `/etc/eznetns/<name>/nsswitch.conf` into the service, with nscd disabled via `/var/empty:/var/run/nscd`.
- Each service (default and every instance) gets its own generated TOML config file passed via `--config`, built from the `settings` submodule — the underlying `ezsocks` binary defaults are not used.
- `workerProcesses` > 1 requires `SO_REUSEPORT` support (Linux, *BSD, macOS; not Windows) — fine for NixOS.
- Both the default service and instances can be active simultaneously, each with independent `settings`.

*Minimal SOCKS proxy module for NixOS network namespaces — just works.* 🚀
