#!/usr/bin/env bash
set -euo pipefail

: "${EZBOOT_BOOT_PATH:=/boot}"
: "${EZBOOT_KEY_NAME:=.ezboot.key}"
: "${EZBOOT_LUKS_NAME:=}"
: "${EZBOOT_MASTER_KEY:=}"

# Flags override whatever came from the environment (i.e. from NixOS's
# wrapProgram --set), so this script works standalone - with no NixOS
# module involved at all - as long as you're root on a system with LUKS,
# systemd, and cryptsetup: pass everything explicitly via flags instead
# of relying on anything being baked in at build time. Flags can appear
# anywhere in the argument list; positional args (the command and its own
# arguments) are collected in order into ARGS.
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --luks-name) EZBOOT_LUKS_NAME="$2"; shift 2 ;;
    --boot-path) EZBOOT_BOOT_PATH="$2"; shift 2 ;;
    --key-name) EZBOOT_KEY_NAME="$2"; shift 2 ;;
    --master-key) EZBOOT_MASTER_KEY="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

KEYFILE="${EZBOOT_BOOT_PATH}/${EZBOOT_KEY_NAME}"
EZBOOT_LUKS_DEVICE=""

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ezboot: must be run as root" >&2
    exit 1
  fi
}

# Discovers the raw underlying LUKS device for the already-open mapping
# EZBOOT_LUKS_NAME (e.g. /dev/nvme0n1p2 for /dev/mapper/rootfs), by
# parsing `cryptsetup status`. This happens entirely at shell runtime,
# not Nix evaluation time, so it can't create the same "reads back what
# it also writes" circular dependency that ruled out deriving this from
# boot.initrd.luks.devices in the Nix module - it just needs the LUKS
# device to already be open, which it always is by the time this script
# runs (on the fully booted system).
require_device() {
  if [ -z "$EZBOOT_LUKS_NAME" ]; then
    echo "ezboot: no LUKS device name configured (check services.ezboot.luksName, or pass --luks-name)" >&2
    exit 1
  fi

  local status_output
  if ! status_output="$(cryptsetup status "$EZBOOT_LUKS_NAME" 2>/dev/null)"; then
    echo "ezboot: LUKS mapping '$EZBOOT_LUKS_NAME' is not active" >&2
    exit 1
  fi

  EZBOOT_LUKS_DEVICE="$(awk '$1=="device:" {print $2}' <<< "$status_output")"

  if [ -z "$EZBOOT_LUKS_DEVICE" ] || [ ! -b "$EZBOOT_LUKS_DEVICE" ]; then
    echo "ezboot: could not determine the underlying device for LUKS mapping '$EZBOOT_LUKS_NAME'" >&2
    exit 1
  fi
}

require_master_key_path() {
  if [ -z "$EZBOOT_MASTER_KEY" ]; then
    echo "ezboot: no master key path configured (services.ezboot.masterKeyPath, or pass --master-key)" >&2
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
usage: ezboot [flags] <command>

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

flags (override whatever came from the environment; can appear anywhere,
before or after the command):
  --luks-name NAME          boot.initrd.luks.devices entry / mapper name
  --boot-path PATH          mountpoint of the unencrypted boot partition
  --key-name NAME           filename of the temporary key on that partition
  --master-key PATH         path to the permanent master key file

These flags are what let this script run standalone on any system with
LUKS, systemd, and cryptsetup - not just via the NixOS module, which
normally supplies all of this by setting environment variables instead.
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
