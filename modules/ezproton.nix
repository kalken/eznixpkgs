# ezproton/ezproton-service.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.services.ezproton;
in
{
  options.services.ezproton = {
    enable = lib.mkEnableOption "ezproton — automatic Proton-GE / CachyOS Proton updater for Steam";

    user = lib.mkOption {
      type        = lib.types.str;
      description = "User account to run ezproton as (must have a Steam installation).";
      example     = "alice";
    };

    variants = lib.mkOption {
      type        = lib.types.listOf (lib.types.enum [ "ge" "cachyos" ]);
      default     = [ "ge" "cachyos" ];
      description = ''
        Which Proton variant(s) to install and keep updated.
        "ge" installs GE-Proton-Latest, "cachyos" installs Proton-CachyOS-Latest.
      '';
      example = [ "ge" ];
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
        If true, ezproton will run after nixos-upgrade.service completes,
        so Proton is updated alongside every NixOS system upgrade.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    systemd.services.ezproton = {
      description = "Update Proton-GE / CachyOS Proton to the latest release";

      after    = [ "network-online.target" ]
                 ++ lib.optional cfg.afterAutoUpgrade "nixos-upgrade.service";
      wants    = [ "network-online.target" ];
      wantedBy = lib.optional cfg.afterAutoUpgrade "nixos-upgrade.service";

      serviceConfig = {
        Type           = "oneshot";
        User           = cfg.user;
        ExecStart      = "${pkgs.ezproton}/bin/ezproton"
                          + lib.concatMapStrings (v: " --variant ${v}") cfg.variants;
        ReadWritePaths = [ "/home/${cfg.user}" ];
      };
    };

    systemd.timers.ezproton = lib.mkIf (cfg.timerOnCalendar != null) {
      description = "Timer for ezproton Proton updater";
      wantedBy    = [ "timers.target" ];
      timerConfig = {
        OnCalendar         = cfg.timerOnCalendar;
        Persistent         = true;
        RandomizedDelaySec = "5m";
      };
    };
  };
}
