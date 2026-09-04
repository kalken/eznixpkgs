# ezboot

Unlocks a LUKS-encrypted root for exactly one reboot using a temporary
key file staged on the unencrypted boot partition, then removes both the
key and the LUKS slot once the system has booted successfully. Useful for
rebooting a remote machine with an encrypted root without anyone present
to type the passphrase.

## 🚀 Quick Start

```nix
{
  services.ezboot = {
    enable = true;
    luksName = "root"; # matches your own boot.initrd.luks.devices."root" declaration
  };
}
```

`luksName` must match an existing `boot.initrd.luks.devices` entry you've
already declared yourself (with its own `device = ...;`) — it can't be
auto-detected, since that would require reading the keys of an option
this module also writes into, which is circular in the Nix module system
and fails with "infinite recursion". The raw device path itself doesn't
need to be repeated separately, though: it's read directly from that same
`device = ...;` declaration (a different field than the ones this module
writes, so reading it is safe) and baked into the `ezboot` package.

Then, as root, generate the master key once (this is the only step that
prompts for an existing LUKS passphrase):

```
ezboot init-master-key
```

From then on, reboot with:

```
ezboot reboot
```

Running `ezboot` with no arguments prints usage instead of rebooting —
see [Commands](#-commands) below for the full list.

`bootPath` defaults to `/boot`, and can be overridden alongside everything
else:

```nix
{
  services.ezboot = {
    enable = true;
    luksName = "root";
    bootPath = "/boot";
  };
}
```

`bootPath` must point at a `fileSystems.<bootPath>` entry that is
unencrypted and readable before root is unlocked — its device and fsType
are read from there for both the running-system key location and the
initrd mount. On layouts where `/boot` is just a directory on the
encrypted root and only the ESP is separately mounted (common with GRUB),
set `bootPath = "/boot/efi";` instead — otherwise the key would be staged
somewhere the initrd can't read before root is even unlocked, defeating
the whole mechanism.

### Automatic reboot after upgrades

To also have the machine reboot itself after `system.autoUpgrade`
installs an update that needs one (e.g. a new kernel), on top of the
config above:

```nix
{
  system.autoUpgrade = {
    enable = true;
    allowReboot = false; # already the default - ezboot handles rebooting instead
  };

  services.ezboot.rebootAfterUpgrade = "onkernelchange";
}
```

This still requires `ezboot init-master-key` to have been run once
first — without a master key, the triggered `ezboot reboot onkernelchange`
call will just fail (and get logged), not fall back to prompting for a
passphrase, since nobody's there to answer it.

If you have other services that also hook into `nixos-upgrade.service`
(e.g. `services.ezproton` with `afterAutoUpgrade = true`), see
[Automatic reboot after system.autoUpgrade](#-automatic-reboot-after-systemautoupgrade)
below for `waitForUnits`, which makes sure they finish before the reboot
happens rather than racing it.

## 🛠 Commands

`ezboot` with no arguments (or `help`/`-h`/`--help`) prints this same
list rather than doing anything — you always have to name a command
explicitly.

| Command | Description |
|---------|-------------|
| `reboot` | Generate a temporary key, add it to the LUKS device via the master key, and reboot immediately. |
| `reboot onkernelchange` | Like `reboot`, but only if the running kernel has changed since this boot. |
| `reboot onchange` | Like `reboot`, but if the running kernel, kernel-modules, or initrd has changed since this boot. |
| `init-master-key` | Generate the permanent master key and add it to the LUKS device. Prompts for an existing passphrase — the only interactive step in normal use. |
| `remove-key` | Remove a leftover temporary key and its LUKS slot. Safe to run any time; a no-op if there's nothing to remove. This is also what the automatic post-boot cleanup service calls. |
| `remove-master-key` | Remove the master key and its LUKS slot. You'll need to run `init-master-key` again afterwards before `reboot` will work again. Kept separate from `remove-key` deliberately — the automatic cleanup service only ever calls `remove-key`, and must never touch the master key, or unattended reboots would break on the very next cycle. |

`rebootAfterUpgrade` calls `reboot onkernelchange` or `reboot onchange`
automatically, matching whichever value it's set to — you'd normally only
run these by hand to test the check itself.

## ✨ How it works

A one-time master key, generated with `ezboot init-master-key`, is added
as a permanent LUKS slot and stored on the encrypted root filesystem
(`services.ezboot.masterKeyPath`, `/var/lib/ezboot/master.key` by
default). Because it lives on the encrypted root, it's only readable once
the disk is already unlocked — but it lets `ezboot` add and remove
temporary keys without prompting for a passphrase on every reboot.

Running `ezboot reboot`:

1. Generates a random temporary key and writes it to the boot partition
   (e.g. `/boot/.ezboot.key`).
2. Adds it as a new LUKS key slot on the target device (`cryptsetup
   luksAddKey --key-file <master key>`), authorized by the master key —
   no interactive passphrase needed.
3. Reboots the machine immediately.

On the next boot, the initrd mounts the (unencrypted) boot partition
before attempting to unlock the target LUKS device, stages the key file
into the initrd's own tmpfs, and uses it to unlock root automatically. If
the key file isn't present or doesn't work, it falls back to the normal
passphrase prompt — `ezboot` never removes your ability to unlock the
disk manually. The exact mechanism differs depending on your initrd:

* **Classic (non-systemd) stage 1** (`boot.initrd.systemd.enable = false`):
  the key is staged via `boot.initrd.luks.devices.<name>.preOpenCommands`,
  with `fallbackToPassword = true` providing the passphrase fallback.
* **systemd stage 1** (`boot.initrd.systemd.enable = true`):
  `preOpenCommands` isn't supported there, so the key is staged by a
  dedicated unit (`ezboot-stage-key.service`) ordered directly before the
  `systemd-cryptsetup@<name>.service` instance for the target device.
  Password fallback is automatic on this path — no equivalent option is
  needed.

Both paths use `boot.initrd.luks.devices.<name>.keyFile` the same way.
Only the systemd stage 1 path has actually been verified end-to-end on
real hardware (including several rounds of live initrd debugging to get
unit ordering, kernel module loading, and device-availability timing
right — see the module source comments for the specifics). The classic
path uses an older, more established NixOS mechanism that predates all of
that, so it's expected to be less fragile, but it hasn't been exercised
in practice — treat it as unverified if you're relying on it.

Once the system reaches `multi-user.target`, a cleanup service runs
`ezboot remove-key`, which removes the temporary LUKS slot and deletes
the key file from the boot partition, restoring the system to a fully
passphrase-only state. This runs on any successful boot where a leftover
key is found, regardless of how root was actually unlocked.

If you change your mind before rebooting, or want to clean up manually
for any other reason, run `ezboot remove-key` yourself at any time — it's
a no-op if there's no temporary key to remove.

## 🔁 Automatic reboot after system.autoUpgrade

`services.ezboot.rebootAfterUpgrade` hooks into `system.autoUpgrade`
instead of its own `allowReboot`: after `nixos-upgrade.service` succeeds,
it compares the booted generation against the newly built one, and if a
reboot would actually change anything, runs the matching `ezboot reboot`
mode to reboot unattended. If nothing relevant changed, it does nothing.
See [Quick Start](#-quick-start) above for the minimal setup.

`rebootAfterUpgrade = "onkernelchange"` only reboots when the running
kernel itself changed. `"onchange"` also reboots on kernel-modules or
initrd-only changes (e.g. an updated cryptsetup/busybox inside the
initrd, or an initrd-affecting option change) — those only take effect
after a reboot too, just without an immediate kernel version bump forcing
the issue. `null` (the default) disables the feature entirely.

`allowReboot` defaults to `false` in NixOS already, so setting it in the
Quick Start example usually isn't strictly necessary — it's shown
explicitly there so that example is self-contained. The
`rebootAfterUpgrade` assertion still earns its keep despite the safe
default: it exists to catch someone who *has* set `allowReboot = true`
elsewhere (e.g. copied from another config) while also enabling
`rebootAfterUpgrade`, which would otherwise leave two competing reboot
mechanisms active without any warning.

**If you have other post-upgrade hooks** (e.g. `services.ezproton` with
`afterAutoUpgrade = true`), they become eligible to run at essentially
the same moment `nixos-upgrade.service` finishes — the same moment that
triggers ezboot's own reboot check — so without an explicit ordering
they'd race, and a reboot could interrupt one of them mid-run. List them
in `waitForUnits` so the reboot check waits for them first:

```nix
{
  services.ezboot.waitForUnits = [ "ezproton.service" ];
}
```

This only adds an ordering hint (`after=`) — it doesn't require or start
units that wouldn't otherwise run as part of the same upgrade.

## ⚙️ Options

| Option        | Type          | Default            | Description                                                                 |
|---------------|---------------|---------------------|-------------------------------------------------------------------------------|
| `enable`      | bool          | `false`             | Enable ezboot.                                                                |
| `luksName`    | str           | *(required)*        | Name of your existing `boot.initrd.luks.devices` entry to target. Must be set explicitly; the raw device path is read from that same entry's `device`, never needed here. |
| `bootPath`    | str           | `"/boot"`           | Mountpoint of the unencrypted, pre-unlock-accessible boot partition (must match a `fileSystems.<bootPath>` entry). Use `"/boot/efi"` if `/boot` itself is on the encrypted root. |
| `keyFileName` | str           | `".ezboot.key"`     | Filename of the temporary key placed on the boot partition.                  |
| `masterKeyPath` | str         | `"/var/lib/ezboot/master.key"` | Path on the encrypted root for the permanent master key.        |
| `package`     | package       | `pkgs.ezboot`        | The ezboot package to use.                                                    |
| `rebootAfterUpgrade` | `null \| "onkernelchange" \| "onchange"` | `null` | Reboot via the matching `ezboot reboot` mode after `system.autoUpgrade` applies an update that needs one. `null` disables it. |
| `waitForUnits` | list of str | `[]`           | Extra systemd units for the reboot check to wait for (`after=`), e.g. other post-upgrade hooks like `ezproton.service`. |

## ⚠️ Security notes

* The master key is a standing, non-interactive credential that can add or
  remove LUKS key slots on its own. It's protected by disk encryption
  (unreadable until root is already unlocked) and filesystem permissions
  (`0600`, root-owned), but treat it as root-equivalent — it should never
  be copied off the encrypted root or onto the boot partition.
* The temporary key only exists between running `ezboot` and the next
  successful boot — it's removed automatically afterwards. If you decide
  not to reboot after all, or the machine never comes back up, run
  `ezboot remove-key` to remove the leftover key and its LUKS slot
  manually (this is the same command the automatic cleanup service uses).
* Anyone with access to the boot partition while the key is staged there
  (i.e. between running `ezboot` and the next successful boot) can use it
  to unlock the disk. This is inherent to the "key on unencrypted boot
  partition" technique — only use `ezboot` when that window is acceptable.
* The boot partition's filesystem type is force-loaded in the initrd via
  `boot.initrd.kernelModules` (not `availableKernelModules` — that only
  loads on-demand via hotplug/hardware detection, which a plain `mount`
  call doesn't trigger the same way block-device drivers do), based on
  `fileSystems.<bootPath>`. For `vfat` specifically, the NLS codepage
  modules it needs to actually mount (`nls_cp437`, `nls_iso8859-1`) are
  force-loaded too — confirmed necessary via live testing, not just
  present-but-unused.
* If the boot partition is `vfat` (a typical EFI System Partition), file
  permissions (`chmod 600` on the temp key) don't really apply — FAT has no
  Unix permission bits, so actual confidentiality depends on that
  filesystem's mount options (`fmask`/`dmask`), which commonly default to
  world-readable. Check yours, and tighten them
  (`fileSystems.<bootPath>.options = [ "fmask=0137" "dmask=0027" ];`) if so
  — otherwise any local user, not just someone with physical/console
  access, could read the temp key during its exposure window.
* To rotate the master key: run `ezboot remove-master-key` (removes its
  LUKS slot and deletes the file), then `ezboot init-master-key` again.
