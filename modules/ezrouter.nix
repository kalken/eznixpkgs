{
  config,
  lib,
  options,
  ...
}:
with lib; let
  cfg = config.services.ezrouter;

  # Function to generate netdev configuration for a VLAN
  mkVlanNetdev = name: vlan: {
    "40-${name}" = {
      netdevConfig = {
        Name = name;
        Kind = "vlan";
      };
      vlanConfig = {
        Id = vlan.id;
      };
    };
  };

  # The domain handed to DHCP clients (option 15), where the router is also their DNS server:
  # without it a client has no way to know that a short name belongs under it, and only the
  # full name resolves. macOS and Windows take it as their search domain.
  # Then whatever the interface lists itself (dhcpOptions), as further SendOption lines.
  dhcpSendOptions = dns: extra:
    let all = optional (dns && cfg.domain != null && cfg.domain != "") "15:string:${cfg.domain}" ++ extra;
    in optionalAttrs (all != []) { SendOption = all; };

  # Function to generate network configuration for a VLAN
  mkVlanNetwork = name: vlan: {
    "60-${name}" = {
      matchConfig = {
        Name = name;
      };
      networkConfig = {
        Address = [ "${vlan.address}/${vlan.netmask}" ];
        IPv6AcceptRA = "no";
        IPv6PrivacyExtensions = vlan.ipv6PrivacyExtensions;
        ConfigureWithoutCarrier = "yes";
      } // optionalAttrs vlan.enableDHCPv4 {
        DHCPServer = "yes";
      } // optionalAttrs vlan.enableDHCPv6 {
        DHCPPrefixDelegation = "yes";
        IPv6SendRA = "yes";
      };
      linkConfig = {
        RequiredForOnline = "no";
      };
    } // optionalAttrs vlan.enableDHCPv6 {
      dhcpPrefixDelegationConfig = {
        UplinkInterface = cfg.wan.device;
        SubnetId = vlan.subnetId;
      };
    } // optionalAttrs vlan.enableDHCPv4 {
      dhcpServerConfig = {
        PoolOffset = 10;
        DNS = if vlan.enableDNS then "_server_address" else "";
      } // dhcpSendOptions vlan.enableDNS vlan.dhcpOptions;
    } // mkStaticLeases vlan.staticLeases;
  };

  # These end up unquoted in nftables rules, so they are checked when the config is evaluated
  portOrServiceType = types.either types.port (types.strMatching "[a-z][a-z0-9-]*|[0-9]+");
  rateLimitType = types.strMatching "[0-9]+/(second|minute|hour|day|week)( burst [0-9]+ packets)?";
  vlanRefType = types.either types.str (types.ints.between 1 4094);
  ifaceNameType = types.strMatching "[A-Za-z0-9_.:-]{1,15}";

  # Extra DHCPv4 options, shared by the bridge and every VLAN
  dhcpOptionsOption = mkOption {
    type = types.listOf types.str;
    default = [];
    example = [ "44:ipv4address:192.168.1.1" "42:ipv4address:192.168.1.1" ];
    description = ''
      Further options the DHCPv4 server on this interface sends to its clients, each as
      `number:type:value`, the form of systemd-networkd's `SendOption=`. The types are
      uint8, uint16, uint32, ipv4address, ipv6address and string. For what ezrouter has no
      setting of its own for: a WINS server (44), a time server (42), a boot file (67).
    '';
  };

  # Fixed DHCPv4 addresses, shared by the bridge and every VLAN
  forceLocalDNSOption = mkOption {
    type = types.bool;
    default = false;
    description = ''
      Make clients on this interface that ignore the DNS server they got from DHCP use the
      router anyway (needs enableDNS). Plain DNS (port 53) to any other server is redirected
      to the router, over IPv4. DNS over TLS (port 853) is rejected, and so is plain DNS over
      IPv6, which the router does not answer, so clients fall back to IPv4. DNS over HTTPS is
      not affected. Clients that eznetns routes through a netns (route.interfaces,
      route.macs) are left alone.
    '';
  };

  staticLeasesOption = mkOption {
    type = types.listOf (types.submodule {
      options = {
        mac = mkOption {
          type = types.str;
          example = "aa:bb:cc:dd:ee:ff";
          description = "MAC address of the client";
        };
        address = mkOption {
          type = types.str;
          example = "192.168.1.50";
          description = "IPv4 address the client always gets";
        };
        name = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "laptop.lan";
          description = "Optional host name the router's DNS answers with this address";
        };
      };
    });
    default = [];
    description = "Clients that always get the same address from the DHCPv4 server on this interface";
    example = literalExpression ''
      [
        { mac = "aa:bb:cc:dd:ee:01"; address = "192.168.1.50"; }
        { mac = "aa:bb:cc:dd:ee:02"; address = "192.168.1.51"; name = "printer.lan"; }
      ]
    '';
  };

  mkStaticLeases = leases: optionalAttrs (leases != []) {
    dhcpServerStaticLeases = map (lease: {
      MACAddress = lease.mac;
      Address = lease.address;
    }) leases;
  };

  allStaticLeases = cfg.bridge.staticLeases
    ++ concatMap (vlan: vlan.staticLeases) (attrValues cfg.vlan);

  # Generate all VLAN netdevs and networks dynamically
  # Clients eznetns routes through a netns, by interface or by MAC. forceLocalDNS leaves
  # them alone: their DNS goes out through the netns, not to the resolver of the router.
  netnsRoutes = optionals ((options.services ? eznetns) && config.services.eznetns.enable)
    (map (i: i.route) (filter (i: i.enable) (attrValues config.services.eznetns.instances)));
  netnsIfaces = concatMap (r: r.interfaces) netnsRoutes;
  netnsMacs = unique (map toLower (concatMap (r: r.macs) netnsRoutes));

  # Clients forceLocalDNS applies to, as an nftables match: those on the interfaces it
  # is set on
  dnsIfaces = subtractLists netnsIfaces (optional cfg.bridge.forceLocalDNS cfg.bridge.name
    ++ attrNames (filterAttrs (_: vlan: vlan.forceLocalDNS) cfg.vlan));
  dnsClients = "iifname { ${concatMapStringsSep ", " (x: ''"${x}"'') dnsIfaces} }"
    + optionalString (netnsMacs != []) " ether saddr != { ${concatStringsSep ", " netnsMacs} }";
  forceDNS = dnsIfaces != [];

  # Bridge ports. The bridge filters VLANs: a port carries its untagged VLAN (the LAN, or one
  # of the VLANs) plus the VLANs it is tagged for, and nothing else. bridge.devices are
  # ports that are only on the LAN.
  # A port refers to a VLAN by name, or by a bare ID for one this router only carries through
  # on the bridge without being on it (another router further on is on it)
  vlanIdOf = v: if isInt v then v else cfg.vlan.${v}.id;
  bridgePorts = genAttrs cfg.bridge.devices (_: { untagged = null; tagged = []; }) // cfg.bridge.ports;
  portVlanNames = port: filter isString (optional (port.untagged != null) port.untagged ++ port.tagged);
  portVlanIds = port: filter isInt (optional (port.untagged != null) port.untagged ++ port.tagged);
  mkPortNetwork = dev: port:
    let
      untaggedId = if port.untagged == null then cfg.bridge.vlanId else vlanIdOf port.untagged;
      unitName = replaceStrings [ "*" "?" "[" "]" ] [ "_" "_" "_" "_" ] dev;
    in {
      "10-${cfg.bridge.name}-${unitName}" = {
        matchConfig = {
          Name = dev;
        };
        networkConfig = {
          Bridge = cfg.bridge.name;
        };
        linkConfig = {
          RequiredForOnline = "no";
        };
        bridgeVLANs = [{ VLAN = untaggedId; PVID = untaggedId; EgressUntagged = untaggedId; }]
          ++ map (v: { VLAN = vlanIdOf v; }) port.tagged;
      };
    };

  vlanNetdevs = concatMapAttrs mkVlanNetdev cfg.vlan;
  vlanNetworks = concatMapAttrs mkVlanNetwork cfg.vlan;

in {
  options.services.ezrouter = {
    enable = mkEnableOption "ezrouter service";

    debug = mkOption {
      type = types.bool;
      default = false;
      description = "Enable debug logging for systemd-networkd when ezrouter is enabled";
    };

    isolateVlans = mkOption {
      type = types.bool;
      default = true;
      description = "Block traffic between VLANs (inter-VLAN isolation)";
    };

    vlanFirewallPorts = mkOption {
      type = types.submodule {
        options = {
          allowedTCPPorts = mkOption {
            type = types.listOf types.port;
            default = [];
            description = "TCP ports to open on all VLAN interfaces";
          };
          allowedUDPPorts = mkOption {
            type = types.listOf types.port;
            default = [];
            description = "UDP ports to open on all VLAN interfaces, on top of DNS and DHCP, which are opened per VLAN by enableDNS and enableDHCPv4";
          };
        };
      };
      default = {};
      description = "Firewall ports to open on all VLAN interfaces";
    };

    trustedInterfaces = mkOption {
      type = types.listOf types.str;
      default = [cfg.bridge.name];
      defaultText = literalExpression ''[config.services.ezrouter.bridge.name]'';
      description = "List of trusted interfaces (no firewall restrictions)";
      example = [ "lan" ];
    };

    domain = mkOption {
      type = types.nullOr types.str;
      default = config.networking.domain;
      defaultText = literalExpression "config.networking.domain";
      example = "lan";
      description = ''
        Domain the DHCP server tells its clients they are in (DHCP option 15), on the bridge
        and on every VLAN where the router is the DNS server. A client then looks a short
        name up with the domain added, so `nas` finds `nas.lan`. null sends none.
      '';
    };

    bridge = {
      name = mkOption {
        type = types.str;
        default = "lan";
        description = "Name of the bridge interface";
      };
      devices = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Network devices to attach to the bridge. They carry every VLAN, or with `vlanFiltering` the LAN only (see `ports`)";
      };
      address = mkOption {
        type = types.str;
        default = "192.168.1.1";
        description = "IP address for the bridge interface";
      };
      netmask = mkOption {
        type = types.str;
        default = "24";
        description = "Netmask for the bridge interface";
      };
      subnetId = mkOption {
        type = types.int;
        default = 1;
        description = "Subnet ID for DHCP prefix delegation";
      };
      ipv6PrivacyExtensions = mkOption {
        type = types.str;
        default = "no";
        description = "Enable IPv6 privacy extensions";
      };
      enableDHCPv4 = mkOption {
        type = types.bool;
        default = true;
        description = "Enable DHCPv4 server on the bridge interface";
      };
      enableDHCPv6 = mkOption {
        type = types.bool;
        default = true;
        description = "Enable DHCPv6 prefix delegation on the bridge interface";
      };
      enableDNS = mkOption {
        type = types.bool;
        default = true;
        description = "Enable DNS server on the bridge interface";
      };
      vlanFiltering = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Make the bridge filter VLANs, so that each port carries only the VLANs `ports` gives
          it. Without it every port in `devices` carries every VLAN, and anything plugged in
          can tag its way into any of them. Turning it on for a bridge that is already up can
          leave it without the LAN until the next reboot, so reboot after the first switch.
        '';
      };
      vlanId = mkOption {
        type = types.ints.between 1 4094;
        default = 1;
        description = ''
          With `vlanFiltering`: the VLAN ID the bridge uses internally for the untagged LAN.
          Never goes on the wire tagged; only change it if 1 clashes with one of your VLAN IDs.
        '';
      };
      ports = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            untagged = mkOption {
              type = types.nullOr vlanRefType;
              default = null;
              example = "iot";
              description = ''
                The VLAN that untagged traffic on this port belongs to, so that whatever is
                plugged in lands on that VLAN: a name from `vlan`, or a bare VLAN ID. null is the LAN.
              '';
            };
            tagged = mkOption {
              type = types.listOf vlanRefType;
              default = [];
              example = [ "iot" "guest" 4 ];
              description = ''
                VLANs this port also carries tagged, e.g. towards an access point or a switch:
                names from `vlan`, or bare VLAN IDs. A bare ID is carried across the bridge
                only, with no interface on this router, for a VLAN that another router is on.
              '';
            };
          };
        });
        default = {};
        example = literalExpression ''
          {
            enp3s0 = { untagged = "iot"; };
            enp4s0 = { tagged = [ "iot" "guest" ]; };
          }
        '';
        description = ''
          Which VLANs each bridge port is on, by interface name. Needs `vlanFiltering`: the bridge
          then lets a port carry only what is listed here, so it cannot tag its way into another
          VLAN. Ports in `devices` are on the LAN only; an entry here for the same interface replaces that.
        '';
      };
      forceLocalDNS = forceLocalDNSOption;
      staticLeases = staticLeasesOption;
      dhcpOptions = dhcpOptionsOption;
    };

    wan = {
      device = mkOption {
        type = types.str;
        description = "WAN interface device name";
      };
      ipv6PrivacyExtensions = mkOption {
        type = types.str;
        default = "no";
        description = "Enable IPv6 privacy extensions";
      };
      prefixHint = mkOption {
        type = types.int;
        default = 56;
        description = "DHCPv6 prefix delegation hint (e.g., 56 for ::/56, 64 for ::/64)";
      };
      keepConfiguration = mkOption {
        type = types.nullOr (types.enum [ "static" "dynamic-on-stop" "dynamic" "yes" ]);
        default = null;
        description = ''
          When set to "static", systemd-networkd will not remove static addresses
          and routes on the WAN interface when starting up. When set to
          "dynamic-on-stop", dynamic addresses and routes (DHCPv4, DHCPv6, SLAAC)
          are not removed when networkd stops. When set to "dynamic", dynamic
          addresses and routes are never removed, even when a DHCP lease expires.
          "yes" implies both "static" and "dynamic". Defaults to null (no
          addresses or routes are kept).
        '';
      };
      sendRelease = mkOption {
        type = types.bool;
        default = false;
        description = ''
          When set to false, the DHCPv6 client does not send a Release message
          when the interface goes down or networkd stops. Defaults to false so
          that the IPv6 prefix is preserved across reboots; most ISPs reassign
          the same lease regardless of whether a Release was received.
        '';
      };
      useMACAsIdentity = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Use the interface MAC address as client identifier for DHCPv4 and
          DUID for DHCPv6. Useful for ISPs that bind leases to MAC address.
        '';
      };
      masqueradeOnly = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Only masquerade traffic that leaves through the WAN interface. When
          false, traffic from the internal interfaces is masqueraded on every
          outgoing interface, which hides client addresses from anything the
          router forwards to (e.g. eznetns nat port forwards). Set to false if
          internal clients also leave through another interface that needs
          masquerading (a VPN tunnel on the router, a second uplink, PPPoE on
          top of wan.device). Always in effect when wan.forwardPorts is used.
        '';
      };
      forwardPorts = mkOption {
        type = types.listOf (types.submodule {
          options = {
            port = mkOption {
              type = types.port;
              description = "External port on the WAN interface to forward";
            };
            host = mkOption {
              type = types.str;
              description = "Internal host IP address to forward traffic to";
            };
            hostPort = mkOption {
              type = types.nullOr types.port;
              default = null;
              description = "Internal port on the host (defaults to the external port)";
            };
            protocol = mkOption {
              type = types.enum [ "tcp" "udp" ];
              default = "tcp";
              description = "Protocol";
            };
          };
        });
        default = [];
        description = "Port forwarding rules from the WAN interface to internal hosts";
        example = literalExpression ''
          [
            { port = 80;    host = "192.168.1.10"; }
            { port = 443;   host = "192.168.1.10"; }
            { port = 25565; host = "192.168.10.5"; hostPort = 25565; protocol = "tcp"; }
          ]
        '';
      };
      openPorts = mkOption {
        type = types.listOf (types.submodule {
          options = {
            port = mkOption {
              type = portOrServiceType;
              description = "Port number or service name (e.g. 22 or \"ssh\")";
            };
            protocol = mkOption {
              type = types.enum [ "tcp" "udp" ];
              default = "tcp";
              description = "Protocol";
            };
            rateLimit = mkOption {
              type = types.nullOr rateLimitType;
              default = null;
              description = "Per-source rate limit in nftables format, e.g. \"10/hour\" or \"5/minute\". Per IPv4 address, per IPv6 /64";
            };
          };
        });
        default = [];
        description = "Ports to open on the WAN interface. Shorthand for openPorts entries with interfaces set to the WAN device.";
        example = literalExpression ''
          [
            { port = "ssh"; rateLimit = "10/hour"; }
            { port = 51820; protocol = "udp"; }
          ]
        '';
      };
    };

    openPorts = mkOption {
      type = types.listOf (types.submodule {
        options = {
          interfaces = mkOption {
            type = types.nonEmptyListOf ifaceNameType;
            description = "Interfaces to open this port on";
            example = [ "eth0" "eth1" ];
          };
          port = mkOption {
            type = portOrServiceType;
            description = "Port number or service name (e.g. 22 or \"ssh\")";
          };
          protocol = mkOption {
            type = types.enum [ "tcp" "udp" ];
            default = "tcp";
            description = "Protocol";
          };
          rateLimit = mkOption {
            type = types.nullOr rateLimitType;
            default = null;
            description = "Per-source rate limit in nftables format, e.g. \"10/hour\" or \"5/minute\". Per IPv4 address, per IPv6 /64";
          };
        };
      });
      default = [];
      description = "Ports to open on specific interfaces, with optional per-source-IP rate limiting";
      example = literalExpression ''
        [
          { interfaces = [ "eth0" ]; port = "ssh"; rateLimit = "10/hour"; }
          { interfaces = [ "eth0" "eth1" ]; port = 443; protocol = "tcp"; }
          { interfaces = [ "eth0" ]; port = 51820; protocol = "udp"; }
        ]
      '';
    };

    internalInterfaces = mkOption {
      type = types.listOf types.str;
      default = [cfg.bridge.name] ++ (builtins.attrNames cfg.vlan);
      defaultText = literalExpression ''[config.services.ezrouter.bridge.name] ++ (builtins.attrNames config.services.ezrouter.vlan)'';
      description = "List of internal interfaces for NAT and masquerading";
    };

    vlan = mkOption {
      type = types.attrsOf (types.submodule ({ name, config, ... }: {
        options = {
          id = mkOption {
            type = types.int;
            description = "VLAN ID (required — used for defaults of address & subnetId)";
          };

          address = mkOption {
            type = types.str;
            default = "192.168.${toString config.id}.1";
            example = "192.168.30.1";
            description = ''
              IPv4 address for this VLAN interface.
              Defaults to 192.168.<vlan-id>.1
            '';
          };

          netmask = mkOption {
            type = types.str;
            default = "24";
            example = "24";
            description = "Netmask length (CIDR notation)";
          };

          subnetId = mkOption {
            type = types.int;
            default = config.id;
            example = 30;
            description = ''
              Subnet identifier used for DHCPv6 prefix delegation.
              Defaults to the VLAN ID itself (very common convention).
            '';
          };

          ipv6PrivacyExtensions = mkOption {
            type = types.str;
            default = "no";
            description = "Enable IPv6 privacy extensions";
          };

          enableDHCPv4 = mkOption {
            type = types.bool;
            default = true;
            description = "Enable DHCPv4 server on this VLAN";
          };

          enableDHCPv6 = mkOption {
            type = types.bool;
            default = true;
            description = "Enable DHCPv6 prefix delegation + router advertisement on this VLAN";
          };

          enableDNS = mkOption {
            type = types.bool;
            default = true;
            description = "Advertise this router as DNS server via DHCP";
          };
          forceLocalDNS = forceLocalDNSOption;

          staticLeases = staticLeasesOption;
          dhcpOptions = dhcpOptionsOption;

          allowedTCPPorts = mkOption {
            type = types.listOf types.port;
            default = [];
            description = "TCP ports to open on this VLAN interface (merged with vlanFirewallPorts.allowedTCPPorts)";
          };

          allowedUDPPorts = mkOption {
            type = types.listOf types.port;
            default = [];
            description = "UDP ports to open on this VLAN interface (merged with vlanFirewallPorts.allowedUDPPorts)";
          };
        };

      }));

      default = {};
      description = ''
        VLAN configurations. Most fields now receive reasonable defaults based on the VLAN ID.

        Minimal example:
          vlan = {
            iot   .id = 30;
            guest .id = 40;
            camera.id = 50;
          };

        This automatically creates:
        • iot   → 192.168.30.1/24, subnetId=30
        • guest → 192.168.40.1/24, subnetId=40
        • camera→ 192.168.50.1/24, subnetId=50

        You only need to override fields when the defaults don't fit.
      '';
      example = literalExpression ''
        {
          iot.id       = 30;
          guest.id     = 40;
          trusted.id   = 10;
          cameras = {
            id      = 50;
            address = "172.16.50.1";   # override default
            netmask = "23";
          };
          dmz = {
            id           = 99;
            enableDHCPv4 = false;
            enableDHCPv6 = false;
            enableDNS    = false;
          };
        }
      '';
    };
  };

  config = mkIf cfg.enable {
    networking.useDHCP = false;
    systemd.network.enable = true;
    services.nscd.enable = false;
    # NixOS refuses NSS modules without nscd, and other modules (resolved, mymachines) add them
    system.nssModules = lib.mkForce [];

    # DNS server configuration (systemd-resolved)
    services.resolved = {
      enable = true;
    } // (
      if (hasAttr "settings" options.services.resolved) then {
        settings = {
          Resolve = {
            # LLMNR answers on the LAN can be spoofed, and nothing here needs it
            LLMNR = mkDefault "false";
            DNSStubListenerExtra =
              (optional cfg.bridge.enableDNS cfg.bridge.address) ++
              (builtins.filter (x: x != null)
                (builtins.attrValues (builtins.mapAttrs (name: value:
                  if value.enableDNS then value.address else null
                ) cfg.vlan)));
          };
        };
      } else {
        llmnr = mkDefault "false";
        extraConfig =
          (optionalString cfg.bridge.enableDNS "DNSStubListenerExtra=${cfg.bridge.address}\n") +
          (concatMapStringsSep "\n" (vlan: "DNSStubListenerExtra=${vlan.address}")
            (builtins.filter (v: v.enableDNS) (builtins.attrValues cfg.vlan)));
      }
    );

    systemd.services.systemd-networkd.serviceConfig = mkIf cfg.debug {
      Environment = "SYSTEMD_LOG_LEVEL=debug";
    };

    # Enable global IPv6 forwarding
    systemd.network.config.networkConfig.IPv6Forwarding = true;

    # Firewall & NAT
    networking.firewall.enable = true;
    networking.nftables.enable = true;
    networking.firewall.filterForward = true;
    networking.firewall.trustedInterfaces = cfg.trustedInterfaces;
    networking.firewall.logRefusedConnections = false;
    # Strict: drop packets whose source could not be reached back through the interface they came in on
    networking.firewall.checkReversePath = mkDefault true;
    networking.nat.enable = true;
    networking.nat.internalInterfaces = cfg.internalInterfaces;
    # Port forwards need the external interface to be set
    networking.nat.externalInterface =
      mkIf (cfg.wan.masqueradeOnly || cfg.wan.forwardPorts != []) cfg.wan.device;
    networking.nat.forwardPorts = map (rule: {
      sourcePort = rule.port;
      destination = "${rule.host}:${toString (if rule.hostPort != null then rule.hostPort else rule.port)}";
      proto = rule.protocol;
    }) cfg.wan.forwardPorts;

    # Open ports on specific interfaces with optional per-source-IP rate limiting
    networking.firewall.extraInputRules =
      let
        allOpenPorts = cfg.openPorts
          ++ map (r: r // { interfaces = [ cfg.wan.device ]; }) cfg.wan.openPorts;
      in
      optionalString (allOpenPorts != []) (
      concatMapStringsSep "\n" (rule:
        let
          port = toString rule.port;
          ifaceExpr =
            if builtins.length rule.interfaces == 1
            then ''"${builtins.head rule.interfaces}"''
            else "{ ${concatMapStringsSep ", " (i: ''"${i}"'') rule.interfaces} }";
          # Short and unique per rule (set names are limited to 31 characters)
          meterName = "rl-${substring 0 8 (builtins.hashString "sha256" (builtins.toJSON rule))}";
        in
        if rule.rateLimit != null then
          # IPv4 per address, IPv6 per /64 (a host owns a whole /64, so per address would be no limit)
          ''
            iifname ${ifaceExpr} ${rule.protocol} dport ${port} ct state new meter ${meterName}-v4 { ip saddr limit rate ${rule.rateLimit} } accept
            iifname ${ifaceExpr} ${rule.protocol} dport ${port} ct state new meter ${meterName}-v6 { ip6 saddr and ffff:ffff:ffff:ffff:: limit rate ${rule.rateLimit} } accept''
        else
          ''iifname ${ifaceExpr} ${rule.protocol} dport ${port} accept''
      ) allOpenPorts
    );

    # Block inter-VLAN traffic (before NAT's accept rule)
    networking.firewall.extraForwardRules = mkMerge [
      (mkIf cfg.isolateVlans (
        let
          ifaceList = concatMapStringsSep ", " (x: ''"${x}"'') cfg.internalInterfaces;
        in ''
          # Drop forwarding between internal interfaces
          iifname {${ifaceList}} oifname {${ifaceList}} drop
        ''
      ))
      (mkIf forceDNS ''
        # forceLocalDNS: no DNS over TLS, and no plain DNS over IPv6 (resolved only
        # listens on IPv4, so it cannot be redirected and clients fall back to IPv4)
        ${dnsClients} meta l4proto { tcp, udp } th dport 853 reject
        ${dnsClients} meta nfproto ipv6 meta l4proto { tcp, udp } th dport 53 reject
      '')
    ];

    # forceLocalDNS: plain DNS to any other server ends up on the address of the interface
    # it came in on, where resolved listens. Plain dstnat, so that the eznetns chain
    # (dstnat - 5) runs first, and never the same packets: that one takes DNS to the router.
    networking.nftables.tables.ezrouter-dns = mkIf forceDNS {
      family = "ip";
      content = ''
        chain prerouting {
          type nat hook prerouting priority dstnat; policy accept;
          ${dnsClients} fib daddr type != local meta l4proto { tcp, udp } th dport 53 redirect
        }
      '';
    };

    systemd.network.netdevs = mkMerge [
      {
        # 30- bridge netdev
        "30-${cfg.bridge.name}" = {
          netdevConfig = {
            Name = cfg.bridge.name;
            Kind = "bridge";
          };
        } // optionalAttrs cfg.bridge.vlanFiltering {
          bridgeConfig = {
            VLANFiltering = true;
            DefaultPVID = "none";
          };
        };
      }
      # 40- VLAN netdevs
      vlanNetdevs
    ];

    systemd.network.networks = mkMerge [
      {
        # 20- WAN uplink
        "20-wan" = {
          matchConfig = {
            Name = cfg.wan.device;
          };
          networkConfig = {
            DHCP = "yes";
            DHCPPrefixDelegation = "yes";
            IPv6PrivacyExtensions = cfg.wan.ipv6PrivacyExtensions;
            IPv6AcceptRA = "yes";
          } // optionalAttrs (cfg.wan.keepConfiguration != null) {
            KeepConfiguration = cfg.wan.keepConfiguration;
          };
          dhcpV4Config = mkIf cfg.wan.useMACAsIdentity {
            ClientIdentifier = "mac";
          };
          dhcpV6Config = {
            PrefixDelegationHint = "::/${toString cfg.wan.prefixHint}";
            UseAddress = true;
          } // optionalAttrs (!cfg.wan.sendRelease) {
            SendRelease = false;
          } // optionalAttrs cfg.wan.useMACAsIdentity {
            DUIDType = "link-layer";
          };
        };

        # 50- bridge network (after VLAN netdevs at 40-)
        "50-${cfg.bridge.name}" = {
          matchConfig = {
            Name = cfg.bridge.name;
          };
          networkConfig = {
            Address = [ "${cfg.bridge.address}/${cfg.bridge.netmask}" ];
            IPv6AcceptRA = "no";
            IPv6PrivacyExtensions = cfg.bridge.ipv6PrivacyExtensions;
            VLAN = builtins.attrNames cfg.vlan;
            ConfigureWithoutCarrier = "yes";
          } // optionalAttrs cfg.bridge.enableDHCPv6 {
            DHCPPrefixDelegation = "yes";
            IPv6SendRA = "yes";
          } // optionalAttrs cfg.bridge.enableDHCPv4 {
            DHCPServer = "yes";
          };
          # The bridge itself is on the LAN untagged and on every VLAN tagged, which is
          # what the VLAN interfaces on top of it receive
        } // optionalAttrs cfg.bridge.vlanFiltering {
          bridgeVLANs = [{ VLAN = cfg.bridge.vlanId; PVID = cfg.bridge.vlanId; EgressUntagged = cfg.bridge.vlanId; }]
            ++ map (vlan: { VLAN = vlan.id; }) (attrValues cfg.vlan);
        } // optionalAttrs cfg.bridge.enableDHCPv6 {
          dhcpPrefixDelegationConfig = {
            UplinkInterface = cfg.wan.device;
            SubnetId = cfg.bridge.subnetId;
          };
        } // optionalAttrs cfg.bridge.enableDHCPv4 {
          dhcpServerConfig = {
            PoolOffset = 10;
            DNS = if cfg.bridge.enableDNS then "_server_address" else "";
          } // dhcpSendOptions cfg.bridge.enableDNS cfg.bridge.dhcpOptions;
        } // mkStaticLeases cfg.bridge.staticLeases;
      }
      (if cfg.bridge.vlanFiltering
        # 10- physical members → bridge (enslaving), each with its VLANs
        then concatMapAttrs mkPortNetwork bridgePorts
        # 10- physical members → bridge (enslaving), all VLANs
        else {
          "10-${cfg.bridge.name}" = {
            matchConfig = {
              Name = cfg.bridge.devices;
            };
            networkConfig = {
              Bridge = cfg.bridge.name;
            };
            linkConfig = {
              RequiredForOnline = "no";
            };
          };
        })
      # 60- VLAN networks
      vlanNetworks
    ];

    # Names of static leases, answered by the DNS server from the hosts file
    networking.hosts = mkMerge (map (lease: { ${lease.address} = [ lease.name ]; })
      (filter (lease: lease.name != null) allStaticLeases));

    assertions = [
      {
        assertion = all (i: elem i cfg.internalInterfaces) ([ cfg.bridge.name ] ++ attrNames cfg.vlan);
        message = "services.ezrouter: internalInterfaces must include the bridge and every VLAN, or the missing ones are neither isolated nor NATed (it is ${toString cfg.internalInterfaces})";
      }
      {
        assertion = cfg.bridge.ports != {} -> cfg.bridge.vlanFiltering;
        message = "services.ezrouter: bridge.ports only does something with bridge.vlanFiltering = true";
      }
      {
        assertion = all (port: all (n: hasAttr n cfg.vlan) (portVlanNames port)) (attrValues cfg.bridge.ports);
        message = "services.ezrouter: bridge.ports refers to a VLAN name that is not defined in services.ezrouter.vlan (use a number for a VLAN ID this router only carries)";
      }
      {
        assertion = all (port: all (id: all (vlan: vlan.id != id) (attrValues cfg.vlan) && id != cfg.bridge.vlanId) (portVlanIds port)) (attrValues cfg.bridge.ports);
        message = "services.ezrouter: bridge.ports uses a bare VLAN ID that is a VLAN of this router or bridge.vlanId, use its name instead";
      }
      {
        assertion = all (vlan: vlan.id >= 1 && vlan.id <= 4094 && (!cfg.bridge.vlanFiltering || vlan.id != cfg.bridge.vlanId)) (attrValues cfg.vlan);
        message = "services.ezrouter: VLAN IDs must be 1-4094 and, with vlanFiltering, differ from bridge.vlanId (${toString cfg.bridge.vlanId}), set bridge.vlanId to a free ID";
      }
      {
        assertion = all (i: i.forceLocalDNS -> i.enableDNS) ([ cfg.bridge ] ++ attrValues cfg.vlan);
        message = "services.ezrouter: forceLocalDNS needs enableDNS on the same interface";
      }
      {
        assertion = all (lease: builtins.match "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" lease.mac != null) allStaticLeases;
        message = "services.ezrouter: staticLeases mac must look like \"aa:bb:cc:dd:ee:ff\"";
      }
      {
        assertion = allUnique (map (lease: lease.address) allStaticLeases)
          && allUnique (map (lease: toLower lease.mac) allStaticLeases);
        message = "services.ezrouter: a mac or address is used by more than one entry in staticLeases";
      }
    ];

    # Open ports on VLAN interfaces (global vlanFirewallPorts merged with per-VLAN allowedTCPPorts/allowedUDPPorts)
    networking.firewall.interfaces = builtins.listToAttrs (
      map (vlanName: {
        name = vlanName;
        value = {
          # DNS (TCP too, for truncated answers) where the router is the DNS server, DHCP where it serves leases
          allowedTCPPorts = cfg.vlanFirewallPorts.allowedTCPPorts ++ cfg.vlan.${vlanName}.allowedTCPPorts
            ++ optional cfg.vlan.${vlanName}.enableDNS 53;
          allowedUDPPorts = cfg.vlanFirewallPorts.allowedUDPPorts ++ cfg.vlan.${vlanName}.allowedUDPPorts
            ++ optional cfg.vlan.${vlanName}.enableDNS 53
            ++ optional cfg.vlan.${vlanName}.enableDHCPv4 67;
        };
      }) (builtins.attrNames cfg.vlan)
    );
  };
}
