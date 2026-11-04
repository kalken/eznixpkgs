{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.eznotify;
  mail = cfg.mail;

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
    {
      echo "From: ${mail.from}"
      echo "To: ${mail.to}"
      echo "Subject: [$(uname -n)] $unit $word"
      echo "Date: $(date -R)"
      echo
      systemctl status --full --no-pager --lines=0 "$unit" || true
      echo
      id=
      if [ "$last_run_only" = 1 ]; then
        # Only the run that just ended, not what an earlier run left in the journal
        id=$(systemctl show --property=InvocationID --value "$unit")
      fi
      if [ -n "$id" ]; then
        journalctl --no-pager --lines="$log_lines" "_SYSTEMD_INVOCATION_ID=$id" --output=short-iso
      else
        journalctl --no-pager --lines="$log_lines" --unit "$unit" --output=short-iso
      fi
    } | msmtp --file=${msmtpConfig} --read-recipients
  '';
in {
  options.services.eznotify = {
    enable = mkEnableOption "eznotify, a message when a service has finished or failed";

    mail = {
      to = mkOption {
        type = types.str;
        example = "you@example.com";
        description = "Who the mail goes to.";
      };
      from = mkOption {
        type = types.str;
        example = "ezbox@example.com";
        description = "The sender address. Some providers only accept their own account's address here.";
      };
      smtp = {
        host = mkOption {
          type = types.str;
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
    systemd.services = {
      "eznotify@" = {
        description = "Message about %i.service";
        serviceConfig.Type = "oneshot";
        scriptArgs = "%i";
        path = [ pkgs.msmtp pkgs.coreutils config.systemd.package ];
        inherit script;
      };
    } // mapAttrs (name: u: {
      onFailure = optional u.onFailure.enable "eznotify@${name}.service";
      onSuccess = optional u.onSuccess.enable "eznotify@${name}.service";
    }) cfg.units;
  };
}
