# ezproton-launcher

Install and launch Windows programs and games with Proton, without Steam or a launcher app. Double-click a `setup.exe`, and the program ends up in the start menu with right-click **Run with log**, **Rename** and **Settings**. Written in Python with a Qt window.

## ✨ Features

- Double-click an exe and it tells you whether it looks like an installer (a setup or install name, or the marks of Inno Setup, NSIS, InstallShield, WiX and the like) or a program, with that choice as the default button. Choose **Install** (runs the installer in a new prefix with [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher), then you pick the program's exe) or **Add** (adds a program that is on the disk, started from where it is). The same window has the prefix (a new one is suggested, the list has the ones that exist), the Proton version and **Run with log**, which logs the installer (Install) or starts the program once with logs (Add). Either way the shortcut list opens next, to name the entries and choose their start menu categories. A program without a Windows shortcut is named after its file, with underscores as spaces and capital first letters (hollow_knight.exe is Hollow Knight)
- If the installer made more than one shortcut (the game, an editor, a launcher, ...), you tick which ones go in the start menu and can change their names. The first ticked one is the main entry. Each entry has its own start menu category (the game under Games, an editor under Development, ...), chosen in the list. They all run in the same prefix and share its settings
- The start menu item **ezproton-launcher** (or `ezproton-launcher gui`) opens one window with all the prefixes, running ones marked (updated every 5 seconds). **Add** makes a new prefix. A double-click (or Enter) opens a prefix's settings; its right-click menu has **Settings**, **Rename** (edits the name in the list, also F2), **Stop** and **Remove** (asks first)
- **Settings** has everything for a prefix: checkboxes for common options (HDR, HDR in Unreal Engine 4 games, Wayland, NVAPI, FSR 4 and DLSS upgrade, MangoHud, FPS counter, GameMode, ...), the Proton version (from `~/.local/share/Steam/compatibilitytools.d`), a text box for any other variable, and buttons for **Reset to defaults** (sets the options, Proton version and custom variables to the defaults, saved with Save), **Stop** (when something runs in the prefix), **Shortcuts**, **Remove** (the prefix), and under **Saves:** the buttons **Backup to zip**, **Restore from zip** and **Import from prefix**
- **Shortcuts** lists every shortcut in the prefix with a checkbox. Ticked ones have an entry, unticking one removes it. Unticking all of them (it asks first) leaves the prefix without entries; it stays in the ezproton-launcher window and can get them back here. Double-click a name to change what the start menu shows, or a program path to point that entry to another program; The Category column sets where each entry goes in the start menu. **Original name** gives the chosen one back the name of its Windows shortcut. **Add** installs another program in the prefix, or adds one that is on the disk, and opens the list again with the new ones ticked
- Right-click **Rename** on a start menu entry changes that entry's name only
- Right-click **Run with log** starts the program with umu's output and a Proton log, shown in a window when it ends, with **Save log**. `ezproton-launcher log` shows them again
- Double-click the prefix's name at the top of Settings (it is renamed when you press Save), or use **Rename** in the ezproton-launcher window, to give the prefix folder a new name; the start menu entries keep theirs
- **Saves: Backup to zip** writes the prefix's Windows user folder (`drive_c/users/steamuser`: Documents, Saved Games, AppData, where games keep their saves) to a zip file you choose. **Restore from zip** puts such a file back: files in it replace the ones in the prefix, others stay. Links to places outside the prefix are left out, and a running game has to be stopped before a restore
- **Saves: Import from prefix** copies the Windows user folder of a prefix made elsewhere (Heroic, Steam, Lutris, plain Wine) into this one, with the same rule: files from there replace the ones here, others stay. Choose the prefix folder (with `drive_c` in it) or the folder above it that holds `pfx`. Folders that are links to elsewhere, such as a `Documents` that Wine links to `~/Documents`, are left out and named afterwards, since those files are on the disk already
- Under **Open With** in the file manager: **Add installed program**, **Install in an existing prefix** and **Add to an existing prefix**
- Starting a program involves neither Python nor ezproton-launcher: its start menu entry runs the prefix's `launch` script, which reads the settings and hands over to umu. The script reads them each time, so changed settings apply at once. `~/.local/share/ezproton-launcher/prefixes/<name>/launch [program.exe]` works from a terminal too
- One prefix per program in `~/.local/share/ezproton-launcher/prefixes/<name>/`; settings are plain `KEY=value` environment variables, so any Proton option works

## 🚀 Quick Start

```nix
programs.ezproton-launcher.enable = true;

# Proton to use (works without Steam installed)
services.ezproton = {
  enable = true;
  user = "alice";
};
```

Then double-click a `setup.exe`.

## ⚙️ Defaults

`programs.ezproton-launcher.defaults` is written to `/etc/ezproton-launcher/config`. A new prefix starts with these variables, copied into its own `config`. Out of the box only `PROTONPATH = "GE-Proton-Latest"` is set:

```nix
programs.ezproton-launcher.defaults = {
  PROTONPATH = "GE-Proton-Latest"; # set by default
  PROTON_ENABLE_WAYLAND = true;    # not set by default: native Wayland instead of XWayland
  MANGOHUD = true;                 # not set by default: performance overlay
};
```

Setting `defaults` replaces the built-in one, so keep the `PROTONPATH` line if you want it. Defaults come from `/etc/ezproton-launcher/config`, then `~/.config/ezproton-launcher/config` (later wins). A prefix has all its settings in its own `config`, so changing the defaults leaves existing prefixes as they are; **Reset to defaults** in Settings applies them to one. Prefixes from older versions get the defaults written into their `config` once, so they run as before.

## ⚙️ All Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `programs.ezproton-launcher.enable` | bool | `false` | Enable ezproton-launcher |
| `programs.ezproton-launcher.package` | package | `pkgs.ezproton-launcher` | The ezproton-launcher package |
| `programs.ezproton-launcher.defaults` | attrs of str, int or bool | `{ PROTONPATH = "GE-Proton-Latest"; }` | Variables a new prefix starts with. Booleans become 1 and 0 |
| `programs.ezproton-launcher.exeHandler` | bool | `true` | Open `.exe` files with `ezproton-launcher add` when double-clicked. On KDE it also turns off the "Open or Execute?" question for executable files |

## 📝 Notes

- Special variables in a prefix's `config`: `LAUNCHER_EXE` (the main program), `LAUNCHER_TITLE` (the name of its start menu entry; without it the entry has the prefix's name), `LAUNCHER_CATEGORY` (the main entry's start menu category; the other entries have theirs in `links`, `Game` by default), `LAUNCHER_ARGS` (arguments for the main program, shell-quoted), `LAUNCHER_WRAPPER` (a command prefix, such as `gamemoderun`) and `LAUNCHER_INHIBIT=0` (let the screen sleep while playing; by default it is kept awake with `kde-inhibit` on KDE, `systemd-inhibit` elsewhere).
- Qt is only loaded when a window opens. The module installs umu-launcher, which the launch scripts need on the PATH.
- The only library is PySide6 (Qt). Without a display the questions are asked in the terminal.
- Command line: `ezproton-launcher add [file.exe]` (with `--install` or `--installed`), `install-in [file.exe]`, `add-to [file.exe]`, `add-in <prefix> [file.exe]`, `run <prefix> [--log]`, `settings <prefix>`, `shortcuts <prefix>`, `rename <prefix> [new name]`, `rename-shortcut <prefix> [exe]`, `remove <prefix>`, `gui`, `list`, `running`, `stop <prefix>`, `log <prefix>`, `backup <prefix> [file.zip]`, `restore <prefix> [file.zip]`, `import-saves <prefix> [folder]`.
- Start menu entries are `~/.local/share/applications/ezproton-launcher-prefix-<name>.desktop`.

*Double-click, play.* 🎮
