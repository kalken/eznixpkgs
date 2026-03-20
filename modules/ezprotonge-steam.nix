# ezprotonge-steam/ezprotonge-steam-service.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.ezprotonge-steam;
in
{
  options.services.ezprotonge-steam = {
    enable = lib.mkEnableOption "ezprotonge-steam — automatic Proton-GE updater for Steam";

    user = lib.mkOption {
      type        = lib.types.str;
      description = "User account to run ezprotonge-steam as (must have a Steam installation).";
      example     = "alice";
    };

    timerOnCalendar = lib.mkOption {
      type        = lib.types.nullOr lib.types.str;
      default     = null;
      description = ''
        systemd OnCalendar expression for the update timer.
        Set to null to disable the timer (useful when relying solely on afterAutoUpgrade).
        Examples: "daily", "04:00", "Mon *-*-* 03:00:00"
      '';
      example = "04:00";
    };

    afterAutoUpgrade = lib.mkOption {
      type        = lib.types.bool;
      default     = false;
      description = ''
        If true, ezprotonge-steam will run after nixos-upgrade.service completes,
        so Proton-GE is updated alongside every NixOS system upgrade.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    systemd.services.ezprotonge-steam = {
      description = "Update Proton-GE to the latest release";

      after    = [ "network-online.target" ]
                 ++ lib.optional cfg.afterAutoUpgrade "nixos-upgrade.service";
      wants    = [ "network-online.target" ];
      wantedBy = lib.optional cfg.afterAutoUpgrade "nixos-upgrade.service";

      serviceConfig = {
        Type           = "oneshot";
        User           = cfg.user;
        ExecStart      = "${pkgs.ezprotonge-steam}/bin/ezprotonge-steam";
        ReadWritePaths = [ "/home/${cfg.user}" ];
      };
    };

    systemd.timers.ezprotonge-steam = lib.mkIf (cfg.timerOnCalendar != null) {
      description = "Timer for ezprotonge-steam Proton-GE updater";
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar         = cfg.timerOnCalendar;
        Persistent         = true;
        RandomizedDelaySec = "5m";
      };
    };
  };
}
