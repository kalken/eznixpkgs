# ezsh

A simple module that applies a sensible zsh configuration system-wide for all users, sourced from [kalken/ezsh](https://github.com/kalken/ezsh). Works on NixOS and, through [nix-darwin](https://github.com/nix-darwin/nix-darwin), on macOS.

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

## 🍎 macOS (nix-darwin)

Import the darwin module instead of the NixOS one — it contains only the modules that work on macOS:

```nix
darwinConfigurations.mymac = nix-darwin.lib.darwinSystem {
  modules = [
    inputs.eznixpkgs.darwinModules.default
    { programs.ezsh.enable = true; }
  ];
};
```

zsh is already the default shell for accounts on macOS, so there is nothing more to set for ordinary users. `root` is the exception: its shell is `/bin/sh`. To get ezsh in a root shell, change it once:

```sh
sudo dscl . -change /Users/root UserShell /bin/sh /bin/zsh
```

`defaultUserShell` has no effect on macOS.

## ⚙️ All Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `programs.ezsh.enable` | bool | `false` | Enable ezsh system-wide |
| `programs.ezsh.defaultUserShell` | bool | `false` | NixOS only. Set zsh as the system-wide default shell for all users who do not have an explicit `users.users.<n>.shell` set, including existing users. Does **not** override per-user shell settings. |
| `programs.ezsh.extraConfig` | lines | `""` | Additional zsh config appended after the ezsh config is sourced |

## 📝 Notes

* The ezsh config is sourced via `/etc/zshrc.local`, which NixOS and nix-darwin both source at the end of `/etc/zshrc` for all interactive shells.
* Completions from installed packages are picked up automatically since the NixOS fpath is set up before the ezsh config is sourced.
* Users can still have their own `~/.zshrc` — it is sourced after `/etc/zshrc.local` as usual.
* Autocompletions work out of the box — any package that ships zsh completions will be picked up automatically.
* **`defaultUserShell` applies to all users without an explicit `users.users.<n>.shell` set**, including existing users. Users with an explicit shell configured will not be affected.

*Sensible zsh for everyone — just works.* 🚀
