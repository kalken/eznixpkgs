# ezcage

> **Status: implemented, being tested on ezberry.** This file records the design and
> the decisions made so far. Turn it into the normal module documentation
> once it has been used for a while.

`ezcage` runs a program so that it sees only the paths you grant it. Everything
else on disk does not exist for it. Main use: AI agents such as Claude Code that
may touch one directory (for example `/etc/nixos`) and nothing else.

A cage uses the **host network** by default, since most programs (Claude
included) need it. `--offline` gives no network at all; `--netns` puts the
cage in an eznetns namespace with its DNS, so it can't reach the LAN or the
host's services. eznetns needs no changes: `ezcage` uses the files eznetns
already creates.

```bash
ezcage --rw ~/photos --offline -- ./sort.sh             # no network
ezcage --rw ~/project -- claude                         # host network
ezcage --netns claude --rw /etc/nixos -- claude         # network through the claude netns
ezcage nixos                                            # profile
```

## Why this design

Approaches considered:

| Approach | Verdict |
|---|---|
| Everything as an `eznetns` command | ties disk lockdown to networks; can't cage something without one |
| `ezcage` + a `cage` command in eznetns | two repos and two flag sets to keep in sync, for nothing `ezcage` can't do itself |
| **`ezcage --netns <name>`** | **chosen**: one tool, eznetns unchanged |
| Anthropic `srt` | read access is a denylist, network is a proxy. Not hard limits |
| microVM (microvm.nix) | strongest (own kernel), heavier. Later, for untrusted AI |

## ezcage

A wrapper around `sudo systemd-run --pty` that builds a transient unit.

```
ezcage [--rw PATH]... [--ro PATH]... [--name NAME] [--workdir DIR]
       [--netns NAME | --offline] [--nix | --no-nix]
       -- COMMAND [ARGS]...
ezcage PROFILE
```

- **Empty root**: `RootDirectory=/run/ezcage/root` (an empty directory ezcage
  creates), `TemporaryFileSystem=/`, `MountAPIVFS=yes`, `PrivateTmp=yes`.
  Not `/var/empty`: it is immutable on NixOS, so systemd can't create mount
  points in it (unit fails with `226/NAMESPACE`).
- **Always read-only**: `/nix/store`, `/run/current-system`, `/etc/static`, `/etc/ssl`,
  `/etc/passwd`, `/etc/group`, `/etc/hosts`.
- **Granted paths**: `--rw` → `BindPaths`, `--ro` → `BindReadOnlyPaths`.
- **User**: a static system user, never root, with `SupplementaryGroups=ezcage`.
  Profiles get their own `ezcage-<name>` user from the module; ad-hoc runs use
  the shared `ezcage` user.
  - Not `DynamicUser`: the random uid has no name inside the cage, and Node's
    `os.userInfo()` fails with `ENOENT` (Claude Code runs on Node). Transient
    users through `/run/userdb` were tried; systemd would not start a unit as
    one on ezberry (no nscd).
  - A stable, named uid also means files left in granted paths have a real owner.
- **Home**: `StateDirectory=ezcage/<name>`, set as `$HOME`; systemd gives it to
  the cage user. Kept across runs. Holds Claude's login and settings.
- **Network**:
  - **Default**: host network, with the host's `resolv.conf`/`nsswitch.conf`
    mounted. Most programs need network, so this is the default; the cage can
    then also reach the LAN and services on the host (localhost, router admin
    pages), and abstract Unix sockets (X11, some D-Bus).
  - **`--netns <name>`**: the eznetns namespace. See [Network namespace](#network-namespace).
    The better choice for AI on machines that have one.
  - **`--offline`**: `PrivateNetwork=yes`, loopback only. Also isolates
    abstract Unix sockets.
- **Nix**: the daemon socket and `/etc/nix` are mounted, so `nix shell` and
  `nix run` work and leave nothing installed. On by default; off with
  `--no-nix`, and off by default with `--netns` or `--offline` (`--nix` turns
  it back on).
  - The daemon builds as root in the host network (fixed-output derivations
    have network access), which would bypass `--netns` and `--offline`.
  - The cage user must not be in `trusted-users`, or it could add binary
    caches or unsigned store paths.
  - Big builds can fill the disk; a Nix bug would be a way out of the cage.
- **Hardening**:
  - `NoNewPrivileges`, `PrivateDevices`, `PrivateIPC`
  - `ProtectProc=invisible`, `ProcSubset=pid`
  - `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`
  - `SystemCallFilter=@system-service`, `RestrictNamespaces=yes`, `LockPersonality=yes`
  - `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK` (netlink for
    interface listing, it only sees the cage's own network namespace)

  - Not `MemoryDenyWriteExecute`: it breaks Node (Claude Code).
  - Not `PrivatePIDs`: together with `StateDirectory` it fails on systemd 260
    (`Failed to set up mount namespacing`). Not needed: the cage user differs
    from every other process owner, so `ProtectProc=invisible` already hides
    all of them (a cage sees about 4 processes, its own).

## Network namespace

`--netns claude` uses what eznetns already provides; eznetns is not changed:

| Unit setting | From eznetns |
|---|---|
| `NetworkNamespacePath=/run/netns/claude` | the namespace |
| `BindReadOnlyPaths=/etc/eznetns/claude/resolv.conf:/etc/resolv.conf` | its DNS servers |
| `BindReadOnlyPaths=/etc/eznetns/claude/nsswitch.conf:/etc/nsswitch.conf` | its lookup order |
| `BindsTo=` / `After=eznetns-claude.service` | cage runs only while the namespace is up |

- The namespace must be given as a unit setting. The unit is started by systemd
  (PID 1), which runs in the host network, so running `ezcage` inside
  `eznetns claude execute` would not put the cage in the namespace.
- **Only the DNS files are mounted, never the whole `/etc/eznetns/<name>/`.**
  That folder holds the WireGuard configs with private keys.
- The empty root has no `/run` or `/var`, so the host's systemd-resolved and
  nscd cannot be reached; lookups only use the netns `resolv.conf`.
- `netnsService` in `modules/eznetns.nix` mounts the same files; the only
  coupling is this file layout.
- **`eznetns <name> execute` runs its command as root.** Fine for your own
  shell, never for AI.

## Write access

The cage user has no rights on granted paths. Two ways to give them:

- **`--group GROUP`** (simplest, when the path already has a group with write
  access): the cage runs with that group as well (`SupplementaryGroups=`).
  Nothing on disk or in `/etc/group` changes; it applies to that run only.
  Tested on ezberry: `ezcage --group eznix --rw /etc/nixos -- claude` can
  write `/etc/nixos` (new files get group `eznix` from the setgid bit), `.git`
  stays read-only.
- **`--main-group GROUP` and `--umask 0002`** (profile options `mainGroup`,
  `umask`): the cage runs with GROUP as its main group (`Group=`) and umask
  `0002` (`UMask=`), so new files are `ezcage-<name>:GROUP` and group-writable
  (`0664`, directories `0775`), without a setgid bit or ACL. Running as your
  own user instead is not an option: without a PID namespace the cage could
  reach the whole disk through `/proc/<pid>/root` of your other processes.
- **An ACL** for the static group `ezcage`, which every cage runs with (profiles
  can grant their own `ezcage-<name>` user instead, which is tighter):

```bash
sudo setfacl -R -m g:ezcage:rwX -m d:g:ezcage:rwX -m d:u:kalken:rwX /etc/nixos
```

One shared group is safe: the mounts decide what a cage sees, the group only
passes the permission check on paths that are mounted into it. Profiles set the
ACL with `systemd.tmpfiles`.

- New files are owned by the cage user; the default ACL keeps you and the
  group in control.
- **`.git` is mounted read-only and left out of the ACL.** Otherwise git hooks
  written in the cage would run as you outside it. Claude edits, you commit.
- `ezcage` writes `safe.directory` into the cage home's `.gitconfig`, because git
  refuses repos owned by another user.
- `--ro` paths are read as "other": files must be world-readable or carry the
  ACL. `0600` files stay hidden.

## Module

```nix
programs.ezcage = {
  enable = true;                       # command, ezcage user and group
  profiles.nixos = {                   # run with: ezcage nixos
    command = "claude";
    groups = [ "eznix" ];              # may write /etc/nixos
    # mainGroup = "eznix";  umask = "0002";   # new files: group eznix, group-writable
    readWrite = [ "/etc/nixos" ];
    workDir = "/etc/nixos";
    # netns = "claude";  offline = true;  nix = false;  readOnly = [ ];  args = [ ];
    packages = [ pkgs.ripgrep ];       # tools on the cage's PATH
  };
};
```

- Each profile gets its own user `ezcage-<name>` and a home in
  `/var/lib/ezcage/<name>`; ad-hoc runs use the shared `ezcage` user.
- Profiles are written to `/etc/ezcage/profiles/<name>`, one argument per
  line. `ezcage <name> [args]` reads them; extra args go to the command.
- `--user` only accepts `ezcage` or `ezcage-*`, never root or a real account.
- Assertion: cage users must not be in `nix.settings.trusted-users`.
- **No sudoers rule**: `ezcage` calls `sudo` itself, so normal sudo rights
  (`wheel`) apply. A passwordless rule would need limits on `--group` (for
  example `--group shadow --ro /etc/shadow`) and is left out.
- A bind mount skips the parent directory's permission check, so
  `--ro /home/other/x` could expose world-readable files inside a `0700` home.
  Since only sudoers can run it, that does not matter.
- Tested on ezberry (2026-11-01) with `switch-to-configuration test`: users
  created, `ezcage nixos --version` runs Claude, a profile with its own
  package and `offline` works, extra args are passed on, `--user root` is
  refused; switching back removed the users.

## SSH agent

Off by default: the cage can't read `~/.ssh` and can't reach your agent.
`--ssh-agent` (profile option `sshAgent = true`) lets it use the agent from
`SSH_AUTH_SOCK`, for `git push` and the like. It can then sign as you, though
it still can't read the keys.

- **Linux**: `ssh-agent` only answers its own user, and the cage runs as
  another one. So `ezcage` runs a `socat` relay as you for the length of the
  run, with its socket in a private `mktemp -d` directory, and mounts only that
  socket into the cage as `/run/ssh-agent.sock`.
- **macOS**: the sandbox allows connecting to the agent's socket; without the
  flag only IP and a few named sockets are allowed (DNS's `mDNSResponder`,
  the Nix daemon, sockets in the cage's home). Before this, a cage that knew
  the agent's (random) path could use it.
- Tested 2026-11-01: on ezberry with a throwaway agent and key (visible with
  the flag, unreachable without), on this Mac with the login agent.

## macOS

`pkgs/ezcage/ezcage-darwin.sh`, installed as `ezcage` on macOS; the module is in
`darwinModules` (`default` and `ezcage`). No namespaces there, and no VMs (the
user's choice), so it uses the built-in sandbox, `sandbox-exec`, with a
generated profile that denies everything by default.

- **Same**: `--rw`, `--ro`, `--name`, `--workdir`, `--offline`, `--nix`/`--no-nix`,
  `--path`, `--umask`, read-only `.git`, profiles in `/etc/ezcage/profiles`.
- **Not supported**: `--netns`, `--user`, `--group`, `--main-group` (error).
  Profiles with `groups`, `mainGroup` or `netns` fail an assertion.
- **Weaker than Linux**:
  - runs as you, no separate user; no `sudo` needed
  - blocked paths are denied, not hidden: names and metadata of any path can
    be read (`stat`), contents and directory listings cannot
  - Nix opens every directory on the way to its home and `/etc`, so those
    parents can be listed (names only). Named homes are therefore in
    `/Users/Shared/ezcage/<user>/<name>` (mode `0700`), not under your home
    folder, which would make your home's file names listable.
- **Readable**: `/System`, `/usr`, `/bin`, `/sbin`, `/private/etc`,
  `/Library/Preferences`, `/dev`, `/opt/homebrew`, `/nix/store`,
  `/nix/var/nix/profiles`, the command's own directory, granted paths, the home.
- **System services** (`mach-lookup`): only users, DNS, network config,
  certificates, logging, preferences and FSEvents. Not LaunchServices, the
  clipboard or AppleEvents, which could act outside the sandbox.
- **Tested on this Mac (macOS 27.0.1, 2026-11-01)**: Claude Code 2.1.309
  `--version`; granted folder writable, `.git`, home files, `Documents`,
  `/tmp` and the clipboard denied; network works, `--offline` blocks it; named
  home persists; `nix shell` works; `open -a Calculator` fails (no app
  launched); the cage can't see your Keychain, so Claude needs its own login
  there. The nix-darwin system builds with a profile, and the profile runs.
- **Not yet tried**: an interactive Claude session and its login (Claude
  normally keeps its login in the Keychain; whether it falls back to a file
  in the cage's home is untested).

## Threat model

- **Covers**: mistakes and prompt injection. Casual escape. With `--netns` or `--offline`, also reaching the LAN or
  the host's services.
- **Does not cover**:
  - Kernel exploits: same kernel. Use a microVM for that.
  - Data leaving through the tunnel: the cage can send anything it can read.
  - `--rw /etc/nixos` is a path to root through your `nixos-rebuild switch`.
    Review the diff every time; a VM would not change this.

## Later

- `services.ezcage.services.<unit>`: apply a profile to any systemd service.
  Until then services can set the same `serviceConfig` directly.
- microVM option (microvm.nix with `writableStoreOverlay`) for unattended runs,
  `--dangerously-skip-permissions`, or untrusted code.
- **Other Linux distros (probably worth doing).** The mechanism is plain
  systemd; only the mounts are NixOS-specific (`/nix/store`,
  `/run/current-system`, `/etc/static`, commands must be in the store). Detect
  NixOS, else mount `/usr` (and the `/bin`, `/lib` links) read-only, accept
  commands from `/usr/bin`, and create the `ezcage` user with `useradd`.
  About 15 lines in the script.

## Prototype results (ezberry, 2026-11-01, systemd 260)

Ran the unit settings above by hand with `systemd-run --wait --pipe`:

- **Works**:
  - empty root shows only `nix`, `etc` (the listed files), `run`
    (`current-system` and journal sockets), `var/lib/ezcage/<name>`, `tmp`
  - `/home` absent, writes outside granted paths denied
  - `sudo` blocked by `NoNewPrivileges`
  - `PrivateNetwork` gives only `lo`; `NetworkNamespacePath` plus the two DNS mounts gives the netns and its `resolv.conf`
  - static user: `whoami` and Node `os.userInfo()` work
- **Fixed in this design**: `/var/empty` root, `DynamicUser`, `PrivatePIDs` (see above).
- **`pkgs/ezcage` script** (same day):
  - relative `--rw`/`--ro` paths
  - read-only `.git` (hook write denied) while git works inside
  - exit codes passed through, `--name` home kept across runs
  - errors for missing paths, namespaces and commands
  - host network DNS (then `--host-network`, now the default)
  - terminal mode (`--pty`)
  - Claude Code 2.1.223: `--version` with no network; started interactively, showed its welcome screen and saved its settings in the cage home
- **Not yet tried**: logging in to Claude Code and working in a cage, a real eznetns tunnel.

## Testing (on ezberry)

```bash
nix run .#ezcage -- --rw /tmp/x -- bash          # script changes, no rebuild
sudo nixos-rebuild switch --flake ~/<ezberry-config>#ezberry \
  --override-input eznixpkgs path:$HOME/eznixpkgs  # module changes
```

Inside a cage, check:

```bash
ls /  ;  ls /home  ;  ls /run          # only granted paths
cat /etc/resolv.conf                   # netns nameservers (with --netns)
getent hosts anthropic.com             # resolves, except with --offline
curl -s ifconfig.me                    # tunnel exit address
touch /etc/nixos/x && touch /etc/x     # first works, second fails
touch /etc/nixos/.git/x                # fails
```

Keep a root shell open while testing the sudoers rule.
