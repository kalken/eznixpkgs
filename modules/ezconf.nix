{ config, lib, pkgs, ... }:
<<<<<<< HEAD

=======
>>>>>>> develop
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
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.ezconf.override { theme = cfg.theme; })
    ];
  };
}
