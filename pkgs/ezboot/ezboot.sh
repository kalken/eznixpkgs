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
  if [ -z "$EZBOOT_LUKS_DEVICE" ]; then
    echo "ezboot: no LUKS device configured (check services.ezboot.luksName and boot.initrd.luks.devices)" >&2
    exit 1
  fi
  if [ ! -b "$EZBOOT_LUKS_DEVICE" ]; then
    echo "ezboot: LUKS device '$EZBOOT_LUKS_DEVICE' not found" >&2
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
    echo "ezboot: to regenerate it, first remove its LUKS slot (cryptsetup luksRemoveKey $EZBOOT_LUKS_DEVICE $EZBOOT_MASTER_KEY) and delete the file" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$EZBOOT_MASTER_KEY")"
  chmod 700 "$(dirname "$EZBOOT_MASTER_KEY")"

  umask 077
  head -c 256 /dev/urandom > "$EZBOOT_MASTER_KEY"
  chmod 600 "$EZBOOT_MASTER_KEY"

  trap 'rm -f "$EZBOOT_MASTER_KEY"' ERR
  echo "ezboot: adding master key to $EZBOOT_LUKS_DEVICE (existing passphrase required)"
  cryptsetup luksAddKey "$EZBOOT_LUKS_DEVICE" "$EZBOOT_MASTER_KEY"
  trap - ERR

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

  trap 'rm -f "$KEYFILE"' ERR

  echo "ezboot: generating temporary key at $KEYFILE"
  umask 077
  head -c 256 /dev/urandom > "$KEYFILE"
  chmod 600 "$KEYFILE"

  echo "ezboot: adding temporary key to $EZBOOT_LUKS_DEVICE"
  cryptsetup luksAddKey --key-file "$EZBOOT_MASTER_KEY" "$EZBOOT_LUKS_DEVICE" "$KEYFILE"

  trap - ERR
  sync

  echo "ezboot: temporary key installed, rebooting now"
  systemctl reboot
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

case "${1:-}" in
  ""|reboot)
    cmd_reboot
    ;;
  init-master-key)
    cmd_init_master_key
    ;;
  remove-key)
    cmd_remove_key
    ;;
  *)
    echo "usage: ezboot [reboot|init-master-key|remove-key]" >&2
    exit 1
    ;;
esac
