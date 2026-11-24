# ezupgrade

A nightly update of your flake's inputs and a rebuild of the system. Works on NixOS (it
configures `system.autoUpgrade`) and on macOS (nix-darwin, which has none, so it makes a launchd
daemon). With [eznotify](eznotify.md) on, it tells you how the upgrade went.

## 🚀 Quick Start

```nix
services.eznotify = { enable = true; desktop.user = "alice"; };
services.ezupgrade = { enable = true; schedule = "*-*-* 04:00"; };   # flake and user have defaults, see Options
```

## 📋 Options

| Option | Type | Default | Description |
|---|---|---|---|
| `services.ezupgrade.enable` | bool | false | Enable ezupgrade |
| `services.ezupgrade.flake` | str | `/etc/nixos`, or `/Users/<user>/.config/nix-darwin` on macOS | Folder of the flake with the system's configuration |
| `services.ezupgrade.configuration` | str | `"default"` | Name of the configuration in the flake |
| `services.ezupgrade.user` | str | `root`, or `system.primaryUser` on macOS | Owner of the flake folder. Inputs are updated as this user; the rebuild runs as root |
| `services.ezupgrade.schedule` | str | required | When it runs, as a systemd calendar expression: `weekly`, `Sat 04:00`, `Mon..Fri 02:30`, `*-*-* 05:00` (every night at 5) |
| `services.ezupgrade.randomizedDelay` | str | `"0"` | Wait a random time, up to this long, after the scheduled time before it starts: `30s`, `45m`, `1h` or seconds |
| `services.ezupgrade.update` | bool | true | Update the inputs first. Off, it rebuilds what the lock file says |
| `services.ezupgrade.gc.keep` | null or str | null | After a successful rebuild, delete generations older than this (`14d`) and collect garbage. Null: no garbage collection |
| `services.ezupgrade.gc.optimise` | bool | true | After a successful rebuild (and garbage collection), deduplicate the store with hard links (`nix-store --optimise`) |
| `services.ezupgrade.waitForNetwork` | bool | true | Wait until the network answers three times in a row before starting. If it has not in time, the upgrade fails (and eznotify tells) |
| `services.ezupgrade.networkCheckUrl` | str | `"https://cache.nixos.org"` | The address that has to answer |
| `services.ezupgrade.networkTimeout` | positive int | `180` | Seconds to wait for a stable network before giving up |
| `services.ezupgrade.homebrew` | bool | false | macOS only: update Homebrew and upgrade its packages before the rebuild |
| `services.ezupgrade.notify` | bool | true | Tell about it through eznotify, when that is enabled |
| `services.ezupgrade.notifyOnSuccess` | bool | true | Also a message when it worked, not only when it failed |

## 📝 Notes

- The rebuild uses `path:<flake>#<configuration>`, so files not yet in git are included.
- NixOS: the job is `nixos-upgrade`, with the inputs updated in its `preStart`. macOS: the daemon is `ezupgrade`, logging to `/var/log/ezupgrade.log`.
- The message settings (log lines and so on) can be changed under `services.eznotify.units.nixos-upgrade` (NixOS) or `services.eznotify.units.ezupgrade` (macOS).
- `schedule` is a systemd calendar expression. NixOS takes any (`man systemd.time`). macOS (launchd) takes `hourly`, `daily`, `weekly`, `monthly` and `[WEEKDAYS] [*-MONTH-DAY] HH:MM` (weekdays as `Mon`, `Sat,Sun` or `Mon..Fri`; `*` or a number for month and day); anything else stops the build with a message.
- macOS has no randomized delay in launchd, so the daemon sleeps for the random time before it starts.
- macOS: the daemon starts `/run/current-system/sw/bin/ezupgrade-run`, a path that stays the same when the script changes. The daemon's plist then stays the same too, so the rebuild does not restart the daemon (and kill the upgrade) in the middle of the run.
- To replace a hand-made upgrade daemon, remove it and enable this.

*ezupgrade is part of eznixpkgs.*
