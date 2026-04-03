# ezsh

A simple NixOS module that applies a sensible zsh configuration system-wide for all users, sourced from [kalken/ezsh](https://github.com/kalken/ezsh).

## ✨ Features

* Sensible zsh defaults for all users without any per-user setup
* History, completion, key bindings, color output and directory stack out of the box
* Suppresses the zsh-newuser-install prompt for users without a `~/.zshrc`
* Optional system-wide default shell
* Extra config hook for your own additions

## 🚀 Quick Start

​```nix
{
  programs.ezsh.enable = true;
}
​```

Then set zsh as the shell for a user:

​```nix
{
  users.users.alice = {
    shell = pkgs.zsh;
  };
}
​```

## ⚙️ All Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `programs.ezsh.enable` | bool | `false` | Enable ezsh system-wide |
| `programs.ezsh.defaultUserShell` | bool | `false` | Set zsh as the default shell for all users |
| `programs.ezsh.extraConfig` | lines | `""` | Additional zsh config appended after the ezsh config is sourced |

## 📝 Notes

* The ezsh config is sourced via `/etc/zshrc.local`, which NixOS sources at the end of `/etc/zshrc` for all interactive shells.
* Completions from installed packages are picked up automatically since the NixOS fpath is set up before the ezsh config is sourced.
* Users can still have their own `~/.zshrc` — it is sourced after `/etc/zshrc.local` as usual.
* Extra zsh completions such as `nix-zsh-completions` can be installed per-user via `users.users.<n>.packages` and will be picked up automatically.

*Sensible zsh for everyone — just works.* 🚀
