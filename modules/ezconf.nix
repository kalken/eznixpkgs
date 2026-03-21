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
    vimOpts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [ lib.types.bool lib.types.int lib.types.float lib.types.str ]);
      default = {
        mouse = "";
      };
      description = ''
        vim.opt settings injected after the user config, so they override defaults set in config.lua.
        Keys are option names, values are booleans, integers, floats, or strings.

        Defaults already set in config.lua (can be overridden here):
          guicursor  = ""      # disables cursor shape changes
          showcmd    = false   # hides command display
          ruler      = false   # hides cursor position
          updatetime = 200     # ms before CursorHold fires (affects autocomplete delay)
      '';
      example = lib.literalExpression ''
        {
          mouse      = "n";  # click to position cursor, "a" for all modes, "" to disable
          number     = true; # show line numbers
          tabstop    = 4;    # tab width
        }
      '';
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.ezconf.override {
        theme = cfg.theme;
        vimOpts = lib.concatStringsSep "\n" (
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
