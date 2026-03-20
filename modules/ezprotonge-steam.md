# ezprotonge-steam

Automatically downloads and installs the latest [Proton-GE](https://github.com/GloriousEggroll/proton-ge-custom) release into Steam's `compatibilitytools.d`. Always appears in Steam as `GE-Proton-Latest` so games never need to be reconfigured after an update.

## ✨ Features

- Fetches the latest release from the GitHub API
- Always installs under the fixed name `GE-Proton-Latest` — no need to re-select in Steam after updates
- SHA-512 checksum verification before installing
- Skips download if the current version is already installed
- Caches the tarball in `/tmp/ezprotonge-steam` for the session — interrupted downloads are detected and re-fetched
- Exits early with a clear message if Steam is not installed for the user

## 🚀 Quick Start

```nix
services.ezprotonge-steam = {
  enable = true;
  user   = "alice";
};
```

Then run manually or wait for the timer/upgrade trigger:

```bash
systemctl start ezprotonge-steam.service
```

## ⏱️ Run on a Timer

```nix
services.ezprotonge-steam = {
  enable          = true;
  user            = "alice";
  timerOnCalendar = "04:00";
};
```

## 🔄 Run After NixOS Upgrade

```nix
services.ezprotonge-steam = {
  enable           = true;
  user             = "alice";
  afterAutoUpgrade = true;
};
```

## 🔄 Timer and After NixOS Upgrade

```nix
services.ezprotonge-steam = {
  enable           = true;
  user             = "alice";
  timerOnCalendar  = "04:00";
  afterAutoUpgrade = true;
};
```

## ⚙️ All Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `services.ezprotonge-steam.enable` | bool | `false` | Enable the ezprotonge-steam service |
| `services.ezprotonge-steam.user` | str | — | User account to run as — must have Steam installed |
| `services.ezprotonge-steam.timerOnCalendar` | str or null | `null` | systemd `OnCalendar` expression for automatic updates. Set to `null` to disable the timer |
| `services.ezprotonge-steam.afterAutoUpgrade` | bool | `false` | Run after `nixos-upgrade.service` completes |

## 📝 Notes

- Steam must be installed and have been launched at least once for `~/.steam/root` to exist.
- The install is placed at `~/.steam/root/compatibilitytools.d/GE-Proton-Latest`.
- The version is detected from the internal tool key in `compatibilitytool.vdf` — no extra files are written.
- The tarball cache at `/tmp/ezprotonge-steam` is cleared on reboot automatically.
- Run `journalctl -xeu ezprotonge-steam.service` to see output from the last service run.
- To also run it manually from the command line, add `pkgs.ezprotonge-steam` to your `environment.systemPackages`, `users.users.<name>.packages`, or `home.packages`.

*Set it and forget it Proton-GE updates for NixOS.* 🎮
