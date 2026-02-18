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
  vlanNetdevs = lib.attrsets.concatMapAttrs mkVlanNetdev cfg.vlan;
  vlanNetworks = lib.attrsets.concatMapAttrs mkVlanNetwork cfg.vlan;
  
  # Generate extra DNSStubListenerExtra lines for resolved
  generateExtraConfig = vlan:
    let
      lines = builtins.attrValues (builtins.mapAttrs (name: value:
        "DNSStubListenerExtra=${value.address}"
      ) vlan);
    in
      builtins.concatStringsSep "\n" lines;
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
            description = "UDP ports to open on all VLAN interfaces";
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
      example = ["lan"];
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
        type = types.bool;
        default = false;
        description = "Keep network configuration on the WAN interface even when the link goes down";
      };
    };

    internalInterfaces = mkOption {
      type = types.listOf types.str;
      default = [cfg.bridge.name] ++ (builtins.attrNames cfg.vlan);
      defaultText = literalExpression ''[config.services.ezrouter.bridge.name] ++ (builtins.attrNames config.services.ezrouter.vlan)'';
      description = "List of internal interfaces for NAT";
    };
    
    # VLAN configuration options
    vlan = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          id = mkOption {
            type = types.int;
            description = "VLAN ID";
          };
          address = mkOption {
            type = types.str;
            description = "IP address for the VLAN interface";
          };
          netmask = mkOption {
            type = types.str;
            default = "24";
            description = "Netmask for the VLAN interface";
          };
          subnetId = mkOption {
            type = types.int;
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
            description = "Enable DHCPv4 server on this VLAN interface";
          };
          enableDHCPv6 = mkOption {
            type = types.bool;
            default = true;
            description = "Enable DHCPv6 prefix delegation on this VLAN interface";
          };
          enableDNS = mkOption {
            type = types.bool;
            default = true;
            description = "Enable DNS server on this VLAN interface";
          };
        };
      });
      default = {};
      description = "VLAN configurations for the router";
    };
  };

  config = mkIf cfg.enable {
    networking.useDHCP = false;
    systemd.network.enable = true;
    services.nscd.enable = false;
    system.nssModules = lib.mkForce [];

    # DNS server configuration
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
    
    # Enable Global ipv6 forward
    systemd.network.config.networkConfig.IPv6Forwarding = true;

    # Firewall configuration
    networking.firewall.enable = true;
    networking.nftables.enable = true;
    networking.firewall.filterForward = true;
    networking.firewall.trustedInterfaces = cfg.trustedInterfaces;
    networking.firewall.logRefusedConnections = false;
    networking.nat.enable = true;
    networking.nat.internalInterfaces = cfg.internalInterfaces;
    
    # Block inter-VLAN traffic before NAT's blanket accept rule
    networking.firewall.extraForwardRules = mkIf cfg.isolateVlans (
      let
        ifaceList = concatMapStringsSep ", " (x: ''"${x}"'') cfg.internalInterfaces;
      in ''
        # Drop forwarding between internal interfaces (must come before NAT's accept rule)
        iifname {${ifaceList}} oifname {${ifaceList}} drop
      ''
    );

    # Bridge and VLAN netdev configuration
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

    # Bridge members, WAN, and VLAN network configuration
    systemd.network.networks = mkMerge [
      {
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

        # WAN configuration
        "20-wan" = {
          matchConfig = {
            Name = cfg.wan.device;
          };
          networkConfig = {
            DHCP = "yes";
            DHCPPrefixDelegation = "yes";
            IPv6PrivacyExtensions = cfg.wan.ipv6PrivacyExtensions;
            IPv6AcceptRA = "yes";
            KeepConfiguration = mkIf cfg.wan.keepConfiguration "yes";
          };
          
          dhcpV6Config = {
            PrefixDelegationHint = "::/${toString cfg.wan.prefixHint}";
            UseAddress = true;
          };
        };

        # Bridge network configuration
        "30-${cfg.bridge.name}" = {
          matchConfig = {
            Name = cfg.bridge.name;
          };
          networkConfig = {
            Address = ["${cfg.bridge.address}/${cfg.bridge.netmask}"];
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
    
    # Configure firewall ports for all VLAN interfaces
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
