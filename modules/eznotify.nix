{ config, lib, pkgs, ... }:

with lib;

let
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
    ${optionalString (mail.smtp.passwordFile != null) "passwordeval cat ${escapeShellArg (toString mail.smtp.passwordFile)}"}
  '';

  # What a message holds, for one service and one outcome.
  messageType = enableDefault: types.submodule {
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
    case "$1:$outcome" in
    ${concatStrings (mapAttrsToList (name: u: concatStrings (map (outcome: ''
      ${escapeShellArg "${name}:${outcome}"}) log_lines=${toString u.${"on" + outcome}.logLines}; last_run_only=${if u.${"on" + outcome}.lastRunOnly then "1" else "0"} ;;
    '') [ "Failure" "Success" ])) cfg.units)}
      *) log_lines=30; last_run_only=1 ;;
    esac
  '';

  # A popup in the desktop session of one user. The system service is root, so it enters the
  # user's session bus; with the user logged out there is no bus and nothing is shown. A popup
  # that fails never fails the service, so the mail still goes out.
  desktopScript = ''
    uid=$(id -u ${escapeShellArg desktop.user})
    if [ -S "/run/user/$uid/bus" ]; then
      if [ "$outcome" = Failure ]; then urgency=critical; else urgency=normal; fi
      popup="on $(uname -n)"$'\n\n'"$(logs ${toString desktop.logLines} cat)"
      runuser -u ${escapeShellArg desktop.user} -- env "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" \
        notify-send --app-name=eznotify --urgency="$urgency" "$unit $word" "$popup" || true
    fi
  '';

  mailScript = ''
    {
      echo "From: ${mail.from}"
      echo "To: ${mail.to}"
      echo "Subject: $subject"
      echo "Date: $(date -R)"
      echo
      systemctl status --full --no-pager --lines=0 "$unit" || true
      echo
      logs "$log_lines" short-iso
    } | msmtp --file=${msmtpConfig} --read-recipients
  '';

  # %i is the name of the service, without ".service". Whether it worked is read from the
  # service itself, so one unit serves both onFailure and onSuccess.
  script = ''
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
    ${optionalString desktop.enable desktopScript}
    ${optionalString mail.enable mailScript}
  '';
in {
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
          type = types.enum [ "starttls" "tls" ];
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
      type = types.attrsOf (types.submodule {
        options = {
          onFailure = mkOption {
            type = messageType true;
            default = {};
            description = "The message when the service fails. On unless `onFailure.enable = false`.";
          };
          onSuccess = mkOption {
            type = messageType false;
            default = {};
            description = "The message when the service ends well. Off unless `onSuccess.enable = true`.";
          };
        };
      });
      default = {};
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

  config = mkIf cfg.enable {
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

    warnings = optional (!mail.enable && !desktop.enable)
      "services.eznotify is enabled but sends nothing: set mail.to or desktop.user (or their enable).";

    systemd.services."eznotify@" = {
      description = "Message about %i.service";
      serviceConfig.Type = "oneshot";
      scriptArgs = "%i";
      path = [ pkgs.coreutils config.systemd.package ]
        ++ optional mail.enable pkgs.msmtp
        ++ optionals desktop.enable [ pkgs.libnotify pkgs.util-linux ];
      inherit script;
    };

    # A drop-in on each listed service, not a definition of it in systemd.services: that would
    # make an empty unit of its own for a service the machine does not have. systemd merges a
    # drop-in into the unit, and ignores it when there is none.
    systemd.units = mapAttrs' (name: u: nameValuePair "${name}.service.d/eznotify.conf" {
      text = ''
        [Unit]
        ${optionalString u.onFailure.enable "OnFailure=eznotify@${name}.service"}
        ${optionalString u.onSuccess.enable "OnSuccess=eznotify@${name}.service"}
      '';
    }) (filterAttrs (_: u: u.onFailure.enable || u.onSuccess.enable) cfg.units);
  };
}
