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

  # Function to generate network configuration for a VLAN
  mkVlanNetwork = name: vlan: {
    "50-${name}" = {
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
      };
    };
  };

  # Generate all VLAN netdevs and networks dynamically
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
            default = [53 67];
            description = "UDP ports to open on all VLAN interfaces (usually DNS + DHCP)";
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

    bridge = {
      name = mkOption {
        type = types.str;
        default = "lan";
        description = "Name of the bridge interface";
      };
      devices = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "List of network devices to attach to the bridge";
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
        type = types.enum [ "no" "static" "dynamic-on-stop" "dynamic" "yes" ];
        default = "no";
        description = ''
          Keep network configuration on the WAN interface when the link goes
          down or networkd restarts. Use "static" to retain addresses/routes
          across reboots while waiting for DHCPv6 lease renewal — useful when
          the ISP does not honor DHCPv6 Release and holds leases for ~24h.
          See KeepConfiguration in systemd.network(5).
        '';
      };
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
    system.nssModules = lib.mkForce [];

    # DNS server configuration (systemd-resolved)
    services.resolved = {
      enable = true;
    } // (
      if (hasAttr "settings" options.services.resolved) then {
        settings = {
          Resolve = {
            DNSStubListenerExtra =
              (optional cfg.bridge.enableDNS cfg.bridge.address) ++
              (builtins.filter (x: x != null)
                (builtins.attrValues (builtins.mapAttrs (name: value:
                  if value.enableDNS then value.address else null
                ) cfg.vlan)));
          };
        };
      } else {
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
    networking.nat.enable = true;
    networking.nat.internalInterfaces = cfg.internalInterfaces;

    # Block inter-VLAN traffic (before NAT's accept rule)
    networking.firewall.extraForwardRules = mkIf cfg.isolateVlans (
      let
        ifaceList = concatMapStringsSep ", " (x: ''"${x}"'') cfg.internalInterfaces;
      in ''
        # Drop forwarding between internal interfaces
        iifname {${ifaceList}} oifname {${ifaceList}} drop
      ''
    );

    systemd.network.netdevs = mkMerge [
      {
        "10-${cfg.bridge.name}" = {
          netdevConfig = {
            Name = cfg.bridge.name;
            Kind = "bridge";
          };
        };
      }
      vlanNetdevs
    ];

    systemd.network.networks = mkMerge [
      {
        # Bridge members (physical ports → bridge)
        "20-${cfg.bridge.name}" = {
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

        # WAN uplink
        "20-wan" = {
          matchConfig = {
            Name = cfg.wan.device;
          };
          networkConfig = {
            DHCP = "yes";
            DHCPPrefixDelegation = "yes";
            IPv6PrivacyExtensions = cfg.wan.ipv6PrivacyExtensions;
            IPv6AcceptRA = "yes";
          } // optionalAttrs (cfg.wan.keepConfiguration != "no") {
            KeepConfiguration = cfg.wan.keepConfiguration;
          };
          dhcpV6Config = {
            PrefixDelegationHint = "::/${toString cfg.wan.prefixHint}";
            UseAddress = true;
          };
        };

        # Bridge itself (LAN)
        "30-${cfg.bridge.name}" = {
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
        } // optionalAttrs cfg.bridge.enableDHCPv6 {
          dhcpPrefixDelegationConfig = {
            UplinkInterface = cfg.wan.device;
            SubnetId = cfg.bridge.subnetId;
          };
        } // optionalAttrs cfg.bridge.enableDHCPv4 {
          dhcpServerConfig = {
            PoolOffset = 10;
            DNS = if cfg.bridge.enableDNS then "_server_address" else "";
          };
        };
      }
      vlanNetworks
    ];

    # Open common ports on all VLAN interfaces
    networking.firewall.interfaces = builtins.listToAttrs (
      map (vlanName: {
        name = vlanName;
        value = {
          allowedTCPPorts = cfg.vlanFirewallPorts.allowedTCPPorts;
          allowedUDPPorts = cfg.vlanFirewallPorts.allowedUDPPorts;
        };
      }) (builtins.attrNames cfg.vlan)
    );
  };
}
