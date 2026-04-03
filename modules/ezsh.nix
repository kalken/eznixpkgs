{ config, pkgs, lib, ... }:

let
  cfg = config.programs.ezsh;
  ezshrc = pkgs.fetchurl {
    url    = "https://raw.githubusercontent.com/kalken/ezsh/master/zshrc";
    sha256 = "sha256-4/stHooYEj+Ukhb9iUwKi39VjIPawdrzHXMae/a75y4=";
  };
in
{
  options.programs.ezsh = {
    enable = lib.mkEnableOption "ezsh - sensible zsh configuration for all users";

    defaultUserShell = lib.mkOption {
      type    = lib.types.bool;
      default = false;
      description = "Set zsh as the default shell for all users.";
    };

    extraConfig = lib.mkOption {
      type    = lib.types.lines;
      default = "";
      description = "Additional zsh config appended after ezsh is sourced.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.zsh = {
      enable = true;
      # suppress zsh-newuser-install prompt for users without a ~/.zshrc
      shellInit = "zsh-newuser-install() { :; }";
    };

    # /etc/zshrc.local is sourced by NixOS at the end of /etc/zshrc for all interactive shells
    environment.etc."zshrc.local".text = ''
      source ${ezshrc}
      ${cfg.extraConfig}
    '';

    users.defaultUserShell = lib.mkIf cfg.defaultUserShell pkgs.zsh;
  };
}
