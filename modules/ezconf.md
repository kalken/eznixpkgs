# ezconf

A custom Neovim distribution for NixOS, preconfigured for Nix development with LSP, autocompletion, and optional theming. Launched with the `ezconf` command.

## ✨ Features

* Preconfigured LSP via `nixd` with host-aware flake integration
* Autocompletion with `nvim-cmp`, `luasnip`, and snippet sources
* Auto-formatting on save via `alejandra`
* Heading sidebar and button panel for `.nix` files
* Mouse disabled by default — keyboard-first experience
* Nix-injected theming — any `vimPlugins` package works
* Ignores `~/.config/nvim` — fully self-contained

## 🚀 Quick Start

```nix
{
  programs.ezconf.enable = true;
}
```

Then launch with:

```bash
ezconf
```

## 🎨 Setting a Theme

Pass any plugin from `pkgs.vimPlugins` directly:

```nix
{
  programs.ezconf = {
    enable = true;
    theme = {
      plugin      = pkgs.vimPlugins.vim-moonfly-colors;
      colorscheme = "moonfly";
    };
  };
}
```

For themes that require a setup call:

```nix
{
  programs.ezconf = {
    enable = true;
    theme = {
      plugin      = pkgs.vimPlugins.catppuccin-nvim;
      colorscheme = "catppuccin";
      setup       = ''require("catppuccin").setup({ flavour = "mocha" })'';
    };
  };
}
```

You can also use a plugin from a custom source:

```nix
{
  programs.ezconf = {
    enable = true;
    theme = {
      plugin = pkgs.vimUtils.buildVimPlugin {
        name = "my-theme";
        src  = pkgs.fetchFromGitHub {
          owner  = "someone";
          repo   = "cool-theme.nvim";
          rev    = "abc123";
          sha256 = "...";
        };
      };
      colorscheme = "cool-theme";
    };
  };
}
```

## ⚙️ All Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `programs.ezconf.enable` | bool | `false` | Enable ezconf and install the `ezconf` command |
| `programs.ezconf.theme` | attrs or null | `null` | Theme to apply. If null, Neovim's built-in default is used |
| `programs.ezconf.theme.plugin` | package | — | Any `vimPlugins` package |
| `programs.ezconf.theme.colorscheme` | str | — | The colorscheme name passed to `vim.cmd.colorscheme()` |
| `programs.ezconf.theme.setup` | str | `""` | Optional Lua setup call, e.g. `require("catppuccin").setup()` |

## 📦 Bundled Packages

The following are installed automatically and do not need to be added separately:

| Package | Purpose |
| --- | --- |
| `nixd` | Nix language server |
| `alejandra` | Nix formatter (runs on save) |
| `nvim-cmp` | Autocompletion engine |
| `luasnip` | Snippet engine |
| `cmp-nvim-lsp` | LSP completion source |
| `cmp-buffer` | Buffer completion source |
| `cmp-path` | Path completion source |
| `cmp_luasnip` | Snippet completion source |

## 🛠️ Custom Syntax for `.nix` Files

ezconf adds two special comment conventions for `.nix` files that power the sidebar and button panel.

### Headings

Use `##! Heading` (any number of `#`) to define navigable headings in your file:

```nix
##! Top Level Section

###! Sub Section

####! Nested Section
```

The number of `#` controls the indent level in the sidebar. Press `<Tab>` to open the sidebar, navigate with arrow keys, and press `<Enter>` to jump to that heading.

### Buttons

Use `#!button Name: command` to define runnable shell commands:

```nix
#!button Build: nixos-rebuild build --flake /etc/nixos
#!button Switch: sudo nixos-rebuild switch --flake /etc/nixos
#!button Check: nix flake check /etc/nixos
```

Press `<Tab>` to open the button panel at the bottom of the screen, navigate with `<Left>` / `<Right>`, and press `<Enter>` to run the command. Output streams live into a split window. Press `<Enter>` again when done to close it.

## ⌨️ Added Keybindings

These are added by ezconf on top of stock Neovim.

| Key | Mode | Action |
| --- | --- | --- |
| `<Tab>` | Normal | Cycle between main buffer, heading sidebar, and button panel |
| `<Enter>` | Normal (sidebar) | Jump to heading and close sidebar |
| `<Enter>` | Normal (button panel) | Run selected button command |
| `<Left>` / `<Right>` | Normal (button panel) | Select previous / next button |
| `<Esc>` | Normal (sidebar / button panel) | Return focus to main buffer |
| `<Enter>` | Normal (output window) | Close output window after command finishes |
| `K` | Normal | Show LSP hover documentation |

## 📝 Notes

* The `ezconf` command is a wrapper around `nvim` — all standard Neovim flags and arguments work.
* LSP is configured to read your system flake from `/etc/nixos` using the current hostname automatically.
* `~/.config/nvim` and other user config files are ignored entirely — ezconf is fully self-contained.
* The mouse is disabled so that terminal text selection works normally.
* The heading sidebar (`HeadingSidebarToggle`) parses `##! Heading` style comments in `.nix` files.
* The button panel (`ButtonPanelToggle`) parses `#!button Name: command` directives and runs them in a split.
* Press `<Tab>` in normal mode to cycle between the main buffer, sidebar, and button panel.

*Opinionated Neovim for NixOS — just works.* 🚀
