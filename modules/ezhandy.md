# ezhandy

Sets up [Handy](https://handy.computer), the offline speech-to-text app, so it works out of the box on Plasma Wayland: hold a key, talk, let go, and the text appears in the focused app. Handy's own settings (talk key, paste method, model, custom words, …) come from the NixOS config, so nothing has to be clicked together in the app.

## ✨ Features

- Installs Handy for one user, with the `ydotool` service and group it needs to type into other apps on Wayland (wtype doesn't work on KWin: it lacks the virtual-keyboard protocol)
- Any talk key, including a modifier on its own like Right Ctrl: switches Handy to its HandyKeys backend and adds the `input` group when the key needs it
- Merges the configured settings into Handy's `settings_store.json` every time Handy starts; settings not listed stay editable in the app
- Adds Ctrl+Shift+V to KDE's Paste shortcut, so one paste method works in terminals, browsers and KDE apps
- Starts Handy hidden in the tray at login, replacing Handy's own login entry (which runs the unwrapped binary from a fixed store path)
- Fails the build on key names Handy can't parse, instead of Handy quietly falling back to its default shortcut

## 🚀 Quick Start

```nix
programs.ezhandy = {
  enable      = true;
  user        = "alice";
  talkKey     = "ctrl_right";
  pasteMethod = "ctrl_shift_v";
};
```

Log out and back in (or reboot) once, so the new groups apply. Handy then starts in the tray at every login. The first time, pick and download a speech model in Handy's window, or set `selected_model` (below) and let Handy download it.

## ⌨️ Choosing the Talk Key

`talkKey` uses Handy's key names: `ctrl+space`, `f12`, `end`, `pause`, `numpad0`, `ctrl_right`, `shift_right`, …

| Key | Backend | Notes |
| --- | --- | --- |
| A combination or a normal key (`ctrl+space`, `f12`, `pause`) | `tauri` | No extra groups. Apps still receive the key: `end` moves the cursor, `insert` toggles overwrite in Kate. |
| A modifier on its own, or a side-specific one (`ctrl_right`, `shift_right`) | `handy_keys` | Adds the `input` group. Handy takes the key out before any app sees it; that key stops working as Ctrl/Shift. |

Set `keyboardImplementation = "handy_keys"` to swallow a normal key too (e.g. `end`). HandyKeys grabs the keyboards and passes every other key through; Handy calls it experimental.

Don't use AltGr (`altgr`, `alt_right`) on layouts that need it for characters, such as Swedish or German (`@`, `{`, `\`).

## 📋 Paste Method

Handy copies the text and presses a paste key in the focused app (through ydotool, which works on any desktop, Wayland or X11). Whether the app pastes on that key depends on the app, not the desktop:

| Value | Terminals | Browsers, Electron apps | KDE/Qt apps | GTK/GNOME apps |
| --- | --- | --- | --- | --- |
| `ctrl_shift_v` | yes | yes (as plain text) | yes, with `kdePasteShortcut` | mostly no |
| `ctrl_v` | no | yes | yes | yes |
| `direct` | yes | yes | yes | yes |

- On Plasma, or anywhere you mostly use terminals, browsers and KDE apps: `ctrl_shift_v`. `kdePasteShortcut` is on by default with it; KDE apps read `/etc/xdg/kdeglobals` on any desktop.
- On GNOME and other GTK desktops: `ctrl_v`, if you rarely dictate into a terminal.
- `direct` types the text key by key, so it works everywhere, but it's slow, and ydotool assumes a US layout, so other layouts get wrong symbols.

## 🎙️ Quiet Microphone

Handy transcribes the raw microphone signal; it has no automatic gain like Discord or browser calls. If the mic is quiet or uneven (some onboard audio, such as ASUS's USB Realtek ALC4080, has no mic boost on Linux), turn on `autoGain`:

```nix
programs.ezhandy.autoGain = true;
```

Needs PipeWire with its ALSA support (`services.pipewire.enable`, `services.pipewire.alsa.enable`, the usual NixOS desktop setup); the rest of the module works without PipeWire. This adds a PipeWire source, "Microphone for Handy (auto gain)", running the default microphone through WebRTC voice processing (automatic gain control, noise suppression, high-pass filter), and has Handy record from it. Other programs keep the plain microphone, and it never becomes the default. Restart PipeWire (or log in again) after the first rebuild: `systemctl --user restart pipewire pipewire-pulse wireplumber`.

WebRTC's gain control only adds so much (roughly 10–15 dB) and starts over at each recording. If Handy's recordings are still quiet, add a fixed boost after it, which applies to Handy's microphone only:

```nix
programs.ezhandy = {
  autoGain       = true;
  autoGainVolume = 3.0;   # 300 %, ≈ +28 dB
};
```

To check the level, measure a recording: `sox ~/.local/share/com.pais.handy/recordings/<file>.wav -n stat`. Speech peaking around 0.3 (RMS 0.03–0.1) is right; peaks near 1.0 clip.

To have Handy record from some other source, set `microphone` to its `node.name` (`wpctl status`, then `wpctl inspect <id>`).

## 🛠 More Settings

Anything in Handy's `settings_store.json` can go in `settings`, by the same names:

```nix
programs.ezhandy = {
  enable  = true;
  user    = "alice";
  talkKey = "ctrl_right";
  settings = {
    selected_model        = "handy-computer/parakeet-unified-en-0.6b-gguf/parakeet-unified-en-0.6b-Q8_0.gguf";
    custom_words          = [ "eznix" "NixOS" ];
    append_trailing_space = true;
  };
};
```

Settings listed here go back to these values each time Handy starts; change them in the config, not in the app. The options (`talkKey`, `pasteMethod`, …) win over the same keys in `settings`.

## ⚙️ Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Enable ezhandy |
| `user` | str | — | User account Handy is for (gets the package and the groups) |
| `package` | package | `pkgs.handy` | The Handy package |
| `talkKey` | null or str | `null` | Transcribe shortcut; `null` leaves it to the app |
| `keyboardImplementation` | `"auto"`, `"tauri"`, `"handy_keys"` | `"auto"` | Shortcut backend; `auto` picks `handy_keys` when `talkKey` needs it |
| `pasteMethod` | null or one of `ctrl_v`, `ctrl_shift_v`, `shift_insert`, `direct`, `none`, `external_script` | `null` | How text goes into the app; `null` leaves it to the app |
| `kdePasteShortcut` | bool | `pasteMethod == "ctrl_shift_v"` | Add Ctrl+Shift+V to KDE's Paste shortcut (`/etc/xdg/kdeglobals`) |
| `autoGain` | bool | `false` | Record from a WebRTC-processed copy of the default mic (auto gain, noise suppression) |
| `autoGainVolume` | number | `1.0` | Volume of the auto-gain mic after processing (3.0 = 300 %), set at every WirePlumber start |
| `microphone` | null or str | `"ezhandy-autogain"` with `autoGain`, else `null` | PipeWire source Handy records from; `null` is the default mic. Handy's feedback sounds don't play when set |
| `autostart` | bool | `true` | Start Handy hidden at login (`/etc/xdg/autostart/Handy.desktop`) |
| `settings` | JSON attrs | `{}` | Any other Handy settings, merged in at every start |

## 📝 Notes

- The settings are merged by the `handy` launcher before Handy starts, and only when Handy isn't already running (it keeps them in memory and would write over the change). After changing them, quit Handy from the tray and start it again.
- Leave "Launch at login" off in Handy itself; the module sets `autostart_enabled = false` for that reason.
- New groups (`ydotool`, `input`) reach programs started after the next login. To try them without one: `systemd-run --user /run/wrappers/bin/sg input -c "handy --start-hidden"`.
- Handy's `settings_store.json` lives in `~/.local/share/com.pais.handy/`, with its log in `logs/handy.log` there.
