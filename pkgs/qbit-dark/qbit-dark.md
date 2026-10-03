# qbit-dark

A dark alternative WebUI for qBittorrent, packaged from [`kalken/qbit-dark`](https://github.com/kalken/qbit-dark).

The upstream repo only holds the theme CSS. The package runs its `build.sh` against the stock WebUI files from `pkgs.qbittorrent-nox.src`, so the WebUI always matches the qBittorrent version from your nixpkgs. Built and tested against qBittorrent 5.2.x. Everything runs offline: no web fonts, CDNs or external images.

If `services.qbittorrent.package` is set to something other than `qbittorrent-nox`, build the WebUI from that package instead:

```nix
pkgs.qbit-dark.override { qbittorrent-nox = config.services.qbittorrent.package; }
```

## 🚀 Quick Start

The package installs the WebUI to `share/qbit-dark` (the folder containing `public/` and `private/`). Point qBittorrent's alternative WebUI at it:

```nix
{ pkgs, ... }:
{
  services.qbittorrent.serverConfig.Preferences.WebUI = {
    AlternativeUIEnabled = true;
    RootFolder = "${pkgs.qbit-dark}/share/qbit-dark";
  };
}
```

Hard-refresh the browser after switching, since the old styles may be cached.

## 🔓 Locked out?

If the WebUI breaks after a qBittorrent upgrade, set `AlternativeUIEnabled = false` to get the stock WebUI back.
