{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.eznetns;
in
{
  options.services.eznetns = {
    enable = mkEnableOption "eznetns service";
    
    package = mkOption {
      type = types.package;
      default = pkgs.eznetns;
      description = "The eznetns package to use";
    };

    instances = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkEnableOption "this eznetns instance";

          portForwards = mkOption {
            type = types.listOf (types.submodule {
              freeformType = types.attrsOf types.anything;
              options = {
                listenStreams = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = "List of TCP addresses and ports to listen on (e.g., '8080', '0.0.0.0:8080')";
                  example = [ "0.0.0.0:8080" "192.168.1.100:9090" ];
                };

                listenDatagrams = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = "List of UDP addresses and ports to listen on";
                  example = [ "0.0.0.0:53" ];
                };

                target = mkOption {
                  type = types.str;
                  description = "Target address and port in the netns (e.g., '127.0.0.1:3000')";
                };
              };
            });
            default = [];
            description = "Port forwards for this netns instance. Any additional options (like BindToDevice) will be passed to socketConfig.";
          };

          nftables = mkOption {
            type = types.nullOr types.lines;
            default = null;
            description = ''
              Complete nftables configuration for this netns.
              If null, a default firewall will be generated from firewall.* options.
              If set, this overrides the entire nftables.conf file.
            '';
            example = ''
              flush ruleset
              table inet filter {
                chain input {
                  type filter hook input priority filter; policy accept;
                }
              }
            '';
          };

          nsswitch = mkOption {
            type = types.lines;
            default = ''
              passwd:         files
              group:          files
              shadow:         files
              gshadow:        files
              hosts:          files dns myhostname
              networks:       files
              protocols:      db files
              services:       db files
              ethers:         db files
              rpc:            db files
              netgroup:       nis
            '';
            description = "Content of nsswitch.conf for this netns";
          };

          configFiles = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                content = mkOption {
                  type = types.str;
                  description = "Content of the configuration file";
                };
                mode = mkOption {
                  type = types.str;
                  default = "0644";
                  description = "File permissions mode (e.g., '0644', '0600')";
                };
                user = mkOption {
                  type = types.str;
                  default = "root";
                  description = "Owner of the file";
                };
                group = mkOption {
                  type = types.str;
                  default = "root";
                  description = "Group of the file";
                };
              };
            });
            default = {};
            description = "Additional configuration files to create in /etc/eznetns/<name>/ (besides nftables.conf and nsswitch.conf)";
          };

          firewall = mkOption {
            type = types.submodule {
              options = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Whether to enable nftables firewall for this netns";
                };

                extraInputRules = mkOption {
                  type = types.lines;
                  default = "";
                  description = "Extra nftables rules to add to the input chain";
                  example = ''
                    iifname "wg0-ovpn" tcp dport 443 accept
                    tcp dport 80 accept
                    udp dport 53 accept
                  '';
                };

                extraForwardRules = mkOption {
                  type = types.lines;
                  default = "";
                  description = "Extra nftables rules to add to the forward chain";
                  example = ''
                    iifname "wg0" oifname "eth0" accept
                    ip saddr 10.0.0.0/8 accept
                  '';
                };
              };
            };
            default = {};
            description = "Firewall configuration for this netns instance";
          };
        };
      });
      default = {};
      description = "Named eznetns instances to create";
    };

    netnsService = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Mapping of systemd service names to eznetns instance names for running services in network namespaces";
      example = {
        "qbittorrent.service" = "mynetns1";
      };
    };
  };

  config = mkIf cfg.enable {
    # Create main eznetns services and port forwarding services
    systemd.services = 
      let
        mainServices = mapAttrs' (name: instanceCfg: 
          let
            # Get list of socket names for this instance
            socketNames = if instanceCfg.enable && instanceCfg.portForwards != [] then
              imap0 (idx: _: "eznetns-${name}-forward-${toString idx}.socket") instanceCfg.portForwards
            else [];
          in
          nameValuePair "eznetns-${name}" {
            enable = instanceCfg.enable;
            description = "eznetns instance: ${name}";
            
            # Add environment variable with hash of configuration
            # This forces systemd to see the service as changed when config changes
            environment = {
              CONFIG_HASH = builtins.hashString "sha256" (builtins.toJSON instanceCfg);
            };
            
            unitConfig = {
              # No special ordering for sockets - they handle it themselves
            };
            
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${cfg.package}/bin/eznetns ${name} setup";
              ExecReload = "${cfg.package}/bin/eznetns ${name} reload";
              ExecStop = "${cfg.package}/bin/eznetns ${name} remove";
              RemainAfterExit = true;
            };
            
            wantedBy = [ "multi-user.target" ];
          }
        ) cfg.instances;

        # Apply netns configuration to specified services
        netnsServices = mapAttrs' (serviceName: netnsName:
          let
            cleanServiceName = removeSuffix ".service" serviceName;
          in
          nameValuePair cleanServiceName {
            unitConfig = {
              Requires = [ "eznetns-${netnsName}.service" ];
              After = [ "eznetns-${netnsName}.service" ];
            };
            serviceConfig = {
              NetworkNamespacePath = "/run/netns/${netnsName}";
              BindReadOnlyPaths = [
                "/etc/eznetns/${netnsName}/nsswitch.conf:/etc/nsswitch.conf"
                "/etc/eznetns/${netnsName}/resolv.conf:/etc/resolv.conf"
                "/var/empty:/var/run/nscd"
              ];
            };
          }
        ) cfg.netnsService;

        # Port forwarding services
        forwardServices = flatten (mapAttrsToList (name: instanceCfg:
          if instanceCfg.enable && instanceCfg.portForwards != [] then
            imap0 (idx: forward:
              nameValuePair "eznetns-${name}-forward-${toString idx}" {
                description = "Port forward proxy for ${name} (-> ${forward.target})";
                unitConfig = {
                  Requires = [ "eznetns-${name}.service" "eznetns-${name}-forward-${toString idx}.socket" ];
                  After = [ "eznetns-${name}.service" "eznetns-${name}-forward-${toString idx}.socket" ];
                  BindsTo = [ "eznetns-${name}.service" ];
                };
                serviceConfig = {
                  Type = "simple";
                  ExecStart = "${pkgs.systemd.out}/lib/systemd/systemd-socket-proxyd ${forward.target}";
                  NetworkNamespacePath = "/run/netns/${name}";
                  Restart = "on-failure";
                  RestartSec = 5;
                };
              }
            ) instanceCfg.portForwards
          else []
        ) cfg.instances);

      in
      (mainServices // netnsServices) // (listToAttrs forwardServices);

    # Create sockets for port forwarding using systemd.sockets.<name>
    systemd.sockets = 
      let
        forwardSockets = flatten (mapAttrsToList (name: instanceCfg:
          if instanceCfg.enable && instanceCfg.portForwards != [] then
            imap0 (idx: forward:
              let
                # Extract socket-specific options (listenStreams, listenDatagrams, target)
                socketSpecificOptions = [ "listenStreams" "listenDatagrams" "target" ];
                # Everything else goes into socketConfig
                extraConfig = removeAttrs forward socketSpecificOptions;
              in
              nameValuePair "eznetns-${name}-forward-${toString idx}" {
                description = "Socket for port forward in ${name} -> ${forward.target}";
                listenStreams = forward.listenStreams;
                listenDatagrams = forward.listenDatagrams;
                socketConfig = extraConfig // {
                  # Allow reusing addresses to handle restarts cleanly
                  ReusePort = true;
                };
                wantedBy = [ "multi-user.target" ];
                unitConfig = {
                  BindsTo = [ "eznetns-${name}.service" ];
                  After = [ "eznetns-${name}.service" "network-online.target" ];
                  Wants = [ "network-online.target" ];
                  # Explicitly prevent being ordered before basic.target
                  DefaultDependencies = false;
                  # BindsTo: socket stops/starts with service
                  # After: socket starts after service completes and network is online
                  # DefaultDependencies = false: prevents automatic sockets.target dependency
                  # wantedBy multi-user.target to avoid cycle
                };
              }
            ) instanceCfg.portForwards
          else []
        ) cfg.instances);
      in
      listToAttrs forwardSockets;

    # Create configuration files in /etc/eznetns/<name>/
    environment.etc = 
      let
        configFiles = mapAttrsToList (name: instanceCfg:
          let
            # Generate nftables config
            nftablesConfig = if instanceCfg.nftables != null then
              # User provided complete nftables config
              {
                "nftables.conf" = {
                  content = instanceCfg.nftables;
                  mode = "0644";
                  user = "root";
                  group = "root";
                };
              }
            else if instanceCfg.firewall.enable then
              # Generate default firewall from firewall.* options
              {
                "nftables.conf" = {
                  content = 
                    let
                      extraInputRules = if instanceCfg.firewall.extraInputRules != "" 
                                        then "\n\t\t" + instanceCfg.firewall.extraInputRules 
                                        else "";
                      extraForwardRules = if instanceCfg.firewall.extraForwardRules != ""
                                          then "\n\t\t" + instanceCfg.firewall.extraForwardRules
                                          else "";
                    in
                    ''
                      flush ruleset
                      table inet filter {
                      	chain input {
                      		type filter hook input priority filter; policy drop;
                      		ct state { established, related } accept
                      		ct state invalid drop
                      		icmp type echo-request accept
                      		icmpv6 type != { nd-redirect, 139 } accept
                      		iifname "lo" accept${extraInputRules}
                      		reject with icmp port-unreachable
                      		reject with icmpv6 port-unreachable
                      	}
                      	chain forward {
                      		type filter hook forward priority filter; policy drop;
                      		ct state established,related accept${extraForwardRules}
                      	}
                      	chain output {
                      		type filter hook output priority filter; policy accept;
                      	}
                      }
                    '';
                  mode = "0644";
                  user = "root";
                  group = "root";
                };
              }
            else
              # No firewall
              {};

            # Add nsswitch.conf
            nsswitchConfig = {
              "nsswitch.conf" = {
                content = instanceCfg.nsswitch;
                mode = "0644";
                user = "root";
                group = "root";
              };
            };

            # Combine all configs
            allConfigs = nftablesConfig // nsswitchConfig // instanceCfg.configFiles;
          in
          mapAttrs' (fileName: fileCfg:
            nameValuePair "eznetns/${name}/${fileName}" {
              text = fileCfg.content;
              mode = fileCfg.mode;
              user = fileCfg.user;
              group = fileCfg.group;
            }
          ) allConfigs
        ) cfg.instances;
      in
      foldr (a: b: a // b) {} configFiles;

    # Assertions to ensure valid netnsService mappings
    assertions = mapAttrsToList (serviceName: netnsName: {
      assertion = hasAttr netnsName cfg.instances;
      message = "netnsService: Service '${serviceName}' references undefined eznetns instance '${netnsName}'";
    }) cfg.netnsService;
  };
}
