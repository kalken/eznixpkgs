# ezsh

A simple NixOS module that applies a sensible zsh configuration system-wide for all users, sourced from [kalken/ezsh](https://github.com/kalken/ezsh).

## ✨ Features

* Sensible zsh defaults for all users without any per-user setup
* History, completion, key bindings, color output and directory stack out of the box
* Suppresses the zsh-newuser-install prompt for users without a `~/.zshrc`
* Optional system-wide default shell
* Extra config hook for your own additions

## 🚀 Quick Start
```nix
{
  programs.ezsh.enable = true;
}
```

Then set zsh as the shell for a user:
```nix
{
  users.users.alice = {
    shell = pkgs.zsh;
  };
}
```

## ⚙️ All Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `programs.ezsh.enable` | bool | `false` | Enable ezsh system-wide |
| `programs.ezsh.defaultUserShell` | bool | `false` | Set zsh as the system-wide default shell for all users who do not have an explicit `users.users.<n>.shell` set, including existing users. Does **not** override per-user shell settings. |
| `programs.ezsh.extraConfig` | lines | `""` | Additional zsh config appended after the ezsh config is sourced |

## 📝 Notes

* The ezsh config is sourced via `/etc/zshrc.local`, which NixOS sources at the end of `/etc/zshrc` for all interactive shells.
* Completions from installed packages are picked up automatically since the NixOS fpath is set up before the ezsh config is sourced.
* Users can still have their own `~/.zshrc` — it is sourced after `/etc/zshrc.local` as usual.
* Autocompletions work out of the box — any package that ships zsh completions will be picked up automatically.
* **`defaultUserShell` applies to all users without an explicit `users.users.<n>.shell` set**, including existing users. Users with an explicit shell configured will not be affected.

*Sensible zsh for everyone — just works.* 🚀
