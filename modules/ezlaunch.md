# ezlaunch

Install and launch Windows programs and games with Proton, without Steam or a launcher app. Double-click a `setup.exe`, and the program ends up in the start menu with right-click **Settings** and **Remove**.

## ✨ Features

- Double-click an exe and choose **Install** (runs the installer in a new prefix with [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher), then you pick the game's exe) or **Add** (adds a game that is on the disk, started from where it is). The same dialog has a Proton version list, with the default preselected, and a category (Game, Utility, Office, Internet, ...) that decides where the entry goes in the start menu. Either way a start menu entry, with the exe's icon, is written
- If the installer made more than one shortcut (the game, an editor, a launcher, ...), you tick which ones go in the start menu. The first is the game. With more than one, they are grouped in a start menu folder named after the game, on desktops with a classic menu (KDE, XFCE, Cinnamon, MATE; GNOME shows them flat). They all run in the same prefix and share its settings
- To put a second program in a prefix that exists, right-click the exe, **Open With**, **Install in an existing ezlaunch prefix**, and pick the game. The installer runs in that prefix with the game's own Proton version, then the shortcuts list opens with the new ones ticked. Programs in one prefix share its settings
- **Add to an existing ezlaunch prefix** (also under Open With) takes any exe on the disk, with no Windows shortcut needed, asks for a name and adds it as another start menu entry of the game you pick. It runs in that game's prefix
- Right-click **Choose shortcuts** lists every shortcut in the prefix, the game itself included, with a checkbox for each, for example after you install an addon in the same prefix. Ticked ones have an entry, unticking one removes it. If you untick the game itself, the first ticked shortcut takes its place. At least one has to stay ticked (**Remove** deletes the whole game). Double-click a name to change what the start menu shows
- The start menu item **ezlaunch** (or `ezlaunch gui`) opens one window with all the prefixes, running ones marked. **Add** makes a new prefix. **Settings**, or a double-click, opens the settings of the chosen prefix, where everything else is. The list is read again when Settings closes, and **Refresh** updates it by hand
- To skip that question, right-click the exe, **Open With**, **Add installed game to ezlaunch**
- One prefix per game, in `~/.local/share/ezlaunch/games/<name>/`
- Any Proton option works: settings are plain `KEY=value` environment variables
- Right-click **Settings** opens one window with everything for the prefix, and a Save button:
  - checkboxes for common options (HDR, Wayland, NTSync, NVAPI, MangoHud, GameMode, ...)
  - the category, where the entry goes in the start menu
  - the Proton version, chosen from the versions installed in `~/.local/share/Steam/compatibilitytools.d`
  - a text box for any other variable
  - buttons for **Choose shortcuts**, **Add** (install another program in the prefix, or add one that is on the disk), **Rename**, **Stop** and **Remove**. Choose shortcuts, Add and Stop leave Settings open; Rename and Remove close it without saving
- Right-click **Rename prefix** (also in Settings, or `ezlaunch rename`): gives the prefix folder a new name. The start menu entries keep their names, which **Choose shortcuts** changes. The game has to be stopped first
- Right-click **Remove**: deletes the game, its prefix and its menu entry
- In a terminal, leave out the game name (`ezlaunch run`, `settings`, `rename`, `remove`, `stop`) to choose it from an arrow-key menu (fzf)
- `ezlaunch list` shows the games and marks the running ones, `ezlaunch running` lists only those, `ezlaunch stop` closes one (it finds a game's processes by its prefix)
- A tray icon shows the running game (its icon and name) with **Stop** and **Settings** in its menu (without a tray, `ezlaunch stop` in a terminal closes a game), and disappears when the game ends. Nothing runs in the background otherwise.

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

`programs.ezlaunch.defaults` is written to `/etc/ezlaunch/config`. Every game starts with these variables. Out of the box only `PROTONPATH = "GE-Proton-Latest"` is set. Everything else is off until you add it, for example:

```nix
programs.ezlaunch.defaults = {
  PROTONPATH = "GE-Proton-Latest"; # set by default
  PROTON_ENABLE_WAYLAND = true;    # not set by default: native Wayland instead of XWayland
  PROTON_ENABLE_HDR = true;        # not set by default: HDR, needs Wayland and an HDR screen
  MANGOHUD = true;                 # not set by default: performance overlay
};
```

Setting `defaults` replaces the built-in one, so keep the `PROTONPATH` line if you want it. Without it, umu picks its own Proton (UMU-Proton).

Settings are layered, later wins: `/etc/ezlaunch/config`, `~/.config/ezlaunch/config`, then the game's own `config`. A change in the defaults applies to every game that does not set the variable itself.

## ⚙️ All Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `programs.ezlaunch.enable` | bool | `false` | Enable ezlaunch |
| `programs.ezlaunch.package` | package | `pkgs.ezlaunch` | The ezlaunch package |
| `programs.ezlaunch.defaults` | attrs of str, int or bool | `{ PROTONPATH = "GE-Proton-Latest"; }` | Variables every game starts with. Booleans become 1 and 0 |
| `programs.ezlaunch.exeHandler` | bool | `true` | Open `.exe` files with `ezlaunch add` when double-clicked. On KDE it also turns off the "Open or Execute?" question for executable files |

## 📝 Notes

- `PROTONPATH` can be a name from `~/.local/share/Steam/compatibilitytools.d` (what ezproton installs), a full path, or a version umu downloads itself.
- The screen is kept awake while a game runs, since a controller does not count as activity for the idle timer: `kde-inhibit` on KDE, `systemd-inhibit` elsewhere (used if installed). Set `EZLAUNCH_INHIBIT=0` in the defaults or a game's custom variables to turn it off.
- Set `EZLAUNCH_TRAY=0` to turn the tray icon off. It needs `yad` (bundled, run through XWayland on Wayland) and a desktop with a system tray: KDE works, GNOME needs the AppIndicator extension.
- Special variables in a game's `config`: `EZLAUNCH_EXE` (the game's exe), `EZLAUNCH_TITLE` (the name of the start menu entry, taken from the Windows shortcut it was picked from; without it the entry has the game's name), `EZLAUNCH_CATEGORY` (the start menu category, `Game` by default; it can also be set in the defaults), `EZLAUNCH_ARGS` (arguments for the game) and `EZLAUNCH_WRAPPER` (a command prefix, such as `gamemoderun`).
- All dialogs are yad, which is bundled. Without a display the questions are asked in the terminal.
- Command line: `ezlaunch add [file.exe]` (with `--install` or `--installed` to say which kind), `install-in [file.exe]`, `add-to [file.exe]`, `add-in <game> [file.exe]`, `run <game>`, `settings <game>`, `shortcuts <game>`, `rename <game> [new name]`, `remove <game>`, `gui`, `list`, `running`, `stop <game>`.
- Start menu entries are `~/.local/share/applications/ezlaunch-<name>.desktop`. Right-click actions need a desktop that supports them (KDE, GNOME, XFCE, ...); some launchers such as rofi ignore them.
- Installers run through Proton. Nothing is extracted by hand, so registry entries and redistributables work as usual.

*Double-click, play.* 🎮
