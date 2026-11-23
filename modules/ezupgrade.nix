{
  config,
  options,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.ezupgrade;

  # Also used as a nix-darwin module (darwinModules in flake.nix). NixOS has its own upgrade
  # service, which this configures; macOS has none, so this makes a launchd daemon.
  isNixOS = options ? systemd;

  # The name eznotify knows the upgrade job by.
  unitName = if isNixOS then "nixos-upgrade" else "ezupgrade";

  # What `schedule` says, as a systemd calendar expression. NixOS takes it as it is;
  # launchd has no such language, so macOS reads the common forms of it (launchdEntries).
  calendar = cfg.schedule;
  named = {
    hourly = "*-*-* *:00:00";
    daily = "*-*-* 00:00:00";
    weekly = "Mon *-*-* 00:00:00";
    monthly = "*-*-01 00:00:00";
  };
  spec = named.${calendar} or calendar;

  # `[WEEKDAYS] [*-MONTH-DAY] HH:MM[:SS]`: weekdays as `Mon`, `Sat,Sun` or `Mon..Fri`, any of
  # hour, month and day as `*`. Null where it is something else (a list of times, `*/2`, `~`).
  parts = builtins.match "(([A-Za-z][A-Za-z,.-]*) )?(\\*-(\\*|[0-9]{1,2})-(\\*|[0-9]{1,2}) )?([0-9]{1,2}|\\*):([0-9]{2})(:[0-9]{2})?" spec;
  dayNumbers = {
    sun = 0;
    mon = 1;
    tue = 2;
    wed = 3;
    thu = 4;
    fri = 5;
    sat = 6;
  };
  dayNumber = d: dayNumbers.${toLower (substring 0 3 d)} or null;
  weekdaysOf =
    text:
    let
      one =
        item:
        let
          ends = builtins.match "([A-Za-z]+)(\\.\\.|-)([A-Za-z]+)" item;
          from = dayNumber (head ends);
          to = dayNumber (elemAt ends 2);
        in
        if ends == null then
          [ (dayNumber item) ]
        else if from == null || to == null then
          [ null ]
        else
          genList (i: mod (from + i) 7) (mod (to - from + 7) 7 + 1);
    in
    unique (concatMap one (splitString "," text));
  number = text: toInt (head (builtins.match "0*([0-9]+)" text));
  launchdEntries =
    if !launchdOk then
      [ ]
    else
      let
        days = if elemAt parts 1 == null then [ null ] else weekdaysOf (elemAt parts 1);
        when = {
          Minute = number (elemAt parts 6);
        }
        // optionalAttrs (elemAt parts 5 != "*") { Hour = number (elemAt parts 5); }
        // optionalAttrs (elemAt parts 3 != null && elemAt parts 3 != "*") {
          Month = number (elemAt parts 3);
        }
        // optionalAttrs (elemAt parts 4 != null && elemAt parts 4 != "*") {
          Day = number (elemAt parts 4);
        };
      in
      map (d: when // optionalAttrs (d != null) { Weekday = d; }) days;
  launchdOk =
    parts != null
    && (elemAt parts 1 == null || all (d: d != null) (weekdaysOf (elemAt parts 1)))
    && (elemAt parts 5 == "*" || number (elemAt parts 5) < 24)
    && number (elemAt parts 6) < 60;

  # "45m", "1h", "30s" or a plain number of seconds
  delayParts = builtins.match "([0-9]+)([smh]?)" cfg.randomizedDelay;
  delaySeconds =
    toInt (head delayParts)
    * {
      "" = 1;
      s = 1;
      m = 60;
      h = 3600;
    }
    .${elemAt delayParts 1};

  target = "path:${cfg.flake}#${cfg.configuration}";

  # Wait until the network answers three times in a row, so a link that is only coming up (Wi-Fi,
  # VPN, DHCP) does not make the update fail. Gives up when it has not been stable in time.
  waitForNetwork = curl: ''
    ok=0
    deadline=$((SECONDS + ${toString cfg.networkTimeout}))
    while [ "$ok" -lt 3 ]; do
      if ${curl} -fsI -o /dev/null --max-time 5 ${escapeShellArg cfg.networkCheckUrl}; then
        ok=$((ok + 1))
        if [ "$ok" -lt 3 ]; then sleep 2; fi
      else
        ok=0
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "ezupgrade: network not stable after ${toString cfg.networkTimeout}s, giving up" >&2
          exit 1
        fi
        sleep 5
      fi
    done
  '';
in
{
  options.services.ezupgrade = {
    enable = mkEnableOption "ezupgrade, a nightly update of the flake's inputs and a rebuild of the system";

    flake = mkOption {
      type = types.str;
      default = if isNixOS then "/etc/nixos" else "/Users/${cfg.user}/.config/nix-darwin";
      defaultText = literalMD "`/etc/nixos` on NixOS, `/Users/<user>/.config/nix-darwin` on macOS";
      example = "/home/alice/nixos";
      description = "The folder of the flake that holds the system's configuration.";
    };

    configuration = mkOption {
      type = types.str;
      default = "default";
      description = "The name of the configuration in the flake that is built.";
    };

    user = mkOption {
      type = types.nullOr types.str;
      default = if isNixOS then "root" else config.system.primaryUser;
      defaultText = literalMD "`root` on NixOS, `system.primaryUser` on macOS";
      example = "alice";
      description = "The user who owns the flake folder. The inputs are updated as this user, so the lock file stays theirs, and the rebuild runs as root.";
    };

    schedule = mkOption {
      type = types.str;
      example = "Sun *-*-* 03:30";
      description = "When the upgrade runs, as a systemd calendar expression: `daily`, `weekly`, `monthly`, `hourly`, `Sat 04:00`, `Mon..Fri 02:30`, `*-*-01 05:00`, `*-*-* 00,12:00`. NixOS takes any expression systemd does; macOS (launchd) takes the names above and `[WEEKDAYS] [*-MONTH-DAY] HH:MM`, with `*` or a number for month and day.";
    };

    randomizedDelay = mkOption {
      type = types.strMatching "[0-9]+[smh]?";
      default = "0";
      example = "45m";
      description = "Wait a random time, up to this long, after the scheduled time before the upgrade starts: `30s`, `45m`, `1h`, or a number of seconds. 0 starts it on time.";
    };

    update = mkOption {
      type = types.bool;
      default = true;
      description = "Update the flake's inputs before the rebuild. Off, it only rebuilds what the lock file says.";
    };

    homebrew = mkOption {
      type = types.bool;
      default = false;
      description = "macOS only: also update Homebrew and upgrade its packages, before the rebuild. Set `homebrew.onActivation.autoUpdate` and `upgrade` to false in nix-darwin to have it done only here and not on every activation.";
    };

    waitForNetwork = mkOption {
      type = types.bool;
      default = true;
      description = "Wait for the network to be stable before the upgrade: `networkCheckUrl` has to answer three times in a row. If it has not within `networkTimeout`, the upgrade fails (and eznotify tells about it) instead of half-running.";
    };

    networkCheckUrl = mkOption {
      type = types.str;
      default = "https://cache.nixos.org";
      description = "The address that has to answer for the network to count as up.";
    };

    networkTimeout = mkOption {
      type = types.ints.positive;
      default = 180;
      description = "How many seconds to wait for a stable network before giving up.";
    };

    notify = mkOption {
      type = types.bool;
      default = true;
      description = "Tell about the upgrade through eznotify (when `services.eznotify` is enabled): a message when it fails, and, with `notifyOnSuccess`, when it worked.";
    };

    notifyOnSuccess = mkOption {
      type = types.bool;
      default = true;
      description = "Also send a message when the upgrade worked, not only when it failed.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.user != null;
          message = "services.ezupgrade.user is not set, and neither is system.primaryUser to take it from.";
        }
        {
          assertion = isNixOS || launchdOk;
          message = "services.ezupgrade.schedule \"${calendar}\" is not one launchd can do: use daily, weekly, monthly, hourly, or [WEEKDAYS] [*-MONTH-DAY] HH:MM.";
        }
      ];
    }
    {
      services.eznotify.units.${unitName} = mkIf cfg.notify {
        onSuccess.enable = mkDefault cfg.notifyOnSuccess;
        onSuccess.logLines = mkDefault 5;
        onFailure.logLines = mkDefault 60;
      };
    }

    (
      if isNixOS then
        {
          system.autoUpgrade = {
            enable = true;
            flake = target;
            dates = calendar;
            randomizedDelaySec = "${toString delaySeconds}s";
          };

          # With a flake, nixos-upgrade does not touch the lock file, so it is updated first.
          systemd.services.nixos-upgrade = {
            path = [
              pkgs.util-linux
              config.nix.package
            ];
            preStart = mkMerge [
              (mkIf cfg.waitForNetwork (mkBefore (waitForNetwork "${pkgs.curl}/bin/curl")))
              (mkIf cfg.update "runuser -u ${escapeShellArg cfg.user} -- nix flake update --flake ${escapeShellArg cfg.flake}")
            ];
          };
        }
      else
        {
          launchd.daemons.ezupgrade = {
            script =
              let
                brew = "${config.homebrew.prefix}/bin/brew";
              in
              ''
                ${optionalString (delaySeconds > 0) "/bin/sleep $(/usr/bin/jot -r 1 0 ${toString delaySeconds})"}
                ${optionalString cfg.waitForNetwork (waitForNetwork "/usr/bin/curl")}
                # A step that fails is not the end of the others, but the job as a whole has failed
                rc=0
                ${optionalString cfg.homebrew "sudo -u ${escapeShellArg cfg.user} ${brew} update && sudo -u ${escapeShellArg cfg.user} ${brew} upgrade || rc=1"}
                { ${optionalString cfg.update "sudo -u ${escapeShellArg cfg.user} /nix/var/nix/profiles/default/bin/nix flake update --flake ${escapeShellArg cfg.flake} &&"}
                  /run/current-system/sw/bin/darwin-rebuild switch --flake ${escapeShellArg target}; } || rc=1
                exit $rc
              '';
            serviceConfig = {
              StartCalendarInterval = launchdEntries;
              EnvironmentVariables.PATH = "/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
              StandardOutPath = "/var/log/ezupgrade.log";
              StandardErrorPath = "/var/log/ezupgrade.log";
            };
          };
        }
    )
  ]);
}
