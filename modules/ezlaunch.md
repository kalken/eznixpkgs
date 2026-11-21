# ezlaunch

Install and launch Windows games with Proton, without Steam or a launcher app. Double-click a `setup.exe`, and the game ends up in the start menu with right-click **Settings** and **Remove**.

## ✨ Features

- Double-click a `.exe`: it runs in a new prefix with [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher), then you pick the game's exe and a start menu entry (with the exe's icon) is written
- One prefix per game, in `~/.local/share/ezlaunch/games/<name>/`
- Any Proton option works: settings are plain `KEY=value` environment variables
- Right-click **Settings** opens a small menu:
  - **Options**: checklist of common options (HDR, Wayland, NTSync, NVAPI, MangoHud, GameMode, ...) and a free-text field for any other variable
  - **Proton version**: choose from the versions installed in `~/.local/share/Steam/compatibilitytools.d`
  - **Change executable**: pick another exe for the game (refreshes the icon and the menu entry)
  - **Change icon**: pick an image (png, svg), an `.ico` or an `.exe` to take the icon from
- Right-click **Stop**: closes the game if it is running
- Right-click **Remove**: deletes the game, its prefix and its menu entry
- In a terminal, leave out the game name (`ezlaunch run`, `settings`, `exe`, `remove`) to choose it from an arrow-key menu (fzf)
- `ezlaunch list` shows the games and marks the running ones, `ezlaunch running` lists only those, `ezlaunch stop` closes one (it finds a game's processes by its prefix)
- A tray icon shows the running game (its icon and name) with **Stop** and **Settings** in its menu, and disappears when the game ends. Nothing runs in the background otherwise.

## 🚀 Quick Start

```nix
programs.ezlaunch.enable = true;

# Proton for ezlaunch to use (works without Steam installed)
services.ezproton = {
  enable = true;
  user = "alice";
};
```

Then double-click a `setup.exe`.

## ⚙️ Defaults

`programs.ezlaunch.defaults` is written to `/etc/ezlaunch/config`. Every game starts with these variables:

```nix
programs.ezlaunch.defaults = {
  PROTONPATH = "GE-Proton-Latest"; # the default
  PROTON_ENABLE_WAYLAND = true;
  MANGOHUD = true;
};
```

Settings are layered, later wins: `/etc/ezlaunch/config`, `~/.config/ezlaunch/config`, then the game's own `config`. A change in the defaults applies to every game that does not set the variable itself.

## ⚙️ All Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `programs.ezlaunch.enable` | bool | `false` | Enable ezlaunch |
| `programs.ezlaunch.package` | package | `pkgs.ezlaunch` | The ezlaunch package |
| `programs.ezlaunch.defaults` | attrs of str, int or bool | `{ PROTONPATH = "GE-Proton-Latest"; }` | Variables every game starts with. Booleans become 1 and 0 |
| `programs.ezlaunch.exeHandler` | bool | `true` | Open `.exe` files with `ezlaunch add` when double-clicked |

## 📝 Notes

- `PROTONPATH` can be a name from `~/.local/share/Steam/compatibilitytools.d` (what ezproton installs), a full path, or a version umu downloads itself.
- The screen is kept awake while a game runs, since a controller does not count as activity for the idle timer: `kde-inhibit` on KDE, `systemd-inhibit` elsewhere (used if installed). Set `EZLAUNCH_INHIBIT=0` in the defaults or a game's custom variables to turn it off.
- Set `EZLAUNCH_TRAY=0` to turn the tray icon off. It needs `yad` (bundled) and a desktop with a system tray: KDE works, GNOME needs the AppIndicator extension.
- Special variables in a game's `config`: `EZLAUNCH_EXE` (the game's exe), `EZLAUNCH_ARGS` (arguments for the game) and `EZLAUNCH_WRAPPER` (a command prefix, such as `gamemoderun`).
- Dialogs use `kdialog` on KDE and `zenity` otherwise. zenity is bundled; kdialog is used if it is installed.
- Command line: `ezlaunch add [setup.exe]`, `run <game>`, `settings <game>`, `exe <game>`, `icon <game>`, `remove <game>`, `list`, `running`, `stop <game>`.
- Start menu entries are `~/.local/share/applications/ezlaunch-<name>.desktop`. Right-click actions need a desktop that supports them (KDE, GNOME, XFCE, ...); some launchers such as rofi ignore them.
- Installers run through Proton. Nothing is extracted by hand, so registry entries and redistributables work as usual.

*Double-click, play.* 🎮
