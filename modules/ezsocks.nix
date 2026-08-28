{ config, lib, pkgs, options, ... }:
let
  cfg = config.services.ezsocks;
  inherit (lib) mkEnableOption mkIf mkOption types mkMerge nameValuePair mkAliasOptionModule;

  legacyOptionNames = [ "enable" "user" "group" "settings" "instances" ];
  legacyOptionWarnings = lib.concatMap (name:
    lib.optional options.services.prettysocks.${name}.isDefined
      "`services.prettysocks.${name}` is deprecated and has been renamed to `services.ezsocks.${name}`. Please change your configuration."
  ) legacyOptionNames;

  tomlFormat = pkgs.formats.toml { };

  settingsSubmodule = types.submodule {
    options = {
      listenHost = mkOption {
        type = types.listOf types.str;
        default = [ "127.0.0.1" "::1" ];
        description = "Addresses to listen on.";
      };
      listenPort = mkOption {
        type = types.port;
        default = 1080;
        description = "Port to listen on.";
      };
      listenBacklog = mkOption {
        type = types.int;
        default = 1024;
        description = "Backlog for the listening socket(s).";
      };
      logLevel = mkOption {
        type = types.enum [ "DEBUG" "INFO" "WARNING" "ERROR" "CRITICAL" ];
        default = "WARNING";
        description = "Logging verbosity.";
      };
      useBuiltinHappyEyeballs = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Use Python's built-in Happy Eyeballs implementation (no
          asynchronous address resolution) instead of the `async-stagger`
          module.
        '';
      };
      resolutionDelay = mkOption {
        type = types.float;
        default = 0.05;
        description = ''
          (async-stagger implementation only) Delay in seconds before
          resolving the next address family. See RFC 8305 section 8.
        '';
      };
      firstAddressFamilyCount = mkOption {
        type = types.int;
        default = 1;
        description = ''
          Number of addresses of the first resolved address family to try
          before interleaving with the other family. See RFC 8305 section 8.
        '';
      };
      connectionAttemptDelay = mkOption {
        type = types.float;
        default = 0.25;
        description = ''
          Delay in seconds between successive connection attempts to
          different addresses. See RFC 8305 section 8.
        '';
      };
      workerProcesses = mkOption {
        type = types.either types.int (types.enum [ "auto" ]);
        default = "auto";
        description = ''
          Number of worker processes to run. Each worker binds its own
          listening socket to the same address/port with `SO_REUSEPORT` set,
          so the kernel distributes connections between them across CPU
          cores. Set to `"auto"` to use one worker per CPU core.
        '';
      };
      relayBufferSize = mkOption {
        type = types.int;
        default = 131072;
        description = ''
          Buffer size, in bytes, used to relay data between downstream and
          upstream connections.
        '';
      };
    };
  };

  mkConfigFile = name: settings: tomlFormat.generate "ezsocks-${name}.toml" {
    listen_host = settings.listenHost;
    listen_port = settings.listenPort;
    listen_backlog = settings.listenBacklog;
    log_level = settings.logLevel;
    use_builtin_happy_eyeballs = settings.useBuiltinHappyEyeballs;
    resolution_delay = settings.resolutionDelay;
    first_address_family_count = settings.firstAddressFamilyCount;
    connection_attempt_delay = settings.connectionAttemptDelay;
    worker_processes = settings.workerProcesses;
    relay_buffer_size = settings.relayBufferSize;
  };
in {
  imports = map (name:
    mkAliasOptionModule [ "services" "prettysocks" name ] [ "services" "ezsocks" name ]
  ) legacyOptionNames;

  options.services.ezsocks = {
    enable = mkEnableOption "EzSocks service in default namespace";
    user = mkOption {
      type = types.str;
      default = "ezsocks";
      description = "User under which to run the EzSocks service in the default namespace.";
    };
    group = mkOption {
      type = types.str;
      default = "proxy";
      description = "Group under which to run the EzSocks service in the default namespace.";
    };
    settings = mkOption {
      type = settingsSubmodule;
      default = { };
      description = "EzSocks settings for the default-namespace service, written to a TOML config file.";
    };
    instances = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkEnableOption "EzSocks instance in network namespace";
          user = mkOption {
            type = types.str;
            default = "ezsocks";
            description = "User under which to run this EzSocks instance in the network namespace.";
          };
          group = mkOption {
            type = types.str;
            default = "nogroup";
            description = "Group under which to run this EzSocks instance in the network namespace.";
          };
          settings = mkOption {
            type = settingsSubmodule;
            default = { };
            description = "EzSocks settings for this instance, written to a TOML config file.";
          };
        };
      });
      default = {};
      description = "Per-network-namespace EzSocks instances";
    };
  };
  config = mkMerge [
    { warnings = legacyOptionWarnings; }
    (mkIf (cfg.enable || (cfg.instances != {})) {
      # Define users and groups for both default service and instances
      users.users = mkMerge ([
        (mkIf cfg.enable {
          "${cfg.user}" = {
            isSystemUser = true;
            group = cfg.group;
            description = "EzSocks service user";
          };
        })
      ] ++ (lib.mapAttrsToList (name: instanceCfg:
        mkIf instanceCfg.enable {
          "ezsocks-${name}" = {
            isSystemUser = true;
            group = instanceCfg.group;
            description = "EzSocks instance user for ${name}";
          };
        }
      ) cfg.instances));
      users.groups = mkMerge ([
        (mkIf cfg.enable {
          "${cfg.group}" = {};
        })
      ] ++ (lib.mapAttrsToList (name: instanceCfg:
        mkIf instanceCfg.enable {
          "${instanceCfg.group}" = {};
        }
      ) cfg.instances));
      # Define all systemd services (default and instances)
      systemd.services = mkMerge ([
        # Default EzSocks service
        (mkIf cfg.enable {
          ezsocks = {
            enable = true;
            description = "EzSocks service";
            serviceConfig = {
              User = cfg.user;
              Group = cfg.group;
              ExecStart = "${pkgs.ezsocks}/bin/ezsocks --config ${mkConfigFile "default" cfg.settings}";
              Restart = "always";
            };
            wantedBy = [ "multi-user.target" ];
          };
        })
        # Instance-specific services
        (lib.mapAttrs' (name: instanceCfg:
          nameValuePair "ezsocks-${name}" (
            mkIf instanceCfg.enable {
              enable = true;
              description = "EzSocks VPN for ${name}";
              unitConfig = {
                Requires = "eznetns-${name}.service";
                After = "eznetns-${name}.service";
                BindsTo = "eznetns-${name}.service";
              };
              serviceConfig = {
                User = "ezsocks-${name}";
                Group = instanceCfg.group;
                ExecStart = "${pkgs.ezsocks}/bin/ezsocks --config ${mkConfigFile name instanceCfg.settings}";
                NetworkNamespacePath = "/run/netns/${name}";
                BindReadOnlyPaths = [
                  "/etc/eznetns/${name}/resolv.conf:/etc/resolv.conf"
                  "/etc/eznetns/${name}/nsswitch.conf:/etc/nsswitch.conf"
                  "/var/empty:/var/run/nscd"
                ];
                Restart = "always";
              };
              wantedBy = [ "multi-user.target" ];
            }
          )
        ) cfg.instances)
      ]);
    })
  ];
}
