{ config, lib, pkgs, ... }:
let
  cfg = config.services.ezsocks-rs;
  inherit (lib) mkEnableOption mkIf mkOption types mkMerge nameValuePair mkDefault
    filterAttrs mapAttrs' mapAttrsToList concatMap escapeShellArgs hasInfix hasPrefix;

  # Enabled instances that run inside an eznetns netns
  netnsInstances = filterAttrs (_: i: i.enable && i.netns != null) cfg.instances;

  settingsSubmodule = types.submodule {
    options = {
      listenHost = mkOption {
        type = types.listOf types.str;
        default = [ "127.0.0.1" "::1" ];
        description = ''
          Addresses or host names to listen on. A host name listens on all
          of its addresses.
        '';
      };
      listenPort = mkOption {
        type = types.port;
        default = 1080;
        description = "Port to listen on.";
      };
      family = mkOption {
        type = types.enum [ "any" "ipv4" "ipv6" ];
        default = "any";
        description = ''
          Address families to connect out with. `any` uses Happy Eyeballs,
          preferring IPv6. `ipv4` skips IPv6 lookups and connections
          completely, for network namespaces without IPv6.
        '';
      };
      threads = mkOption {
        type = types.either types.ints.positive (types.enum [ "auto" ]);
        default = 1;
        description = ''
          Worker threads. One is plenty for a home network; `"auto"` uses
          one per CPU core.
        '';
      };
      logLevel = mkOption {
        type = types.enum [ "DEBUG" "INFO" "WARNING" "ERROR" ];
        default = "WARNING";
        description = "Logging verbosity. `INFO` logs every connection with its destination.";
      };
      dnsCacheTtl = mkOption {
        type = types.ints.unsigned;
        default = 60;
        description = ''
          Seconds to cache host name lookups for. Failed lookups are not
          cached. Set to 0 to disable the cache.
        '';
      };
      handshakeTimeout = mkOption {
        type = types.either types.ints.unsigned types.float;
        default = 30;
        description = ''
          Seconds a client gets to send its SOCKS5 request before it is
          disconnected. Set to 0 to disable.
        '';
      };
      connectTimeout = mkOption {
        type = types.either types.ints.unsigned types.float;
        default = 30;
        description = "Seconds to connect to the destination. Set to 0 to disable.";
      };
      keepaliveIdle = mkOption {
        type = types.ints.unsigned;
        default = 300;
        description = ''
          Seconds a connection may be idle before TCP keepalive probes are
          sent to the client and the destination, so connections whose
          peer has disappeared get dropped. Set to 0 to disable.
        '';
      };
    };
  };

  # IPv6 addresses need brackets in front of the port
  listenArg = port: host:
    if hasInfix ":" host && !(hasPrefix "[" host)
    then "[${host}]:${toString port}"
    else "${host}:${toString port}";

  mkArgs = s: concatMap (h: [ "--listen" (listenArg s.listenPort h) ]) s.listenHost ++ [
    "--family" s.family
    "--threads" (toString s.threads)
    "--log-level" s.logLevel
    "--dns-cache-ttl" (toString s.dnsCacheTtl)
    "--handshake-timeout" (toString s.handshakeTimeout)
    "--connect-timeout" (toString s.connectTimeout)
    "--keepalive" (toString s.keepaliveIdle)
  ];

  mkService = description: settings: {
    inherit description;
    serviceConfig = {
      ExecStart = "${pkgs.ezsocks-rs}/bin/ezsocks ${escapeShellArgs (mkArgs settings)}";
      DynamicUser = true;
      Restart = "always";
      # Each proxied connection uses two sockets and two pipes, six file
      # descriptors; the systemd default of 1024 would cap it at about 170
      LimitNOFILE = mkDefault 65536;
    };
    wantedBy = [ "multi-user.target" ];
  };
in {
  options.services.ezsocks-rs = {
    enable = mkEnableOption "ezsocks-rs SOCKS5 proxy in the default network namespace";
    settings = mkOption {
      type = settingsSubmodule;
      default = { };
      description = "Settings for the default-namespace service.";
    };
    instances = mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          enable = mkEnableOption "ezsocks-rs instance";
          netns = mkOption {
            type = types.nullOr types.str;
            default = name;
            defaultText = lib.literalExpression "<name>";
            description = ''
              eznetns instance to run this instance in, joined through
              `services.eznetns.netnsService`. Defaults to the instance name,
              `null` runs it in the default network namespace.
            '';
          };
          settings = mkOption {
            type = settingsSubmodule;
            default = { };
            description = "Settings for this instance.";
          };
        };
      }));
      default = { };
      description = "Named ezsocks-rs instances, each running in its own eznetns netns by default.";
    };
  };

  config = mkIf (cfg.enable || cfg.instances != { }) {
    systemd.services = mkMerge [
      (mkIf cfg.enable {
        ezsocks-rs = mkService "ezsocks-rs SOCKS5 proxy" cfg.settings;
      })
      (mapAttrs' (name: instanceCfg:
        nameValuePair "ezsocks-rs-${name}"
          (mkIf instanceCfg.enable (mkService "ezsocks-rs SOCKS5 proxy ${name}" instanceCfg.settings))
      ) cfg.instances)
    ];
    # eznetns puts the instance in its netns
    services.eznetns.netnsService = mapAttrs' (name: instanceCfg:
      nameValuePair "ezsocks-rs-${name}.service" instanceCfg.netns
    ) netnsInstances;
    assertions = mapAttrsToList (name: instanceCfg: {
      assertion = config.services.eznetns.enable;
      message = "services.ezsocks-rs.instances.${name}: netns = \"${instanceCfg.netns}\" needs services.eznetns.enable";
    }) netnsInstances;
  };
}
