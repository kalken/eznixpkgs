{ config, lib, pkgs, ... }:
let
  cfg = config.services.prettysocks;
  inherit (lib) mkEnableOption mkIf mkOption types mkMerge nameValuePair;
in {
  options.services.prettysocks = {
    enable = mkEnableOption "PrettySocks service in default namespace";
    user = mkOption {
      type = types.str;
      default = "prettysocks";
      description = "User under which to run the PrettySocks service in the default namespace.";
    };
    group = mkOption {
      type = types.str;
      default = "proxy";
      description = "Group under which to run the PrettySocks service in the default namespace.";
    };
    instances = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkEnableOption "PrettySocks instance in network namespace";
          user = mkOption {
            type = types.str;
            default = "prettysocks";
            description = "User under which to run this PrettySocks instance in the network namespace.";
          };
          group = mkOption {
            type = types.str;
            default = "nogroup";
            description = "Group under which to run this PrettySocks instance in the network namespace.";
          };
        };
      });
      default = {};
      description = "Per-network-namespace PrettySocks instances";
    };
  };
  config = mkIf (cfg.enable || (cfg.instances != {})) {
    # Define users and groups for both default service and instances
    users.users = mkMerge ([
      (mkIf cfg.enable {
        "${cfg.user}" = {
          isSystemUser = true;
          group = cfg.group;
          description = "PrettySocks service user";
        };
      })
    ] ++ (lib.mapAttrsToList (name: instanceCfg:
      mkIf instanceCfg.enable {
        "prettysocks-${name}" = {
          isSystemUser = true;
          group = instanceCfg.group;
          description = "PrettySocks instance user for ${name}";
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
      # Default PrettySocks service
      (mkIf cfg.enable {
        prettysocks = {
          enable = true;
          description = "PrettySocks service";
          serviceConfig = {
            User = cfg.user;
            Group = cfg.group;
            StandardError = "null";
            ExecStart = "${pkgs.prettysocks}/bin/prettysocks";
            Restart = "always";
          };
          wantedBy = [ "multi-user.target" ];
        };
      })
      # Instance-specific services
      (lib.mapAttrs' (name: instanceCfg:
        nameValuePair "prettysocks-${name}" (
          mkIf instanceCfg.enable {
            enable = true;
            description = "PrettySocks VPN for ${name}";
            unitConfig = {
              Requires = "eznetns-${name}.service";
              After = "eznetns-${name}.service";
              BindsTo = "eznetns-${name}.service";
            };
            serviceConfig = {
              User = "prettysocks-${name}";
              Group = instanceCfg.group;
              StandardError = "null";
              ExecStart = "${pkgs.prettysocks}/bin/prettysocks";
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
  };
}
