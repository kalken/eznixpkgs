{ config, lib, pkgs, ... }:
let
  cfg = config.programs.ezconf;
in {
  options.programs.ezconf = {
    enable = lib.mkEnableOption "ezconf - custom Neovim";
    theme = lib.mkOption {
      default = {
        plugin      = pkgs.vimPlugins.onedarkpro-nvim;
        colorscheme = "onedark_dark";
        setup       = "";
      };
      description = "Theme to use. Pass plugin, colorscheme, and optional setup lua.";
      type = lib.types.submodule {
        options = {
          plugin = lib.mkOption {
            type        = lib.types.package;
            description = "Any vimPlugin package, e.g. pkgs.vimPlugins.kanagawa-nvim";
          };
          colorscheme = lib.mkOption {
            type        = lib.types.str;
            description = "The colorscheme name passed to vim.cmd.colorscheme()";
          };
          setup = lib.mkOption {
            type        = lib.types.str;
            default     = "";
            description = "Optional Lua setup call, e.g. require('kanagawa').setup()";
          };
        };
      };
    };
    nerdFonts = lib.mkOption {
      type        = lib.types.bool;
      default     = false;
      description = "Enable Nerd Fonts icons in the completion popup.";
    };
    extraConfig = lib.mkOption {
      type        = lib.types.lines;
      default     = "";
      example     = ''
        vim.opt.guicursor = "a:ver25"
      '';
      description = ''
        Arbitrary Lua injected after the user config, so it overrides defaults set in config.lua.
        Use this for vim.opt settings, keymaps, autocmds, or any other Lua you want to append.
      '';
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.ezconf.override {
        theme     = cfg.theme;
        nerdFonts = cfg.nerdFonts;
        extraConfig = cfg.extraConfig;
      })
    ];
  };
}
