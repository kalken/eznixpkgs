{ config, options, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.ezupgrade;

  # Also used as a nix-darwin module (darwinModules in flake.nix). NixOS has its own upgrade
  # service, which this configures; macOS has none, so this makes a launchd daemon.
  isNixOS = options ? systemd;

  # The name eznotify knows the upgrade job by.
  unitName = if isNixOS then "nixos-upgrade" else "ezupgrade";

  hour = toInt (head (builtins.match "0?([0-9]+):.*" cfg.time));
  minute = toInt (head (builtins.match "[0-9]+:0?([0-9]+)" cfg.time));

  # "45m", "1h", "30s" or a plain number of seconds
  delayParts = builtins.match "([0-9]+)([smh]?)" cfg.randomizedDelay;
  delaySeconds = toInt (head delayParts) * { "" = 1; s = 1; m = 60; h = 3600; }.${elemAt delayParts 1};

  target = "path:${cfg.flake}#${cfg.configuration}";
in {
  options.services.ezupgrade = {
    enable = mkEnableOption "ezupgrade, a nightly update of the flake's inputs and a rebuild of the system";

    flake = mkOption {
      type = types.str;
      example = "/home/alice/.config/nix-darwin";
      description = "The folder of the flake that holds the system's configuration.";
    };

    configuration = mkOption {
      type = types.str;
      default = "default";
      description = "The name of the configuration in the flake that is built.";
    };

    user = mkOption {
      type = types.str;
      example = "alice";
      description = ''
        The user who owns the flake folder. The inputs are updated as this user, so the lock
        file stays theirs, and the rebuild runs as root.
      '';
    };

    time = mkOption {
      type = types.strMatching "[0-9]{1,2}:[0-9]{2}";
      default = "04:00";
      description = "When the upgrade runs each day, as `HH:MM`.";
    };

    randomizedDelay = mkOption {
      type = types.strMatching "[0-9]+[smh]?";
      default = "0";
      example = "45m";
      description = "Wait a random time, up to this long, after `time` before the upgrade starts: `30s`, `45m`, `1h`, or a number of seconds. 0 starts it on time.";
    };

    update = mkOption {
      type = types.bool;
      default = true;
      description = "Update the flake's inputs before the rebuild. Off, it only rebuilds what the lock file says.";
    };

    notify = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Tell about the upgrade through eznotify (when `services.eznotify` is enabled): a message
        when it fails, and, with `notifyOnSuccess`, when it worked.
      '';
    };

    notifyOnSuccess = mkOption {
      type = types.bool;
      default = true;
      description = "Also send a message when the upgrade worked, not only when it failed.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.eznotify.units.${unitName} = mkIf cfg.notify {
        onSuccess.enable = mkDefault cfg.notifyOnSuccess;
        onSuccess.logLines = mkDefault 5;
        onFailure.logLines = mkDefault 60;
      };
    }

    (if isNixOS then {
      system.autoUpgrade = {
        enable = true;
        flake = target;
        dates = "*-*-* ${cfg.time}:00";
        randomizedDelaySec = "${toString delaySeconds}s";
      };

      # With a flake, nixos-upgrade does not touch the lock file, so it is updated first.
      systemd.services.nixos-upgrade = mkIf cfg.update {
        path = [ pkgs.util-linux config.nix.package ];
        preStart = "runuser -u ${escapeShellArg cfg.user} -- nix flake update --flake ${escapeShellArg cfg.flake}";
      };
    } else {
      launchd.daemons.ezupgrade = {
        script = ''
          ${optionalString (delaySeconds > 0) "/bin/sleep $(/usr/bin/jot -r 1 0 ${toString delaySeconds})"}
          ${optionalString cfg.update "sudo -u ${escapeShellArg cfg.user} /nix/var/nix/profiles/default/bin/nix flake update --flake ${escapeShellArg cfg.flake} &&"}
          /run/current-system/sw/bin/darwin-rebuild switch --flake ${escapeShellArg target}
        '';
        serviceConfig = {
          StartCalendarInterval = [ { Hour = hour; Minute = minute; } ];
          EnvironmentVariables.PATH = "/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
          StandardOutPath = "/var/log/ezupgrade.log";
          StandardErrorPath = "/var/log/ezupgrade.log";
        };
      };
    })
  ]);
}
