{ config, lib, pkgs, ... }:
let
  cfg = config.programs.ezcage;
  inherit (lib) mkEnableOption mkIf mkOption types mapAttrs' nameValuePair
    optional optionals concatMap concatStringsSep attrNames any hasPrefix stringLength;

  profileSubmodule = types.submodule {
    options = {
      command = mkOption {
        type = types.str;
        example = "claude";
        description = ''
          Command to run. Looked up in `packages` first, then on the PATH of
          whoever runs the profile.
        '';
      };
      args = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Arguments for the command. Arguments given after the profile name are added after these.";
      };
      readWrite = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "/etc/nixos" ];
        description = "Paths the cage can read and write. A `.git` inside them stays read-only.";
      };
      readOnly = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Paths the cage can only read.";
      };
      groups = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "eznix" ];
        description = ''
          Extra groups the cage runs with, typically the group that may
          write a `readWrite` path. Only for the run: no group file changes.
        '';
      };
      netns = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "claude";
        description = "eznetns namespace for the network, with its DNS. Default: host network.";
      };
      offline = mkOption {
        type = types.bool;
        default = false;
        description = "No network at all, only loopback.";
      };
      nix = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Allow Nix commands such as `nix shell`. `null`: allowed, except
          with `netns` or `offline`, since Nix builds run outside the cage's
          network.
        '';
      };
      workDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/etc/nixos";
        description = "Directory to start in. Default: the current directory if the cage can see it, else its home.";
      };
      packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        example = lib.literalExpression "[ pkgs.claude-code pkgs.git ]";
        description = "Packages on the cage's PATH.";
      };
    };
  };

  # Each profile runs as its own user, so cages can't see each other's processes
  profileUser = name: "ezcage-${name}";

  profileArgs = name: p:
    [ "--name" name "--user" (profileUser name) ]
    ++ concatMap (x: [ "--rw" x ]) p.readWrite
    ++ concatMap (x: [ "--ro" x ]) p.readOnly
    ++ concatMap (g: [ "--group" g ]) p.groups
    ++ optionals (p.netns != null) [ "--netns" p.netns ]
    ++ optional p.offline "--offline"
    ++ optional (p.nix == true) "--nix"
    ++ optional (p.nix == false) "--no-nix"
    ++ optionals (p.workDir != null) [ "--workdir" p.workDir ]
    ++ optionals (p.packages != [ ]) [
      "--path"
      "${pkgs.buildEnv { name = "ezcage-${name}-path"; paths = p.packages; }}/bin"
    ]
    ++ [ "--" p.command ] ++ p.args;
in
{
  options.programs.ezcage = {
    enable = mkEnableOption "ezcage, which runs programs that see only the paths they are granted";

    package = mkOption {
      type = types.package;
      default = pkgs.ezcage;
      defaultText = lib.literalExpression "pkgs.ezcage";
      description = "The ezcage package.";
    };

    profiles = mkOption {
      type = types.attrsOf profileSubmodule;
      default = { };
      example = lib.literalExpression ''
        {
          nixos = {
            command = "claude";
            groups = [ "eznix" ];
            readWrite = [ "/etc/nixos" ];
            workDir = "/etc/nixos";
          };
        }
      '';
      description = ''
        Named cages, run with `ezcage <name>`. Each gets its own user
        (`ezcage-<name>`) and a home in `/var/lib/ezcage/<name>` that is kept
        across runs.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = map (name: {
      assertion = builtins.match "[A-Za-z0-9_-]+" name != null && stringLength (profileUser name) <= 32;
      message = "programs.ezcage.profiles.${name}: the name may only contain letters, digits, '_' and '-', and be at most 25 characters.";
    }) (attrNames cfg.profiles) ++ [{
      assertion = !(any (u: u == "ezcage" || u == "@ezcage" || hasPrefix "ezcage-" u || hasPrefix "@ezcage-" u)
        (config.nix.settings.trusted-users or [ ]));
      message = "programs.ezcage: cage users must not be in nix.settings.trusted-users; they could add binary caches or unsigned store paths.";
    }];

    environment.systemPackages = [ cfg.package ];

    # One argument per line; ezcage reads them back with mapfile
    environment.etc = mapAttrs' (name: p:
      nameValuePair "ezcage/profiles/${name}" {
        text = concatStringsSep "\n" (profileArgs name p) + "\n";
      }) cfg.profiles;

    # Shared user for ad-hoc runs; every cage also runs with the ezcage group
    users.users = {
      ezcage = {
        isSystemUser = true;
        group = "ezcage";
        home = "/var/empty";
      };
    } // mapAttrs' (name: _:
      nameValuePair (profileUser name) {
        isSystemUser = true;
        group = profileUser name;
        home = "/var/lib/ezcage/${name}";
      }) cfg.profiles;

    users.groups = {
      ezcage = { };
    } // mapAttrs' (name: _: nameValuePair (profileUser name) { }) cfg.profiles;
  };
}
