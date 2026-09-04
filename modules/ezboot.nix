{ config, lib, pkgs, utils, ... }:

with lib;

let
  cfg = config.services.ezboot;

  targetLuksName = cfg.luksName;

  bootFs = config.fileSystems.${cfg.bootPath} or null;

  keyFilePath = "${cfg.bootPath}/${cfg.keyFileName}";

  # Mounts the boot partition and stages the temp key for the LUKS unlock
  # step (keyFile = "/ezboot.key"). Used by the classic stage-1 path below.
  # Full store paths so Nix's closure scanner picks these up.
  stageKeyCommands = ''
    ${pkgs.coreutils}/bin/mkdir -p /ezboot-boot
    if ${pkgs.util-linux}/bin/mount -t ${bootFs.fsType} -o ro ${bootFs.device} /ezboot-boot 2>/dev/null; then
      if [ -f /ezboot-boot/${cfg.keyFileName} ]; then
        ${pkgs.coreutils}/bin/cp /ezboot-boot/${cfg.keyFileName} /ezboot.key
        ${pkgs.coreutils}/bin/chmod 600 /ezboot.key
      fi
      ${pkgs.util-linux}/bin/umount /ezboot-boot
    fi
  '';

  # Same as stageKeyCommands, for the systemd stage-1 unit below. Bare
  # command names (script= supplies the closure/PATH, matching nixpkgs's
  # own cryptsetup-clevis pattern) and unguarded, since this unit runs
  # independently and can fail loudly.
  stageKeyScriptText = ''
    set -x
    mkdir -p /ezboot-boot
    mount -t ${bootFs.fsType} -o ro ${bootFs.device} /ezboot-boot
    if [ -f /ezboot-boot/${cfg.keyFileName} ]; then
      cp /ezboot-boot/${cfg.keyFileName} /ezboot.key
      chmod 600 /ezboot.key
    fi
    umount /ezboot-boot
  '';

  ezbootPackage = cfg.package.override {
    luksName = cfg.luksName;
    bootPath = cfg.bootPath;
    keyFileName = cfg.keyFileName;
    masterKeyPath = cfg.masterKeyPath;
  };
in {
  options.services.ezboot = {
    enable = mkEnableOption "ezboot one-time LUKS boot-key unlock";

    luksName = mkOption {
      type = types.str;
      description = ''
        Name of the `boot.initrd.luks.devices` entry to target (must be set
        explicitly, e.g. matching your own
        `boot.initrd.luks.devices."<name>" = { device = ...; };`
        declaration). This can't be auto-detected: doing so would require
        reading the keys of an option this module also writes into, which
        is circular and fails with "infinite recursion". The raw device
        path itself is never needed here - the `ezboot` command discovers
        it at runtime from `cryptsetup status <luksName>` (the mapping is
        always already open by the time it runs), rather than needing it
        baked in at build time.
      '';
    };

    bootPath = mkOption {
      type = types.str;
      default = "/boot";
      description = ''
        Mountpoint of the unencrypted, pre-unlock-accessible boot partition,
        matching a `fileSystems.<bootPath>` entry (its device and fsType are
        read from there for both the running-system key location and the
        initrd's mount). Must not be a path under the encrypted root — e.g.
        on layouts where `/boot` is just a directory on the encrypted root
        and only `/boot/efi` is a separate unencrypted partition, set this
        to `"/boot/efi"` instead.
      '';
    };

    keyFileName = mkOption {
      type = types.str;
      default = ".ezboot.key";
      description = "Filename of the temporary key placed on the boot partition.";
    };

    masterKeyPath = mkOption {
      type = types.str;
      default = "/var/lib/ezboot/master.key";
      description = ''
        Path on the encrypted root filesystem for the permanent master key.
        Generated once with `ezboot init-master-key`, it authorizes adding
        and removing temporary keys without prompting for a passphrase on
        every reboot.
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.ezboot;
      description = "The ezboot package to use.";
    };

    rebootAfterUpgrade = mkOption {
      type = types.nullOr (types.enum [ "onkernelchange" "onchange" ]);
      default = null;
      example = "onkernelchange";
      description = ''
        Automatically reboot via ezboot after system.autoUpgrade applies
        an update, using the matching `ezboot reboot` mode:
        "onkernelchange" only reboots if the running kernel changed;
        "onchange" also reboots when the kernel-modules or initrd changed,
        even if the kernel version didn't (e.g. a cryptsetup/busybox/etc.
        update embedded in the initrd, or an initrd-affecting option
        change) - those only take effect after a reboot too, just without
        an immediate kernel version bump forcing the issue. `null` (the
        default) disables this entirely. Requires
        system.autoUpgrade.enable = true and
        system.autoUpgrade.allowReboot = false (ezboot handles the reboot
        instead).
      '';
    };

    waitForUnits = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "ezproton.service" ];
      description = ''
        Extra systemd unit names for rebootAfterUpgrade to wait for
        (added to ezboot-auto-reboot.service's `after`) before checking
        whether a reboot is needed. Other post-upgrade hooks - e.g.
        services.ezproton with afterAutoUpgrade = true - become eligible
        to start at essentially the same moment nixos-upgrade.service
        finishes, which is also exactly when this module's own reboot
        check fires; without an explicit ordering between them they race,
        and a reboot could interrupt one of them mid-run. This is just an
        ordering hint: it doesn't require or start units that wouldn't
        otherwise run as part of the same upgrade.
      '';
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      # A typo'd luksName isn't cross-checked here (would be circular);
      # it instead surfaces as NixOS's own "option ... is used but not
      # defined" error.
      assertions = [
        {
          assertion = bootFs != null;
          message = "services.ezboot: fileSystems.\"${cfg.bootPath}\" must be configured (services.ezboot.bootPath = \"${cfg.bootPath}\")";
        }
      ];

      environment.systemPackages = [ ezbootPackage ];

      systemd.tmpfiles.rules = [
        "d ${builtins.dirOf cfg.masterKeyPath} 0700 root root -"
      ];
    })

    (mkIf (cfg.enable && bootFs != null) {
      # Force-loaded, not hotplug-only (availableKernelModules) - a plain
      # `mount` doesn't trigger hotplug loading. vfat also needs an NLS
      # codepage module to mount at all.
      boot.initrd.kernelModules = [ bootFs.fsType ]
        ++ optionals (bootFs.fsType == "vfat") [ "nls_cp437" "nls_iso8859-1" ];

      # Fields are always present, only their values are conditional -
      # making presence itself conditional causes infinite recursion via
      # nixpkgs's own systemd-stage-1 assertion on preOpenCommands.
      boot.initrd.luks.devices.${targetLuksName} = {
        keyFile = "/ezboot.key";
        fallbackToPassword = !config.boot.initrd.systemd.enable;
        preOpenCommands = if config.boot.initrd.systemd.enable then "" else stageKeyCommands;
      };

      # Ignored under classic stage 1, so safe to declare unconditionally.
      # Ordered against the specific systemd-cryptsetup instance (always
      # runs) rather than cryptsetup-pre.target (not guaranteed activated).
      boot.initrd.systemd.services.ezboot-stage-key = {
        description = "Stage temporary ezboot LUKS key";
        wantedBy = [ "systemd-cryptsetup@${utils.escapeSystemdPath targetLuksName}.service" ];
        before = [
          "systemd-cryptsetup@${utils.escapeSystemdPath targetLuksName}.service"
          "initrd-switch-root.target"
          "shutdown.target"
        ];
        # Needs the boot fs module loaded and the device symlink present
        # before mounting (both confirmed necessary via live testing).
        wants = [ "${utils.escapeSystemdPath bootFs.device}.device" ];
        after = [
          "systemd-modules-load.service"
          "${utils.escapeSystemdPath bootFs.device}.device"
        ];
        # Without this, the implicit early-boot barrier ordering would
        # delay this unit until after root is already unlocked.
        unitConfig.DefaultDependencies = false;
        script = stageKeyScriptText;
        serviceConfig = {
          Type = "oneshot";
        };
      };

      # Once the system has booted (however it unlocked root), remove any
      # leftover temporary key and its LUKS slot.
      systemd.services.ezboot-cleanup = {
        description = "Remove temporary ezboot LUKS key after successful boot";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        unitConfig = {
          ConditionPathExists = keyFilePath;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${ezbootPackage}/bin/ezboot remove-key";
        };
      };
    })

    (mkIf (cfg.enable && cfg.rebootAfterUpgrade != null) {
      assertions = [
        {
          assertion = config.system.autoUpgrade.enable;
          message = "services.ezboot.rebootAfterUpgrade requires system.autoUpgrade.enable = true";
        }
        {
          assertion = !config.system.autoUpgrade.allowReboot;
          message = "services.ezboot.rebootAfterUpgrade reboots via ezboot itself; set system.autoUpgrade.allowReboot = false to avoid a conflicting plain reboot";
        }
      ];

      # Chain our own reboot-if-needed check onto the upgrade service,
      # instead of using system.autoUpgrade.allowReboot's plain reboot.
      systemd.services.nixos-upgrade.unitConfig.OnSuccess = [ "ezboot-auto-reboot.service" ];

      systemd.services.ezboot-auto-reboot = {
        description = "Reboot via ezboot if the last system upgrade requires it";
        # waitForUnits lets other post-upgrade hooks finish first instead
        # of racing this one.
        after = [ "nixos-upgrade.service" ] ++ cfg.waitForUnits;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${ezbootPackage}/bin/ezboot reboot ${cfg.rebootAfterUpgrade}";
        };
      };
    })
  ];
}
