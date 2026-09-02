{ config, lib, pkgs, utils, ... }:

with lib;

let
  cfg = config.services.ezboot;

  targetLuksName = cfg.luksName;

  bootFs = config.fileSystems.${cfg.bootPath} or null;

  keyFilePath = "${cfg.bootPath}/${cfg.keyFileName}";

  # Mount the unencrypted boot partition and stage the temp key where the
  # LUKS unlock step (keyFile = "/ezboot.key") can read it, before that
  # device is opened. Shared between the classic and systemd stage 1
  # mechanisms below, which each hook it in differently. Commands are
  # referenced by full store path (rather than relying on $PATH) so Nix's
  # reference scanning pulls them into whichever initrd closure mechanism
  # picks this script up (extraUtils for the classic stage 1, storePaths
  # for systemd stage 1 below).
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

  # Same steps as stageKeyCommands, but unguarded and with `set -x`, and
  # using bare command names instead of full store paths - matching
  # nixpkgs's own cryptsetup-clevis-<name> script exactly, which relies on
  # `script = ''...'';` (rather than a manually built ExecStart) to wire up
  # both the closure (via the initrd's jobScripts mechanism) and a working
  # $PATH from boot.initrd.systemd.package. Referencing pkgs.util-linux's
  # own mount binary directly (the previous approach) doesn't work in this
  # environment - Type=exec reported it couldn't be found at all. Used only
  # for the systemd-stage-1 unit below, which runs independently
  # (wantedBy=, not requiredBy=) so it's safe to let it fail loudly rather
  # than silently as stageKeyCommands does for preOpenCommands.
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
    luksDevice = cfg.luksDevice;
    bootPath = cfg.bootPath;
    keyFileName = cfg.keyFileName;
    masterKeyPath = cfg.masterKeyPath;
  };

  # When rebootOnlyOnKernelChange is false, also compare kernel-modules and
  # initrd, since those only take effect after a reboot too even without a
  # kernel version bump.
  bootedExtraPaths = optionalString (!cfg.rebootOnlyOnKernelChange)
    " $(readlink -f /run/booted-system/kernel-modules) $(readlink -f /run/booted-system/initrd)";
  currentExtraPaths = optionalString (!cfg.rebootOnlyOnKernelChange)
    " $(readlink -f /run/current-system/kernel-modules) $(readlink -f /run/current-system/initrd)";
in {
  options.services.ezboot = {
    enable = mkEnableOption "ezboot one-time LUKS boot-key unlock";

    luksName = mkOption {
      type = types.str;
      description = ''
        Name of the `boot.initrd.luks.devices` entry to target (must be set
        explicitly). This can't be auto-detected: doing so would require
        reading the keys of an option this module also writes into,
        which is circular and fails with "infinite recursion".
      '';
    };

    luksDevice = mkOption {
      type = types.str;
      description = ''
        Raw device path of the LUKS-encrypted partition, matching
        `boot.initrd.luks.devices.<luksName>.device` exactly (e.g.
        "/dev/disk/by-label/rootfs_luks"). Must be supplied directly here
        rather than read back from boot.initrd.luks.devices, since this
        module also writes into that same option - reading it back would
        be circular for the same reason luksName can't be auto-detected.
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

    rebootAfterUpgrade = mkEnableOption ''
      automatically rebooting via ezboot after system.autoUpgrade applies an
      update that actually requires a reboot. Requires
      system.autoUpgrade.enable = true and
      system.autoUpgrade.allowReboot = false (ezboot handles the reboot
      instead)
    '';

    rebootOnlyOnKernelChange = mkOption {
      type = types.bool;
      default = true;
      description = ''
        When rebootAfterUpgrade is enabled, only reboot if the running
        kernel itself changed. If false, also reboot when the kernel
        modules or initrd changed, even if the kernel version didn't
        (e.g. a cryptsetup/busybox/etc. update embedded in the initrd, or
        an initrd-affecting option change) — those only take effect after
        a reboot too, but on their own don't require one immediately.
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
      # Note: we deliberately don't cross-check luksName/luksDevice against
      # config.boot.initrd.luks.devices here - reading that back would be
      # circular for the same reason described on the luksDevice option. A
      # typo'd luksName will instead surface as NixOS's own standard "the
      # option `boot.initrd.luks.devices.<name>.device' is used but not
      # defined" error, since ezboot's contribution to a nonexistent name
      # creates a new device entry with no `device` field.
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
      # kernelModules (force-loaded at initrd startup), not
      # availableKernelModules (only auto-loaded via hotplug/hardware
      # detection, which a plain `mount` call doesn't trigger) - confirmed
      # via a live initrd debug shell that `mount -t vfat` failed with
      # "wrong fs type" even with the module present, until it was loaded
      # explicitly. vfat also needs an NLS codepage module to actually
      # mount, which was completely absent from the initrd (modprobe
      # reported it not found, not just unloaded).
      boot.initrd.kernelModules = [ bootFs.fsType ]
        ++ optionals (bootFs.fsType == "vfat") [ "nls_cp437" "nls_iso8859-1" ];

      # Always contribute the same fields here, with only their values (not
      # their presence) depending on config.boot.initrd.systemd.enable.
      # Making the presence of preOpenCommands/fallbackToPassword itself
      # conditional caused an infinite recursion: nixpkgs's own luksroot.nix
      # asserts (when systemd stage 1 is enabled) that every device's
      # preOpenCommands is "" - checking that requires resolving what this
      # module contributes here, which (with a conditional shape) required
      # resolving config.boot.initrd.systemd.enable again first - circular.
      boot.initrd.luks.devices.${targetLuksName} = {
        keyFile = "/ezboot.key";
        fallbackToPassword = !config.boot.initrd.systemd.enable;
        preOpenCommands = if config.boot.initrd.systemd.enable then "" else stageKeyCommands;
      };

      # systemd stage 1 ignores this whole option when
      # boot.initrd.systemd.enable is false, so it's safe to always declare
      # it unconditionally. Ordered directly against the specific
      # systemd-cryptsetup instance for our device (guaranteed to run, since
      # root can't unlock without it) rather than cryptsetup-pre.target -
      # After=/Before= relative to a target doesn't guarantee that target is
      # ever actually activated, only orders things if it is.
      boot.initrd.systemd.services.ezboot-stage-key = {
        description = "Stage temporary ezboot LUKS key";
        wantedBy = [ "systemd-cryptsetup@${utils.escapeSystemdPath targetLuksName}.service" ];
        before = [
          "systemd-cryptsetup@${utils.escapeSystemdPath targetLuksName}.service"
          "initrd-switch-root.target"
          "shutdown.target"
        ];
        # Needed so the boot fs kernel module (loaded via
        # boot.initrd.kernelModules) is actually available before this
        # unit tries to mount it - omitted from the initial port of
        # nixpkgs's cryptsetup-clevis-<name> pattern, which has the same
        # ordering for the same reason.
        #
        # Also wait for udev to have actually created the boot device's
        # symlink (confirmed live: mount failed with "can't lookup
        # blockdev" because /dev/disk/by-label/bootfs didn't exist yet).
        # Nothing else in the initrd needs /boot's device at all - it's
        # only mounted after switch-root as part of the real system - so
        # nothing else pulls this in; wants= is needed, not just after=.
        wants = [ "${utils.escapeSystemdPath bootFs.device}.device" ];
        after = [
          "systemd-modules-load.service"
          "${utils.escapeSystemdPath bootFs.device}.device"
        ];
        # Without this, systemd adds an implicit After= on the early-boot
        # barrier target - and since unlocking root is itself part of
        # reaching that target, this unit couldn't start until after the
        # unlock attempt regardless of the explicit before=/wantedBy=
        # above. Confirmed against nixpkgs's own cryptsetup-clevis-<name>
        # units, which solve the identical problem the same way.
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

    (mkIf (cfg.enable && cfg.rebootAfterUpgrade) {
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
        # nixos-upgrade.service itself: belt-and-suspenders, since
        # OnSuccess= already means this can't start until it has finished
        # (it's the event that triggers it), and that service's own
        # switch-to-configuration run is synchronous, so every restart it
        # directly causes has already completed by then too.
        #
        # waitForUnits: other post-upgrade hooks (e.g. services.ezproton
        # with afterAutoUpgrade = true) become eligible to start at
        # essentially the same moment nixos-upgrade.service finishes -
        # the same moment that triggers this unit via OnSuccess= - so
        # without this they'd race rather than run in sequence.
        after = [ "nixos-upgrade.service" ] ++ cfg.waitForUnits;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "ezboot-auto-reboot" ''
            set -eu
            booted="$(readlink -f /run/booted-system/kernel)${bootedExtraPaths}"
            current="$(readlink -f /run/current-system/kernel)${currentExtraPaths}"

            if [ "$booted" = "$current" ]; then
              echo "ezboot-auto-reboot: no reboot needed"
              exit 0
            fi

            echo "ezboot-auto-reboot: reboot needed, rebooting via ezboot"
            exec ${ezbootPackage}/bin/ezboot
          '';
        };
      };
    })
  ];
}
