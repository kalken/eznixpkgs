# ezupgrade

A nightly update of your flake's inputs and a rebuild of the system. Works on NixOS (it
configures `system.autoUpgrade`) and on macOS (nix-darwin, which has none, so it makes a launchd
daemon). With [eznotify](eznotify.md) on, it tells you how the upgrade went.

## 🚀 Quick Start

```nix
services.eznotify = { enable = true; desktop.user = "alice"; };
services.ezupgrade = {
  enable = true;
  flake = "/Users/alice/.config/nix-darwin";
  user = "alice";
};
```

## 📋 Options

| Option | Type | Default | Description |
|---|---|---|---|
| `services.ezupgrade.enable` | bool | false | Enable ezupgrade |
| `services.ezupgrade.flake` | str | | Folder of the flake with the system's configuration |
| `services.ezupgrade.configuration` | str | `"default"` | Name of the configuration in the flake |
| `services.ezupgrade.user` | str | | Owner of the flake folder. Inputs are updated as this user; the rebuild runs as root |
| `services.ezupgrade.time` | str | `"04:00"` | When it runs each day, `HH:MM` |
| `services.ezupgrade.randomizedDelay` | str | `"0"` | Wait a random time, up to this long, after `time` before it starts: `30s`, `45m`, `1h` or seconds |
| `services.ezupgrade.update` | bool | true | Update the inputs first. Off, it rebuilds what the lock file says |
| `services.ezupgrade.notify` | bool | true | Tell about it through eznotify, when that is enabled |
| `services.ezupgrade.notifyOnSuccess` | bool | true | Also a message when it worked, not only when it failed |

## 📝 Notes

- The rebuild uses `path:<flake>#<configuration>`, so files not yet in git are included.
- NixOS: the job is `nixos-upgrade`, with the inputs updated in its `preStart`. macOS: the daemon is `ezupgrade`, logging to `/var/log/ezupgrade.log`.
- The message settings (log lines and so on) can be changed under `services.eznotify.units.nixos-upgrade` (NixOS) or `services.eznotify.units.ezupgrade` (macOS).
- macOS has no randomized delay in launchd, so the daemon sleeps for the random time before it starts.
- To replace a hand-made upgrade daemon, remove it and enable this.

*ezupgrade is part of eznixpkgs.*
