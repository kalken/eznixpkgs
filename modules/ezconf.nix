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
    vimOpts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [ lib.types.bool lib.types.int lib.types.float lib.types.str ]);
      default = { mouse = ""; };
      description = ''
        vim.opt settings injected after the user config, so they override defaults set in config.lua.
      '';
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.ezconf.override {
        theme     = cfg.theme;
        nerdFonts = cfg.nerdFonts;
        vimOpts   = lib.concatStringsSep "\n" (
          lib.mapAttrsToList
            (name: value:
              "vim.opt.${name} = ${
                if builtins.isBool value then (if value then "true" else "false")
                else if builtins.isString value then ''"${value}"''
                else toString value
              }")
            cfg.vimOpts
        );
      })
    ];
  };
}
