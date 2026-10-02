# qbit-dark

A dark alternative WebUI for qBittorrent, packaged from [`kalken/qbit-dark`](https://github.com/kalken/qbit-dark).

Based on the stock WebUI from qBittorrent **5.2.4**, so use it with qBittorrent 5.2.x. Everything runs offline: no web fonts, CDNs or external images.

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
