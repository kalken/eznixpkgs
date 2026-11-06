{ config, options, lib, pkgs, ... }:
let
  cfg = config.programs.ezcage;

  # Also used as a nix-darwin module (darwinModules in flake.nix). macOS has no
  # cage users, groups or network namespaces: the cage runs as you.
  isNixOS = options ? systemd;
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
        description = "Paths the cage can read and write. Every `.git` inside them stays read-only, unless `git` is set.";
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
      mainGroup = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "eznix";
        description = ''
          Main group the cage runs with, so new files get this group.
          Default: the cage user's own group.
        '';
      };
      umask = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "0002";
        description = "Umask for the cage. `0002` makes new files group-writable.";
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
      git = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Let the cage write `.git` folders, so it can commit (and push, with
          `sshAgent`). It can then run commands as you, outside the cage,
          through git hooks or `.git/config`.
        '';
      };
      sshAgent = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Let the cage use your SSH agent, for example for `git push`. It can
          then sign as you, though it still can't read the keys.
        '';
      };
      signalAll = mkOption {
        type = types.bool;
        default = false;
        description = ''
          macOS only. Let the cage signal any process of yours, also one it
          did not start, for example to stop a server started outside it. It
          can then stop anything you run.
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
    [ "--name" name ]
    ++ optionals isNixOS [ "--user" (profileUser name) ]
    ++ concatMap (x: [ "--rw" x ]) p.readWrite
    ++ concatMap (x: [ "--ro" x ]) p.readOnly
    ++ concatMap (g: [ "--group" g ]) p.groups
    ++ optionals (p.mainGroup != null) [ "--main-group" p.mainGroup ]
    ++ optionals (p.umask != null) [ "--umask" p.umask ]
    ++ optionals (p.netns != null) [ "--netns" p.netns ]
    ++ optional p.offline "--offline"
    ++ optional (p.nix == true) "--nix"
    ++ optional (p.nix == false) "--no-nix"
    ++ optional p.sshAgent "--ssh-agent"
    ++ optional p.git "--git"
    ++ optional p.signalAll "--signal-all"
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

  config = mkIf cfg.enable ({
    assertions = map (name: {
      assertion = builtins.match "[A-Za-z0-9_-]+" name != null && stringLength (profileUser name) <= 32;
      message = "programs.ezcage.profiles.${name}: the name may only contain letters, digits, '_' and '-', and be at most 25 characters.";
    }) (attrNames cfg.profiles) ++ [{
      # nix-darwin with nix.enable off (Nix managed elsewhere) forbids reading nix.settings
      assertion = !(config.nix.enable or true)
        || !(any (u: u == "ezcage" || u == "@ezcage" || hasPrefix "ezcage-" u || hasPrefix "@ezcage-" u)
          (config.nix.settings.trusted-users or [ ]));
      message = "programs.ezcage: cage users must not be in nix.settings.trusted-users; they could add binary caches or unsigned store paths.";
    }] ++ optionals (!isNixOS) (map (name: {
      assertion = cfg.profiles.${name}.groups == [ ] && cfg.profiles.${name}.mainGroup == null
        && cfg.profiles.${name}.netns == null;
      message = "programs.ezcage.profiles.${name}: groups, mainGroup and netns are not supported on macOS.";
    }) (attrNames cfg.profiles)) ++ optionals isNixOS (map (name: {
      assertion = !cfg.profiles.${name}.signalAll;
      message = "programs.ezcage.profiles.${name}: signalAll is only supported on macOS, since the cage runs as another user there.";
    }) (attrNames cfg.profiles));

    environment.systemPackages = [ cfg.package ];

    # One argument per line; ezcage reads them back with mapfile
    environment.etc = mapAttrs' (name: p:
      nameValuePair "ezcage/profiles/${name}" {
        text = concatStringsSep "\n" (profileArgs name p) + "\n";
      }) cfg.profiles;
  } // (if isNixOS then {
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
  } else { }));
}
