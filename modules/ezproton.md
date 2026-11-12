# ezproton

Automatically downloads and installs the latest [Proton-GE](https://github.com/GloriousEggroll/proton-ge-custom) and/or [CachyOS Proton](https://github.com/CachyOS/proton-cachyos) release into Steam's `compatibilitytools.d`. Always installed under fixed names — `GE-Proton-Latest` and `Proton-CachyOS-Latest` — so games never need to be reconfigured after an update.

## ✨ Features

- Fetches the latest release from the GitHub API for each selected variant
- Always installs under fixed names (`GE-Proton-Latest`, `Proton-CachyOS-Latest`) — no need to re-select in Steam after updates
- SHA-512 checksum verification before installing
- Skips download if the current version is already installed
- Caches each variant's tarball under `/tmp/ezproton` for the session — interrupted downloads are detected and re-fetched
- Exits early with a clear message if Steam is not installed for the user

## 🚀 Quick Start

By default both Proton-GE and CachyOS Proton are installed and kept up to date:

```nix
services.ezproton = {
  enable = true;
  user   = "alice";
};
```

Then run manually or wait for the timer/upgrade trigger:

```bash
systemctl start ezproton.service
```

## 📌 Pinning Specific Versions

```nix
services.ezproton = {
  enable   = true;
  user     = "alice";
  variants = [ "ge" ];                      # keep GE-Proton-Latest updated
  versions.ge = [ "GE-Proton10-5" ];        # plus this exact release
};
```

Set `variants = [ ]` to install only the pinned versions. A tag that doesn't exist is logged and doesn't stop the other installs; use `ezproton --list` to see valid tags.

## 🎯 Choosing Variants

Install only Proton-GE:

```nix
services.ezproton = {
  enable   = true;
  user     = "alice";
  variants = [ "ge" ];
};
```

Install only CachyOS Proton:

```nix
services.ezproton = {
  enable   = true;
  user     = "alice";
  variants = [ "cachyos" ];
};
```

## ⏱️ Run on a Timer

```nix
services.ezproton = {
  enable          = true;
  user            = "alice";
  timerOnCalendar = "04:00";
};
```

## 🔄 Run After NixOS Upgrade

```nix
services.ezproton = {
  enable           = true;
  user             = "alice";
  afterAutoUpgrade = true;
};
```

## 🔄 Timer and After NixOS Upgrade

```nix
services.ezproton = {
  enable           = true;
  user             = "alice";
  timerOnCalendar  = "04:00";
  afterAutoUpgrade = true;
};
```

## ⚙️ All Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `services.ezproton.enable` | bool | `false` | Enable the ezproton service |
| `services.ezproton.user` | str | — | User account to run as — must have Steam installed |
| `services.ezproton.variants` | list of `"ge"` \| `"cachyos"` | `[ "ge" "cachyos" ]` | Which Proton variant(s) to install and keep updated |
| `services.ezproton.versions.ge` | list of str | `[]` | Specific Proton-GE tags to install (e.g. `"GE-Proton10-5"`), next to the `*-Latest` builds |
| `services.ezproton.versions.cachyos` | list of str | `[]` | Specific CachyOS Proton tags to install |
| `services.ezproton.timerOnCalendar` | str or null | `null` | systemd `OnCalendar` expression for automatic updates. Set to `null` to disable the timer |
| `services.ezproton.afterAutoUpgrade` | bool | `false` | Run after `nixos-upgrade.service` completes |

## 📝 Notes

- Steam must be installed and have been launched at least once for `~/.steam/root` to exist.
- Installs are placed at `~/.steam/root/compatibilitytools.d/GE-Proton-Latest` and/or `~/.steam/root/compatibilitytools.d/Proton-CachyOS-Latest`.
- The internal tool key is pinned to the `*-Latest` name so Steam selections survive upgrades; the installed tag is recorded in `.ezproton-version` inside the install directory.
- `ezproton --list` (optionally with `--variant`) prints the 30 most recent release tags.
- To install a specific release from the command line, use `ezproton --variant ge --release GE-Proton10-5`. It is installed next to the `*-Latest` build under its own tag name.
- The tarball cache at `/tmp/ezproton` is cleared on reboot automatically.
- Run `journalctl -xeu ezproton.service` to see output from the last service run.
- To also run it manually from the command line, add `pkgs.ezproton` to your `environment.systemPackages`, `users.users.<name>.packages`, or `home.packages`, then run `ezproton --latest` (optionally with `--variant ge` and/or `--variant cachyos`). Running `ezproton` with no arguments shows the help.

*Set it and forget it Proton updates for NixOS.* 🎮
