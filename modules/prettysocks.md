# prettysocks

A simple NixOS module for running PrettySocks as a systemd service, either in the default network namespace or inside isolated named network namespaces via `eznetns`.

## ✨ Features

- Default-namespace service with configurable user/group
- Per-namespace instances bound to `eznetns-<n>.service`
- Automatic system user and group provisioning
- Namespace-scoped DNS and NSS via bind-mounted `resolv.conf` / `nsswitch.conf`

## 🚀 Quick Start

```nix
{
  services.prettysocks = {
    enable = true;
  };
}
```

Or with a named network namespace instance:

```nix
{
  services.prettysocks.instances.myns = {
    enable = true;
  };
}
```

## ⚙️ All Options

### Global Settings

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `services.prettysocks.enable` | bool | `false` | Enable PrettySocks in the default network namespace |
| `services.prettysocks.user` | str | `"prettysocks"` | User under which to run the default-namespace service |
| `services.prettysocks.group` | str | `"proxy"` | Group under which to run the default-namespace service |
| `services.prettysocks.instances` | attrs | `{}` | Per-network-namespace PrettySocks instances |

### Instance Settings (`services.prettysocks.instances.<n>`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `instances.<n>.enable` | bool | `false` | Enable this PrettySocks instance in its network namespace |
| `instances.<n>.user` | str | `"prettysocks"` | User under which to run this instance (a dedicated `prettysocks-<n>` system user is created) |
| `instances.<n>.group` | str | `"nogroup"` | Group under which to run this instance |

## 📝 Notes

- Enabling `services.prettysocks.enable` creates a `prettysocks.service` unit and provisions the configured user and group automatically.
- Each entry in `instances` creates a `prettysocks-<n>.service` unit with a dedicated `prettysocks-<n>` system user.
- Instance services run inside `/run/netns/<n>` and are bound to `eznetns-<n>.service`; if the namespace goes down, the instance stops with it. The namespace can be of any kind.
- Namespace-local DNS resolution is provided by bind-mounting `/etc/eznetns/<n>/resolv.conf` and `/etc/eznetns/<n>/nsswitch.conf` into the service, with nscd disabled via `/var/empty:/var/run/nscd`.
- Both the default service and instances can be active simultaneously.

*Minimal SOCKS proxy module for NixOS network namespaces — just works.* 🚀
