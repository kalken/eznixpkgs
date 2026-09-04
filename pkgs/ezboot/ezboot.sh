#!/usr/bin/env bash
set -euo pipefail

: "${EZBOOT_BOOT_PATH:=/boot}"
: "${EZBOOT_KEY_NAME:=.ezboot.key}"
: "${EZBOOT_LUKS_DEVICE:=}"
: "${EZBOOT_MASTER_KEY:=}"

KEYFILE="${EZBOOT_BOOT_PATH}/${EZBOOT_KEY_NAME}"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ezboot: must be run as root" >&2
    exit 1
  fi
}

require_device() {
  if [ -z "$EZBOOT_LUKS_DEVICE" ] || [ ! -b "$EZBOOT_LUKS_DEVICE" ]; then
    echo "ezboot: no LUKS device configured (check services.ezboot.luksName)" >&2
    exit 1
  fi
}

require_master_key_path() {
  if [ -z "$EZBOOT_MASTER_KEY" ]; then
    echo "ezboot: no master key path configured (services.ezboot.masterKeyPath)" >&2
    exit 1
  fi
}

cmd_init_master_key() {
  require_root
  require_device
  require_master_key_path

  if [ -e "$EZBOOT_MASTER_KEY" ]; then
    echo "ezboot: master key already exists at $EZBOOT_MASTER_KEY" >&2
    echo "ezboot: to regenerate it, run 'ezboot remove-master-key' first" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$EZBOOT_MASTER_KEY")"
  chmod 700 "$(dirname "$EZBOOT_MASTER_KEY")"

  umask 077
  head -c 256 /dev/urandom > "$EZBOOT_MASTER_KEY"
  chmod 600 "$EZBOOT_MASTER_KEY"

  # cryptsetup can take real time (PBKDF cost), so an interrupt (Ctrl+C)
  # can land after the slot write has already durably completed but
  # before the process reports success. Always attempt to remove the slot
  # (self-verifying, so harmless if it was never actually added) before
  # deleting the file - otherwise an interrupt at the wrong moment leaves
  # an orphaned slot with no file to identify or clean it up by later.
  cleanup_init_master_key() {
    cryptsetup luksRemoveKey "$EZBOOT_LUKS_DEVICE" "$EZBOOT_MASTER_KEY" 2>/dev/null || true
    rm -f "$EZBOOT_MASTER_KEY"
  }
  trap cleanup_init_master_key ERR INT TERM

  echo "ezboot: adding master key to $EZBOOT_LUKS_DEVICE (existing passphrase required)"
  cryptsetup luksAddKey "$EZBOOT_LUKS_DEVICE" "$EZBOOT_MASTER_KEY"
  trap - ERR INT TERM

  echo "ezboot: master key installed at $EZBOOT_MASTER_KEY"
}

cmd_reboot() {
  require_root
  require_device
  require_master_key_path

  if [ ! -d "$EZBOOT_BOOT_PATH" ]; then
    echo "ezboot: boot path '$EZBOOT_BOOT_PATH' does not exist" >&2
    exit 1
  fi

  if [ ! -f "$EZBOOT_MASTER_KEY" ]; then
    echo "ezboot: no master key found at $EZBOOT_MASTER_KEY, run 'ezboot init-master-key' first" >&2
    exit 1
  fi

  if [ -e "$KEYFILE" ]; then
    echo "ezboot: a temporary key already exists at $KEYFILE" >&2
    echo "ezboot: a reboot is likely already pending; if not, run 'ezboot remove-key' first" >&2
    exit 1
  fi

  # See cleanup_init_master_key for why this also tries luksRemoveKey
  # first: an interrupt can land after the slot write already completed
  # durably but before the process reports success, leaving an orphaned
  # slot if we only ever delete the file.
  cleanup_reboot() {
    cryptsetup luksRemoveKey "$EZBOOT_LUKS_DEVICE" "$KEYFILE" 2>/dev/null || true
    rm -f "$KEYFILE"
  }
  trap cleanup_reboot ERR INT TERM

  echo "ezboot: generating temporary key at $KEYFILE"
  umask 077
  head -c 256 /dev/urandom > "$KEYFILE"
  chmod 600 "$KEYFILE"

  echo "ezboot: adding temporary key to $EZBOOT_LUKS_DEVICE"
  cryptsetup luksAddKey --key-file "$EZBOOT_MASTER_KEY" "$EZBOOT_LUKS_DEVICE" "$KEYFILE"

  trap - ERR INT TERM
  sync

  echo "ezboot: temporary key installed, rebooting now"
  systemctl reboot
}

cmd_reboot_if_needed() {
  local mode="$1"
  local booted current
  booted="$(readlink -f /run/booted-system/kernel)"
  current="$(readlink -f /run/current-system/kernel)"

  if [ "$mode" = "onchange" ]; then
    booted="$booted $(readlink -f /run/booted-system/kernel-modules) $(readlink -f /run/booted-system/initrd)"
    current="$current $(readlink -f /run/current-system/kernel-modules) $(readlink -f /run/current-system/initrd)"
  fi

  if [ "$booted" = "$current" ]; then
    echo "ezboot: no reboot needed"
    exit 0
  fi

  echo "ezboot: reboot needed"
  cmd_reboot
}

cmd_remove_key() {
  require_root
  require_device

  if [ ! -f "$KEYFILE" ]; then
    echo "ezboot: no temporary key found at $KEYFILE, nothing to remove"
    exit 0
  fi

  echo "ezboot: removing temporary key from $EZBOOT_LUKS_DEVICE"
  cryptsetup luksRemoveKey "$EZBOOT_LUKS_DEVICE" "$KEYFILE"
  rm -f "$KEYFILE"

  echo "ezboot: temporary key removed"
}

cmd_remove_master_key() {
  require_root
  require_device
  require_master_key_path

  if [ ! -f "$EZBOOT_MASTER_KEY" ]; then
    echo "ezboot: no master key found at $EZBOOT_MASTER_KEY, nothing to remove"
    exit 0
  fi

  echo "ezboot: removing master key from $EZBOOT_LUKS_DEVICE"
  cryptsetup luksRemoveKey "$EZBOOT_LUKS_DEVICE" "$EZBOOT_MASTER_KEY"
  rm -f "$EZBOOT_MASTER_KEY"

  echo "ezboot: master key removed; run 'ezboot init-master-key' to add a new one"
}

cmd_help() {
  cat <<'USAGE'
usage: ezboot <command>

commands:
  reboot                    generate a temporary key, add it to the LUKS
                            device via the master key, and reboot immediately
  reboot onkernelchange     like reboot, but only if the running kernel has
                            changed since this boot
  reboot onchange           like reboot, but if the running kernel,
                            kernel-modules, or initrd has changed since this
                            boot
  init-master-key           generate the permanent master key and add it to
                            the LUKS device (prompts for an existing
                            passphrase)
  remove-key                remove a leftover temporary key and its LUKS slot
  remove-master-key         remove the master key and its LUKS slot (you'll
                            need to run init-master-key again afterwards)
USAGE
}

case "${1:-}" in
  reboot)
    case "${2:-}" in
      "")
        cmd_reboot
        ;;
      onkernelchange|onchange)
        cmd_reboot_if_needed "$2"
        ;;
      *)
        echo "ezboot: unknown reboot mode '$2' (expected onkernelchange or onchange)" >&2
        exit 1
        ;;
    esac
    ;;
  init-master-key)
    cmd_init_master_key
    ;;
  remove-key)
    cmd_remove_key
    ;;
  remove-master-key)
    cmd_remove_master_key
    ;;
  ""|help|-h|--help)
    cmd_help
    ;;
  *)
    cmd_help >&2
    exit 1
    ;;
esac
