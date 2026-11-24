{
  config,
  options,
  lib,
  pkgs,
  ...
}:

with lib;

let
  # Also used as a nix-darwin module (darwinModules in flake.nix). There the services are
  # launchd daemons: each listed one is wrapped in a script that runs it and tells how it ended.
  isNixOS = options ? systemd;

  cfg = config.services.eznotify;
  mail = cfg.mail;
  desktop = cfg.desktop;

  # The mail account for msmtp. It holds no secret: the password is read from a file when a
  # mail is sent, so the file in the store can be read by anyone.
  msmtpConfig = pkgs.writeText "eznotify-msmtprc" ''
    defaults
    tls on
    tls_starttls ${if mail.smtp.tls == "starttls" then "on" else "off"}
    auth ${if mail.smtp.user != null then "on" else "off"}

    account default
    host ${mail.smtp.host}
    port ${toString mail.smtp.port}
    from ${mail.from}
    ${optionalString (mail.smtp.user != null) "user ${mail.smtp.user}"}
    ${optionalString (
      mail.smtp.passwordFile != null
    ) "passwordeval cat ${escapeShellArg (toString mail.smtp.passwordFile)}"}
  '';

  # What a message holds, for one service and one outcome.
  messageType =
    enableDefault:
    types.submodule {
      options = {
        enable = mkOption {
          type = types.bool;
          default = enableDefault;
          description = "Send a message for this outcome.";
        };
        logLines = mkOption {
          type = types.ints.positive;
          default = 30;
          description = "How many of the service's last log lines go in the mail.";
        };
        lastRunOnly = mkOption {
          type = types.bool;
          default = true;
          description = "Take the log lines from the run that just ended only. Off, they are the last lines of the service's journal, which can include earlier runs.";
        };
      };
    };

  # The settings differ per service and per outcome, so they are looked up by both.
  perMessage = ''
    case "$name:$outcome" in
    ${concatStrings (
      mapAttrsToList (
        name: u:
        concatStrings (
          map
            (outcome: ''
              ${escapeShellArg "${name}:${outcome}"}) log_lines=${
                toString u.${"on" + outcome}.logLines
              }; last_run_only=${if u.${"on" + outcome}.lastRunOnly then "1" else "0"} ;;
            '')
            [
              "Failure"
              "Success"
            ]
        )
      ) cfg.units
    )}
      *) log_lines=30; last_run_only=1 ;;
    esac
  '';

  # A popup in the desktop session of one user. The system service is root, so it enters the
  # user's session bus; with the user logged out there is no bus and nothing is shown. A popup
  # that fails never fails the service, so the mail still goes out.
  desktopScriptNixOS = ''
    uid=$(id -u ${escapeShellArg desktop.user})
    if [ -S "/run/user/$uid/bus" ]; then
      if [ "$outcome" = Failure ]; then urgency=critical; else urgency=normal; fi
      # A log helps to find what went wrong, not to read that it went well
      popup=
      if [ "$outcome" = Failure ]; then
        popup=$(logs ${toString desktop.logLines} cat)
      fi
      runuser -u ${escapeShellArg desktop.user} -- env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
        notify-send --app-name=eznotify --urgency="$urgency" "$subject" "$popup" || true
    fi
  '';

  # macOS: where each daemon's log is, so a click on its banner can open it
  logFiles = concatStrings (
    mapAttrsToList (
      name: _:
      let
        path = config.launchd.daemons.${name}.serviceConfig.StandardOutPath or null;
      in
      optionalString (path != null) "${escapeShellArg name}) logfile=${escapeShellArg path} ;;\n"
    ) cfg.units
  );

  # macOS: the popup is shown inside the GUI session of the user at the console. With the user
  # not logged in there is no session and nothing is shown.
  desktopScriptDarwin = ''
    user=${escapeShellArg desktop.user}
    if [ "$(/usr/bin/stat -f %Su /dev/console)" = "$user" ]; then
      # A log helps to find what went wrong, not to read that it went well. The text can not be
      # empty or blank: terminal-notifier takes that as no message and shows nothing.
      popup="$name finished"
      if [ "$outcome" = Failure ]; then
        popup=$(logs ${toString desktop.logLines})
      fi
      # A click on the banner opens the job's log, when the daemon has one
      logfile=
      case "$name" in
      ${logFiles}esac
      open=
      if [ -n "$logfile" ]; then open="file://$logfile"; fi
      /bin/launchctl asuser "$(id -u "$user")" /usr/bin/sudo -u "$user" \
        ${pkgs.terminal-notifier}/bin/terminal-notifier -group "$name" -title "$subject" -message "$popup" \
        ''${open:+-open "$open"} >/dev/null || true
    fi
  '';

  mailScript = status: ''
    {
      echo "From: ${mail.from}"
      echo "To: ${mail.to}"
      echo "Subject: $subject"
      echo "Date: $(date -R)"
      echo
      ${status}
      echo
      logs "$log_lines" short-iso
    } | msmtp --file=${msmtpConfig} --read-recipients
  '';

  # %i is the name of the service, without ".service". Whether it worked is read from the
  # service itself, so one unit serves both onFailure and onSuccess.
  scriptNixOS = ''
    name="$1"
    unit="$1.service"
    result=$(systemctl show --property=Result --value "$unit")
    if [ "$result" = success ]; then
      outcome=Success; word=succeeded
    else
      outcome=Failure; word="failed ($result)"
    fi
    ${perMessage}

    # The last log lines of the service: $1 of them, in journalctl output format $2
    logs() {
      id=
      if [ "$last_run_only" = 1 ]; then
        # Only the run that just ended, not what an earlier run left in the journal
        id=$(systemctl show --property=InvocationID --value "$unit")
      fi
      if [ -n "$id" ]; then
        journalctl --no-pager --lines="$1" "_SYSTEMD_INVOCATION_ID=$id" --output="$2"
      else
        journalctl --no-pager --lines="$1" --unit "$unit" --output="$2"
      fi
    }

    subject="[$(uname -n)] $unit $word"
    ${optionalString desktop.enable desktopScriptNixOS}
    ${optionalString mail.enable (
      mailScript ''systemctl status --full --no-pager --lines=0 "$unit" || true''
    )}
  '';

  # macOS: run what is after the name, keep its output going to launchd's log, and tell how it ended.
  scriptDarwin = ''
    name="$1"
    shift
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    { "$@" 2>&1; echo $? > "$tmp/rc"; } | tee "$tmp/log"
    rc=$(cat "$tmp/rc")
    if [ "$rc" = 0 ]; then
      outcome=Success; word=succeeded
    else
      outcome=Failure; word="failed (exit $rc)"
    fi
    ${perMessage}

    # The last $1 lines of what the job printed in this run
    logs() { tail -n "$1" "$tmp/log"; }

    subject="[$(uname -n)] $name $word"
    ${optionalString desktop.enable desktopScriptDarwin}
    ${optionalString mail.enable (mailScript ''echo "$name $word"'')}
    # What the job itself returned is what launchd sees
    exit "$rc"
  '';

  runner = pkgs.writeShellScript "eznotify-run" ''
    export PATH=${
      makeBinPath ([ pkgs.coreutils ] ++ optional mail.enable pkgs.msmtp)
    }:/usr/bin:/bin:/usr/sbin:/sbin
    ${scriptDarwin}
  '';

  # The daemons start the runner by this path, which stays the same when the runner changes. Their
  # plist then does not change either, so a rebuild does not restart a daemon that is running it
  # (nix-darwin restarts a daemon whose plist changed, which kills a job that is rebuilding).
  runnerPath = "/run/current-system/sw/bin/eznotify-run";
  runnerPackage = pkgs.runCommand "eznotify-run" { } ''
    mkdir -p $out/bin
    ln -s ${runner} $out/bin/eznotify-run
  '';
in
{
  options.services.eznotify = {
    enable = mkEnableOption "eznotify, a message when a service has finished or failed, by mail, as a desktop popup, or both";

    mail = {
      enable = mkOption {
        type = types.bool;
        default = mail.to != null;
        defaultText = literalExpression "config.services.eznotify.mail.to != null";
        description = "Send a mail through an SMTP account of your own. On as soon as `to` is set.";
      };
      to = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "you@example.com";
        description = "Who the mail goes to.";
      };
      from = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "ezbox@example.com";
        description = "The sender address. Some providers only accept their own account's address here.";
      };
      smtp = {
        host = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "smtp.example.com";
          description = "The SMTP server mail is sent through.";
        };
        port = mkOption {
          type = types.port;
          default = 587;
          description = "Its port: 587 for `starttls`, 465 for `tls`.";
        };
        tls = mkOption {
          type = types.enum [
            "starttls"
            "tls"
          ];
          default = "starttls";
          description = "`starttls` starts plain and switches to TLS (port 587), `tls` is TLS from the start (port 465).";
        };
        user = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "ezbox@example.com";
          description = "The account to log in with. Null for a server that takes mail without a login.";
        };
        passwordFile = mkOption {
          type = types.nullOr (types.either types.path types.str);
          default = null;
          example = "/etc/eznotify-password";
          description = ''
            A file with the account's password, read as root when a mail is sent. Give it as a
            string, not a path in the flake, or the password ends up in the Nix store.
          '';
        };
      };
    };

    desktop = {
      enable = mkOption {
        type = types.bool;
        default = desktop.user != null;
        defaultText = literalExpression "config.services.eznotify.desktop.user != null";
        description = ''
          Show a popup in the desktop session of one user, through the freedesktop notification
          service that GNOME, KDE, XFCE and others share. On as soon as `user` is set.
        '';
      };
      user = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "alice";
        description = "The user whose desktop shows the popup. Nothing is shown while they are logged out.";
      };
      logLines = mkOption {
        type = types.ints.positive;
        default = 3;
        description = "How many of the service's last log lines go in the popup.";
      };
    };

    units = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            onFailure = mkOption {
              type = messageType true;
              default = { };
              description = "The message when the service fails. On unless `onFailure.enable = false`.";
            };
            onSuccess = mkOption {
              type = messageType false;
              default = { };
              description = "The message when the service ends well. Off unless `onSuccess.enable = true`.";
            };
          };
        }
      );
      default = { };
      example = literalExpression ''
        {
          nixos-upgrade = {
            onFailure.logLines = 60;
            onSuccess = { enable = true; logLines = 5; };
          };
          restic-backups-home = { };
        }
      '';
      description = ''
        The services to send a message about, by name (`nixos-upgrade`, not
        `nixos-upgrade.service`), each with its messages. A service that keeps running only has a
        message when it fails; `onSuccess` is for those that end, such as a oneshot or a timer's job.
      '';
    };
  };

  config = mkIf cfg.enable (
    if isNixOS then
      {
        assertions = [
          {
            assertion = !mail.enable || (mail.to != null && mail.from != null && mail.smtp.host != null);
            message = "services.eznotify.mail needs to, from and smtp.host.";
          }
          {
            assertion = !desktop.enable || desktop.user != null;
            message = "services.eznotify.desktop needs a user.";
          }
        ];

        warnings = optional (
          !mail.enable && !desktop.enable
        ) "services.eznotify is enabled but sends nothing: set mail.to or desktop.user (or their enable).";

        systemd.services."eznotify@" = {
          description = "Message about %i.service";
          serviceConfig.Type = "oneshot";
          scriptArgs = "%i";
          path = [
            pkgs.coreutils
            config.systemd.package
          ]
          ++ optional mail.enable pkgs.msmtp
          ++ optionals desktop.enable [
            pkgs.libnotify
            pkgs.util-linux
          ];
          script = scriptNixOS;
        };

        # A drop-in on each listed service, not a definition of it in systemd.services: that would
        # make an empty unit of its own for a service the machine does not have. systemd merges a
        # drop-in into the unit, and ignores it when there is none.
        systemd.units = mapAttrs' (
          name: u:
          nameValuePair "${name}.service.d/eznotify.conf" {
            text = ''
              [Unit]
              ${optionalString u.onFailure.enable "OnFailure=eznotify@${name}.service"}
              ${optionalString u.onSuccess.enable "OnSuccess=eznotify@${name}.service"}
            '';
          }
        ) (filterAttrs (_: u: u.onFailure.enable || u.onSuccess.enable) cfg.units);
      }
    else
      {
        assertions = [
          {
            assertion = !mail.enable || (mail.to != null && mail.from != null && mail.smtp.host != null);
            message = "services.eznotify.mail needs to, from and smtp.host.";
          }
          {
            assertion = !desktop.enable || desktop.user != null;
            message = "services.eznotify.desktop needs a user.";
          }
        ]
        ++ mapAttrsToList (name: _: {
          assertion = config.launchd.daemons.${name}.command != "";
          message = "services.eznotify.units.${name}: there is no launchd daemon `${name}` with a `command` or `script`.";
        }) cfg.units;

        warnings = optional (
          !mail.enable && !desktop.enable
        ) "services.eznotify is enabled but sends nothing: set mail.to or desktop.user (or their enable).";

        environment.systemPackages = [ runnerPackage ];

        # The daemon keeps its own settings; only what it starts changes: the runner starts it.
        launchd.daemons = mapAttrs (name: _: {
          serviceConfig.ProgramArguments = mkForce [
            "/bin/sh"
            "-c"
            "/bin/wait4path ${runnerPath} && exec ${runnerPath} ${escapeShellArg name} ${
              config.launchd.daemons.${name}.command
            }"
          ];
        }) (filterAttrs (_: u: u.onFailure.enable || u.onSuccess.enable) cfg.units);
      }
  );
}
