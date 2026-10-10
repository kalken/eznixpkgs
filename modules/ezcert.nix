{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.ezcert;

  # The authority: one of its own in `dir`, unless an existing one is named (ca.cert, ca.key).
  ownCa  = cfg.ca.cert == null;
  caCert = if ownCa then "${cfg.dir}/ca.pem" else cfg.ca.cert;
  caKey  = if ownCa then "${cfg.dir}/ca-key.pem" else cfg.ca.key;

  # All the work is in ezcert.sh, which can be run by hand; this only calls it.
  script = "${pkgs.runtimeShell} ${./ezcert.sh}";

  # Its answer is taken on a line of its own: inside the `if` a failure of the script would
  # pass for "nothing changed" and the unit would end well with no certificate made.
  certLine = name: c: ''
    answer=$(${script} cert ${escapeShellArgs ([ "${cfg.dir}/${name}" caCert caKey (toString c.days) (toString c.renewDays) c.user c.group ] ++ c.names)})
    if [ "$answer" = changed ]; then
      restart="$restart ${escapeShellArgs c.restart}"
    fi
  '' + optionalString (c.keystore != null) ''
    answer=$(${script} keystore ${escapeShellArgs [ "${cfg.dir}/${name}" c.keystore.path c.keystore.alias c.keystore.password c.keystore.user c.keystore.group ]})
    if [ "$answer" = changed ]; then
      restart="$restart ${escapeShellArgs c.restart}"
    fi
  '';

  anyKeystore = any (c: c.keystore != null) (attrValues cfg.certs);
in {
  options.services.ezcert = {
    enable = mkEnableOption "ezcert, certificates for services from an authority of one's own";

    dir = mkOption {
      type = types.str;
      default = "/var/lib/ezcert";
      description = "Where the certificates are kept, each in a folder of its name, and the authority when ezcert makes its own.";
    };

    ca = {
      cert = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/var/lib/eznix/ca.pem";
        description = ''
          The certificate of an existing authority to sign with, instead of one ezcert makes
          itself: what a browser already trusts then covers these certificates too. Set
          together with `ca.key`. It only has to be there when ezcert runs (see `after`), not
          when the system is built.
        '';
      };
      key = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/var/lib/eznix/ca-key.pem";
        description = "The key of that existing authority. Read as root.";
      };
      name = mkOption {
        type = types.str;
        default = "ezcert (${config.networking.hostName})";
        defaultText = literalExpression ''"ezcert (''${config.networking.hostName})"'';
        description = "What the authority ezcert makes itself is called: the name a browser or a keychain lists it under. Not used with an existing one.";
      };
      path = mkOption {
        type = types.str;
        readOnly = true;
        default = caCert;
        defaultText = literalExpression ''"''${dir}/ca.pem", or ca.cert'';
        description = "The certificate of the authority in use: the file to import where these certificates should be trusted.";
      };
    };

    keytoolPackage = mkOption {
      type = types.package;
      default = pkgs.jre_headless;
      defaultText = literalExpression "pkgs.jre_headless";
      description = "Where `keytool` comes from, for certificates with a `keystore`. Set it to the Java the service itself runs on to avoid a second one on the system.";
    };

    after = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "eznix.service" ];
      description = "Units that have to have run before ezcert does: the one that makes the existing authority, when `ca.cert` names one that a service creates.";
    };

    certs = mkOption {
      default = {};
      example = literalExpression ''
        {
          unifi = { names = [ "ezbox.lan" "192.168.1.1" ]; group = "nginx"; restart = [ "nginx.service" ]; };
        }
      '';
      description = "The certificates to keep, by a name of your choosing: each is a folder of that name in `dir`.";
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          names = mkOption {
            type = types.listOf types.str;
            example = [ "ezbox.lan" "192.168.1.1" ];
            description = "The host names and addresses the certificate is for: what is typed in the browser to reach the service. Changing them makes a new certificate.";
          };
          user = mkOption {
            type = types.str;
            default = "root";
            description = "Owner of the files.";
          };
          group = mkOption {
            type = types.str;
            default = "root";
            description = "Group of the files. The key is readable by owner and group only, so this is how a service that does not run as root gets to it.";
          };
          days = mkOption {
            type = types.ints.positive;
            default = 365;
            description = "How long a certificate lasts. Apple's systems refuse one that lasts more than 825 days, whoever signed it.";
          };
          renewDays = mkOption {
            type = types.ints.positive;
            default = 30;
            description = "A new certificate is made when the old one has fewer days than this left.";
          };
          restart = mkOption {
            type = types.listOf types.str;
            default = [];
            example = [ "nginx.service" ];
            description = "Units to restart when the certificate was made anew, so they read it. They are also started only after ezcert at boot.";
          };
          keystore = mkOption {
            default = null;
            example = literalExpression ''
              { path = "/var/lib/unifi/data/keystore"; alias = "unifi"; password = "aircontrolenterprise"; user = "unifi"; group = "unifi"; }
            '';
            description = ''
              Also keep the certificate as a Java keystore, for a service that reads nothing
              else. It is written again whenever it is missing, was made from another
              certificate, or has been replaced by something else, so what is set here is
              what the service finds. The folder it lies in has to exist: it is the
              service's own and is not created.
            '';
            type = types.nullOr (types.submodule {
              options = {
                path = mkOption { type = types.str; description = "The keystore file."; };
                alias = mkOption { type = types.str; default = name; description = "The name the certificate has inside the keystore: the one the service looks for."; };
                password = mkOption { type = types.str; default = "changeit"; description = "The keystore's password, as the service expects it. It ends up in the Nix store, readable by everyone, which is fine for the fixed ones such services use and for nothing else."; };
                user = mkOption { type = types.str; default = "root"; description = "Owner of the keystore."; };
                group = mkOption { type = types.str; default = "root"; description = "Group of the keystore."; };
              };
            });
          };
          cert = mkOption {
            type = types.str;
            readOnly = true;
            default = "${cfg.dir}/${name}/cert.pem";
            description = "The certificate.";
          };
          fullchain = mkOption {
            type = types.str;
            readOnly = true;
            default = "${cfg.dir}/${name}/fullchain.pem";
            description = "The certificate followed by the authority's.";
          };
          key = mkOption {
            type = types.str;
            readOnly = true;
            default = "${cfg.dir}/${name}/key.pem";
            description = "Its key.";
          };
        };
      }));
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.ca.cert == null) == (cfg.ca.key == null);
        message = "services.ezcert.ca: cert and key go together, set both to use an existing authority or neither for ezcert to make its own.";
      }
    ] ++ mapAttrsToList (name: c: {
      assertion = c.names != [] && c.days > c.renewDays;
      message = "services.ezcert.certs.${name}: needs at least one name, and days above renewDays (it would be made anew at every run otherwise).";
    }) cfg.certs;

    systemd.services.ezcert = {
      description = "ezcert: certificates for services";
      wantedBy = [ "multi-user.target" ];
      after = cfg.after;
      wants = cfg.after;
      # Whatever reads a certificate starts after it is there.
      before = unique (concatMap (c: c.restart) (attrValues cfg.certs));
      path = [ pkgs.openssl pkgs.coreutils ] ++ optional anyKeystore cfg.keytoolPackage;
      serviceConfig.Type = "oneshot";
      script = ''
        set -eu
        mkdir -p ${escapeShellArg cfg.dir}
        ${optionalString ownCa "${script} ca ${escapeShellArgs [ cfg.dir cfg.ca.name ]}"}
        restart=""
        ${concatStrings (mapAttrsToList certLine cfg.certs)}
        # Only what is running: at boot they have not started yet, and start with the new
        # certificate anyway. Not waited for: one of them may be waiting for this unit.
        if [ -n "$restart" ]; then
          ${pkgs.systemd}/bin/systemctl --no-block try-restart $restart || true
        fi
      '';
    };

    # A certificate lasts a year and is made anew a month before it runs out: looked at
    # weekly, and at every boot.
    systemd.timers.ezcert = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
