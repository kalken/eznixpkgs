{ config, options, pkgs, lib, ... }:
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
      description = ''
        Set zsh as the system-wide default shell. Applies to all users who do
        not have an explicit shell set via users.users.<n>.shell, including
        existing users. Users with an explicit shell configured will not be
        affected. NixOS only: has no effect on macOS, where each account's
        shell is set in the system itself.
      '';
    };
    extraConfig = lib.mkOption {
      type    = lib.types.lines;
      default = "";
      description = "Additional zsh config appended after ezsh is sourced.";
    };
  };
  # Also used as a nix-darwin module (darwinModules in flake.nix), which has everything below
  # except users.defaultUserShell: macOS owns each account's shell, so that option only exists,
  # and is only set, on NixOS.
  config = lib.mkIf cfg.enable ({
    programs.zsh = {
      enable = true;
      # suppress zsh-newuser-install prompt for users without a ~/.zshrc
      shellInit = "zsh-newuser-install() { :; }";
    };
    # /etc/zshrc.local is sourced by NixOS (and nix-darwin) at the end of /etc/zshrc for all
    # interactive shells
    environment.etc."zshrc.local".text = ''
      source ${ezshrc}
      ${cfg.extraConfig}
    '';
  } // lib.optionalAttrs (options.users ? defaultUserShell) {
    users.defaultUserShell = lib.mkIf cfg.defaultUserShell pkgs.zsh;
  });
}
