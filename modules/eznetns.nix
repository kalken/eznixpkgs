{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.eznetns;

  # Routed ("nat") port forwards send packets over a veth pair instead of
  # proxying them, so services in the netns see the real client address.
  # Replies are steered back over the veth with a connection mark.
  natMark = "0x657a";
  natTable = "25978";

  # Stable per-instance number (0-255) derived from the instance name
  nameOctet = name:
    (builtins.fromTOML "v = 0x${substring 0 2 (builtins.hashString "sha256" name)}").v;

  natOnlyOptions = [ "interfaces" "allowedSources" "fromHost" ];

  natForwards = instanceCfg: filter (fwd: fwd.mode == "nat") instanceCfg.portForwards;
  hasNat = instanceCfg: instanceCfg.enable && natForwards instanceCfg != [];
  natInstances = filterAttrs (_: hasNat) cfg.instances;

  # Source routing sends everything selected clients forward through the
  # netns, over the same veth pair the nat forwards use.
  hasRoute = instanceCfg: instanceCfg.enable && instanceCfg.route.sources != [];
  routeInstances = filterAttrs (_: hasRoute) cfg.instances;
  hasVeth = instanceCfg: hasNat instanceCfg || hasRoute instanceCfg;
  vethInstances = filterAttrs (_: hasVeth) cfg.instances;

  # Routing table and rule priority on the host, per instance
  routeTable = name: toString (25979 + nameOctet name);
  routePref = name: 20000 + 2 * nameOctet name;

  # Proxy forwards keep their position in portForwards as unit index
  proxyForwards = instanceCfg:
    filter (f: f.forward.mode == "proxy")
      (imap0 (idx: forward: { inherit idx forward; }) instanceCfg.portForwards);

  # "8080" or "192.168.1.10:8080" -> { address, port }, null if not parseable
  parseListen = s:
    let m = builtins.match "(([0-9.]+):)?([0-9]+)" s;
    in if m == null then null else {
      address = let a = elemAt m 1; in if a == "0.0.0.0" then null else a;
      port = elemAt m 2;
    };

  # One entry per listen address of every nat forward
  natRules = instanceCfg: concatMap (fwd:
    let
      mkRule = proto: s:
        let l = parseListen s; in
        optional (l != null) {
          inherit proto fwd;
          inherit (l) address port;
          targetPort = if fwd.target != null then fwd.target else l.port;
        };
    in
    concatMap (mkRule "tcp") fwd.listenStreams ++ concatMap (mkRule "udp") fwd.listenDatagrams
  ) (natForwards instanceCfg);

  nftSet = elems: "{ ${concatStringsSep ", " elems} }";

  # DNAT rules in the host namespace
  natHostRuleset = name: instanceCfg:
    let
      veth = instanceCfg.veth;
      rules = natRules instanceCfg;
      dnat = r: "${r.proto} dport ${r.port} dnat to ${veth.nsAddress}:${r.targetPort}";
      preRule = r:
        optionalString (r.fwd.interfaces != []) "iifname ${nftSet (map (i: ''"${i}"'') r.fwd.interfaces)} "
        + optionalString (r.fwd.allowedSources != []) "ip saddr ${nftSet r.fwd.allowedSources} "
        # Only traffic addressed to the host itself, never traffic routed through it
        + (if r.address != null then "ip daddr ${r.address} " else "fib daddr type local ")
        + dnat r;
      outRule = r:
        (if r.address != null then "ip daddr ${r.address} " else "ip daddr != 127.0.0.0/8 fib daddr type local ")
        + dnat r;
    in
    pkgs.writeText "eznetns-${name}-nat-host.nft" (concatStringsSep "\n" (
      [
        "table ip eznetns-${name}"
        "delete table ip eznetns-${name}"
        "table ip eznetns-${name} {"
        "\tchain prerouting {"
        "\t\ttype nat hook prerouting priority -100; policy accept;"
        "\t\tiifname \"${veth.hostInterface}\" return"
      ]
      ++ map (r: "\t\t${preRule r}") rules
      ++ [
        "\t}"
        "\tchain output {"
        "\t\ttype nat hook output priority -100; policy accept;"
      ]
      ++ map (r: "\t\t${outRule r}") (filter (r: r.fwd.fromHost) rules)
      ++ [
        "\t}"
        "}"
        ""
      ]
    ));

  # Connection marking inside the netns, kept in its own table so it also
  # works together with a custom nftables config
  natNetnsRuleset = name: instanceCfg:
    let nsIf = instanceCfg.veth.nsInterface; in
    if hasRoute instanceCfg then
    # With source routing the netns also forwards: traffic from the veth is
    # masqueraded out through the tunnel, and its replies are marked so they
    # are routed back over the veth.
    pkgs.writeText "eznetns-${name}-nat-netns.nft" ''
      table ip eznetns-nat
      delete table ip eznetns-nat
      table ip eznetns-nat {
      	chain prerouting {
      		type filter hook prerouting priority mangle; policy accept;
      		iifname "${nsIf}" ct mark set ${natMark}
      		iifname != "${nsIf}" ct mark ${natMark} meta mark set ${natMark}
      	}
      	chain output {
      		type route hook output priority mangle; policy accept;
      		ct mark ${natMark} meta mark set ${natMark}
      	}
      	chain forward {
      		type filter hook forward priority mangle; policy accept;
      		iifname "${nsIf}" tcp flags syn tcp option maxseg size set rt mtu
      	}
      	chain postrouting {
      		type nat hook postrouting priority 100; policy accept;
      		iifname "${nsIf}" oifname != "${nsIf}" masquerade
      	}
      }
    ''
    else
    pkgs.writeText "eznetns-${name}-nat-netns.nft" ''
      table ip eznetns-nat
      delete table ip eznetns-nat
      table ip eznetns-nat {
      	chain prerouting {
      		type filter hook prerouting priority mangle; policy accept;
      		iifname "${instanceCfg.veth.nsInterface}" meta mark set ${natMark} ct mark set ${natMark}
      	}
      	chain output {
      		type route hook output priority mangle; policy accept;
      		ct mark ${natMark} meta mark set ${natMark}
      	}
      }
    '';

  natPath = makeBinPath [ pkgs.iproute2 pkgs.nftables pkgs.procps ];

  # Idempotent, runs after both setup and reload
  natUp = name: instanceCfg:
    let
      veth = instanceCfg.veth;
      pref = routePref name;
      table = routeTable name;
      # Marked replies must not be judged by the reverse path filter when
      # the netns forwards, so it is switched off on the veth instead
      srcValidMark = if hasRoute instanceCfg then "0" else "1";
      routeUp = optionalString (hasRoute instanceCfg) ("\n" + ''

        # Source routing: the netns forwards, and the host sends the selected
        # sources to it. The first rule keeps their traffic to local networks
        # on the main table, the second sends everything else to the netns.
        ip netns exec ${name} sysctl -q -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.${veth.nsInterface}.rp_filter=0
        sysctl -q -w net.ipv4.conf.${veth.hostInterface}.rp_filter=0
        while ip rule del pref ${toString pref} 2>/dev/null; do :; done
        while ip rule del pref ${toString (pref + 1)} 2>/dev/null; do :; done
        ip route replace default via ${veth.nsAddress} dev ${veth.hostInterface} table ${table}
        ${concatMapStringsSep "\n" (src: ''
          ip rule add pref ${toString pref} from ${src} lookup main suppress_prefixlength 0
          ip rule add pref ${toString (pref + 1)} from ${src} lookup ${table}'') instanceCfg.route.sources}'');
    in
    pkgs.writeShellScript "eznetns-${name}-nat-up" ''
      set -eu
      export PATH=${natPath}

      if ! ip link show ${veth.hostInterface} >/dev/null 2>&1; then
        ip link add ${veth.hostInterface} type veth peer name ${veth.nsInterface} netns ${name}
      fi
      ip addr replace ${veth.hostAddress}/${toString veth.prefixLength} dev ${veth.hostInterface}
      ip link set ${veth.hostInterface} up
      ip -n ${name} addr replace ${veth.nsAddress}/${toString veth.prefixLength} dev ${veth.nsInterface}
      ip -n ${name} link set ${veth.nsInterface} up

      # Replies to forwarded connections leave through the veth, everything
      # else keeps using the main routing table of the netns
      ip netns exec ${name} sysctl -q -w net.ipv4.conf.all.src_valid_mark=${srcValidMark}
      ip -n ${name} rule del fwmark ${natMark} lookup ${natTable} 2>/dev/null || true
      ip -n ${name} rule add fwmark ${natMark} lookup ${natTable}
      ip -n ${name} route replace default via ${veth.hostAddress} dev ${veth.nsInterface} table ${natTable}

      ip netns exec ${name} nft -f ${natNetnsRuleset name instanceCfg}
      nft -f ${natHostRuleset name instanceCfg}${routeUp}
    '';

  natDown = name: instanceCfg:
    let
      pref = routePref name;
      routeDown = optionalString (hasRoute instanceCfg) ("\n" + ''
        while ip rule del pref ${toString pref} 2>/dev/null; do :; done
        while ip rule del pref ${toString (pref + 1)} 2>/dev/null; do :; done
        ip route flush table ${routeTable name} 2>/dev/null || true'');
    in
    pkgs.writeShellScript "eznetns-${name}-nat-down" ''
      export PATH=${natPath}
      nft delete table ip eznetns-${name} 2>/dev/null || true
      ip link del ${instanceCfg.veth.hostInterface} 2>/dev/null || true${routeDown}
    '';

  # Hash input for CONFIG_HASH. Instances without nat forwards hash the same
  # as before the nat options existed, so they are not restarted by them.
  # WireGuard rotation runs in its own units and is never part of the hash.
  hashedConfig = instanceCfg:
    let
      base = removeAttrs instanceCfg ([ "wireguard" ]
        ++ optional (!hasRoute instanceCfg) "route"
        ++ optional (!hasVeth instanceCfg) "veth");
    in
    if hasNat instanceCfg then base
    else base // {
      portForwards = map (fwd: removeAttrs fwd ([ "mode" ] ++ natOnlyOptions)) instanceCfg.portForwards;
    };

  # WireGuard interfaces with config rotation, as { name, dev, rotate } entries
  rotations = concatLists (mapAttrsToList (name: instanceCfg:
    optionals instanceCfg.enable (mapAttrsToList (dev: wg: {
      inherit name dev;
      inherit (wg) rotate;
    }) (filterAttrs (_: wg: wg.rotate != null) instanceCfg.wireguard))
  ) cfg.instances);
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
      type = types.attrsOf (types.submodule ({ name, ... }: {
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
                  type = types.nullOr types.str;
                  default = null;
                  description = ''
                    Mode "proxy": target address and port in the netns (e.g., '127.0.0.1:3000'), required.
                    Mode "nat": target port on the veth address of the netns (e.g., '3000'), defaults to the listen port.
                  '';
                };

                mode = mkOption {
                  type = types.enum [ "proxy" "nat" ];
                  default = "proxy";
                  description = ''
                    "proxy" relays connections with systemd-socket-proxyd, the service sees them coming from 127.0.0.1.
                    "nat" routes them into the netns over a veth pair (IPv4 only), the service sees the real client address.
                  '';
                };

                interfaces = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = "Mode \"nat\" only: host interfaces to forward from. Empty means all interfaces.";
                  example = [ "br0" "vlan30" ];
                };

                allowedSources = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = "Mode \"nat\" only: source addresses or networks to forward. Empty means any source.";
                  example = [ "192.168.30.0/24" ];
                };

                fromHost = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Mode \"nat\" only: also forward connections the host itself makes to its own (non-loopback) addresses.";
                };
              };
            });
            default = [];
            description = "Port forwards for this netns instance. For proxy forwards, any additional options (like BindToDevice) will be passed to socketConfig.";
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

          wireguard = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                rotate = mkOption {
                  type = types.nullOr (types.submodule {
                    options = {
                      source = mkOption {
                        type = types.str;
                        default = "/root/.config/ezwgen";
                        example = "/var/lib/ezwgen";
                        description = ''
                          Folder ezwgen reads from. It needs <source>/<netns>/<interface>.conf
                          (settings such as the private key) and the folder
                          <source>/<netns>/<interface>/ with templates to pick from.
                          Read at runtime, so the private key is not copied to the nix store.
                        '';
                      };

                      pattern = mkOption {
                        type = types.str;
                        default = ".";
                        example = "se-";
                        description = "Only pick templates whose file name contains this text";
                      };

                      interval = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        example = "daily";
                        description = ''
                          How often to rotate, as a systemd calendar expression (see systemd.time(7)).
                          If null there is no timer and the service only runs when started manually.
                        '';
                      };
                    };
                  });
                  default = null;
                  description = ''
                    Generate a new config for this WireGuard interface with ezwgen (a random
                    template merged with your settings) and reload the interface. Creates
                    eznetns-<netns>-rotate-<interface>.service, and a timer if interval is set.
                  '';
                };
              };
            });
            default = {};
            description = "Per-interface WireGuard settings, keyed by interface name (the config file name without .conf)";
            example = literalExpression ''
              {
                wg0-surf.rotate = {
                  interval = "daily";
                };
              }
            '';
          };

          route = {
            sources = mkOption {
              type = types.listOf types.str;
              default = [];
              example = [ "192.168.1.50" "192.168.30.0/24" ];
              description = ''
                IPv4 addresses or networks whose forwarded traffic is routed through
                this netns instead of the normal default route. Traffic to the host
                itself and to its directly connected networks is not affected. The
                sources are blocked from every other way out, also while the netns
                is down. IPv4 only, and requires the nftables firewall with
                networking.firewall.filterForward.
              '';
            };
          };

          veth = {
            hostInterface = mkOption {
              type = types.str;
              default = "ve-${name}";
              description = "Name of the veth interface in the host namespace (at most 15 characters)";
            };

            nsInterface = mkOption {
              type = types.str;
              default = "host0";
              description = "Name of the veth interface inside the netns";
            };

            hostAddress = mkOption {
              type = types.str;
              default = "10.200.${toString (nameOctet name)}.1";
              defaultText = literalExpression ''"10.200.<derived from instance name>.1"'';
              description = "IPv4 address of the host end of the veth pair";
            };

            nsAddress = mkOption {
              type = types.str;
              default = "10.200.${toString (nameOctet name)}.2";
              defaultText = literalExpression ''"10.200.<derived from instance name>.2"'';
              description = "IPv4 address of the netns end of the veth pair. Forwards with mode \"nat\" are sent to this address.";
            };

            prefixLength = mkOption {
              type = types.ints.between 1 30;
              default = 30;
              description = "Prefix length of the veth addresses";
            };
          };
        };
      }));
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
          nameValuePair "eznetns-${name}" {
            enable = instanceCfg.enable;
            description = "eznetns instance: ${name}";
            
            # Add environment variable with hash of configuration
            # This forces systemd to see the service as changed when config changes
            environment = {
              CONFIG_HASH = builtins.hashString "sha256" (builtins.toJSON (hashedConfig instanceCfg));
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
            } // optionalAttrs (hasVeth instanceCfg) {
              # The veth and nat rules are set up after the netns exists, and
              # again after a reload since that flushes the netns ruleset
              ExecStartPost = natUp name instanceCfg;
              ExecReload = [
                "${cfg.package}/bin/eznetns ${name} reload"
                (natUp name instanceCfg)
              ];
              ExecStopPost = natDown name instanceCfg;
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
          if instanceCfg.enable then
            map ({ idx, forward }:
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
            ) (proxyForwards instanceCfg)
          else []
        ) cfg.instances);

        # WireGuard config rotation, also usable manually with systemctl start
        rotateServices = map ({ name, dev, rotate }:
          nameValuePair "eznetns-${name}-rotate-${dev}" ({
            description = "New WireGuard config for ${dev} in ${name}";
            unitConfig = {
              Requires = [ "eznetns-${name}.service" ];
              After = [ "eznetns-${name}.service" ];
            };
            serviceConfig = {
              Type = "oneshot";
              ExecStartPre = escapeShellArgs [
                "${cfg.package}/bin/ezwgen"
                "--source" rotate.source
                "--netns" name
                "--dev" dev
                "--pattern" rotate.pattern
              ];
              ExecStart = escapeShellArgs [ "${cfg.package}/bin/eznetns" name "wg.reload" dev ];
            };
          } // optionalAttrs (rotate.interval != null) {
            startAt = rotate.interval;
          })
        ) rotations;

      in
      (mainServices // netnsServices) // (listToAttrs forwardServices) // (listToAttrs rotateServices);

    # Create sockets for port forwarding using systemd.sockets.<name>
    systemd.sockets = 
      let
        forwardSockets = flatten (mapAttrsToList (name: instanceCfg:
          if instanceCfg.enable then
            map ({ idx, forward }:
              let
                # Extract socket-specific options (listenStreams, listenDatagrams, target)
                socketSpecificOptions = [ "listenStreams" "listenDatagrams" "target" "mode" ] ++ natOnlyOptions;
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
            ) (proxyForwards instanceCfg)
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
                      # Accept nat forwards arriving over the veth
                      natInputRules = concatStrings (unique (map (r:
                        "\n\t\tiifname \"${instanceCfg.veth.nsInterface}\" ${r.proto} dport ${r.targetPort} accept"
                      ) (natRules instanceCfg)));
                      extraInputRules = if instanceCfg.firewall.extraInputRules != "" 
                                        then "\n\t\t" + instanceCfg.firewall.extraInputRules 
                                        else "";
                      # Let routed sources out through the netns
                      routeForwardRules = optionalString (hasRoute instanceCfg)
                        "\n\t\tiifname \"${instanceCfg.veth.nsInterface}\" oifname != \"${instanceCfg.veth.nsInterface}\" accept";
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
                      		iifname "lo" accept${natInputRules}${extraInputRules}
                      		reject with icmp port-unreachable
                      		reject with icmpv6 port-unreachable
                      	}
                      	chain forward {
                      		type filter hook forward priority filter; policy drop;
                      		ct state established,related accept${routeForwardRules}${extraForwardRules}
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

    # Forwarding between the host interfaces and the veth pairs
    boot.kernel.sysctl = mkIf (vethInstances != {}) {
      "net.ipv4.conf.all.forwarding" = mkDefault true;
      "net.ipv4.conf.default.forwarding" = mkDefault true;
    };

    # systemd-networkd ships a default config for container interfaces named
    # ve-* that would replace the veth addresses, so keep its hands off
    systemd.network.networks = mapAttrs' (name: instanceCfg:
      nameValuePair "10-eznetns-${name}" {
        matchConfig.Name = instanceCfg.veth.hostInterface;
        linkConfig.Unmanaged = true;
      }
    ) vethInstances;

    # Routed sources may only leave through their netns. These rules are part
    # of the host firewall, so they also hold while the netns is down.
    networking.firewall.extraForwardRules = mkIf (routeInstances != {}) (mkBefore (
      concatStrings (mapAttrsToList (name: instanceCfg: ''
        ip saddr ${nftSet instanceCfg.route.sources} oifname "${instanceCfg.veth.hostInterface}" accept comment "eznetns ${name}: routed sources"
        ip saddr ${nftSet instanceCfg.route.sources} oifname != "${instanceCfg.veth.hostInterface}" drop comment "eznetns ${name}: routed sources only leave through the netns"
      '') routeInstances)
    ));

    # Replies come back over the veth from addresses the host would reach
    # through its own default route
    networking.firewall.extraReversePathFilterRules = mkIf (routeInstances != {}) (
      concatStrings (mapAttrsToList (name: instanceCfg: ''
        iifname "${instanceCfg.veth.hostInterface}" accept comment "eznetns ${name}: routed sources"
      '') routeInstances)
    );

    # systemd-networkd would otherwise remove the routing rules when it restarts
    systemd.network.config = mkIf (routeInstances != {}) {
      networkConfig.ManageForeignRoutingPolicyRules = false;
    };

    warnings =
      let nat = config.networking.nat; in
      optional (natInstances != {} && nat.enable && nat.externalInterface == null && nat.internalInterfaces != [])
        "services.eznetns: networking.nat masquerades everything coming from ${concatStringsSep ", " nat.internalInterfaces}, so nat port forwards will not see the client addresses of those interfaces. Set networking.nat.externalInterface (or leave services.ezrouter.wan.masqueradeOnly enabled when using ezrouter).";

    assertions =
      # Assertions to ensure valid netnsService mappings
      mapAttrsToList (serviceName: netnsName: {
        assertion = hasAttr netnsName cfg.instances;
        message = "netnsService: Service '${serviceName}' references undefined eznetns instance '${netnsName}'";
      }) cfg.netnsService
      # Assertions on port forwards
      ++ flatten (mapAttrsToList (name: instanceCfg:
        imap0 (idx: fwd:
          let
            where = "services.eznetns.instances.${name}.portForwards[${toString idx}]";
            listens = fwd.listenStreams ++ fwd.listenDatagrams;
            extraAttrs = attrNames (removeAttrs fwd ([ "listenStreams" "listenDatagrams" "target" "mode" ] ++ natOnlyOptions));
          in
          if fwd.mode == "proxy" then [
            {
              assertion = fwd.target != null;
              message = "${where}: target is required for proxy forwards";
            }
            {
              assertion = fwd.interfaces == [] && fwd.allowedSources == [] && !fwd.fromHost;
              message = "${where}: interfaces, allowedSources and fromHost are only supported with mode = \"nat\"";
            }
          ] else [
            {
              assertion = listens != [] && all (s: parseListen s != null) listens;
              message = "${where}: nat forwards need at least one listen address of the form \"port\" or \"ipv4:port\"";
            }
            {
              assertion = fwd.target == null || builtins.match "[0-9]+" fwd.target != null;
              message = "${where}: target of a nat forward is a port on the veth address of the netns (e.g. \"8080\"), not an address";
            }
            {
              assertion = extraAttrs == [];
              message = "${where}: socket options (${concatStringsSep ", " extraAttrs}) are not supported with mode = \"nat\"";
            }
          ]
        ) instanceCfg.portForwards
      ) cfg.instances)
      # Assertions on the veth pairs of instances with nat forwards
      ++ mapAttrsToList (name: instanceCfg: {
        assertion = stringLength instanceCfg.veth.hostInterface <= 15;
        message = "services.eznetns.instances.${name}.veth.hostInterface: '${instanceCfg.veth.hostInterface}' is longer than 15 characters, set a shorter name";
      }) vethInstances
      ++ [
        (let
          addrs = concatMap (i: [ i.veth.hostAddress i.veth.nsAddress ]) (attrValues vethInstances);
          names = map (i: i.veth.hostInterface) (attrValues vethInstances);
        in {
          assertion = allUnique addrs && allUnique names;
          message = "services.eznetns: instances with nat forwards or routed sources need distinct veth addresses and host interface names, set instances.<name>.veth explicitly";
        })
      ]
      # Assertions on source routing
      ++ mapAttrsToList (name: instanceCfg: {
        assertion = all (src: builtins.match "([0-9]{1,3}[.]){3}[0-9]{1,3}(/[0-9]{1,2})?" src != null) instanceCfg.route.sources;
        message = "services.eznetns.instances.${name}.route.sources: entries must be IPv4 addresses or networks, e.g. \"192.168.1.50\" or \"192.168.30.0/24\"";
      }) routeInstances
      ++ optionals (routeInstances != {}) [
        {
          assertion = config.networking.nftables.enable && config.networking.firewall.enable && config.networking.firewall.filterForward;
          message = "services.eznetns: route.sources needs networking.nftables.enable, networking.firewall.enable and networking.firewall.filterForward, so the sources can be kept from leaving any other way";
        }
        {
          assertion = allUnique (map nameOctet (attrNames routeInstances));
          message = "services.eznetns: two instances with route.sources share the same derived routing table, rename one of them";
        }
        {
          assertion = allUnique (concatMap (i: i.route.sources) (attrValues routeInstances));
          message = "services.eznetns: the same entry is listed in route.sources of more than one instance";
        }
      ];
  };
}
