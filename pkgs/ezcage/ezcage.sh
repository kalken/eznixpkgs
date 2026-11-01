#!/usr/bin/env bash
# ezcage: run a program that sees only the paths it is granted.
# Builds a transient systemd unit with an empty root, a static non-root user
# and the host network unless offline or an eznetns namespace is given.
# See modules/ezcage.md.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ezcage [options] -- COMMAND [ARGS]...
       ezcage PROFILE [ARGS]...     (profiles from programs.ezcage.profiles)

  --rw PATH         grant read-write access (repeatable)
  --ro PATH         grant read-only access (repeatable)
  --name NAME       keep a home in /var/lib/ezcage/NAME across runs
                    (default: temporary home, gone after the run)
  --workdir DIR     start in DIR (default: current directory if granted, else home)
  --netns NAME      network of the eznetns namespace NAME, with its DNS
  --offline         no network, loopback only (default: host network)
  --nix, --no-nix   allow or deny Nix commands such as nix shell (default:
                    allowed, except with --netns or --offline: Nix builds
                    run outside the cage's network)
  --user USER       run as USER, ezcage or ezcage-* (default: ezcage)
  --group GROUP     also run with GROUP, e.g. the group that owns a --rw path
                    (repeatable)
  --main-group GROUP
                    run with GROUP as main group: new files get this group
  --umask MASK      umask for the cage, e.g. 0002 for group-writable files
  --git             let the cage write .git folders, so it can commit (and push,
                    with --ssh-agent). It can then run commands as you, outside
                    the cage, through hooks or .git/config. Default: every .git
                    below a --rw path is read-only
  --path DIR        put DIR (in /nix/store) on the cage's PATH (repeatable)
  --ssh-agent       let the cage use your SSH agent (from SSH_AUTH_SOCK): it can
                    sign as you, e.g. git push, but still can't read the keys
  -h, --help        show this help
EOF
}

die() { echo "ezcage: $*" >&2; exit 1; }

# A profile is a file of arguments, one per line, ending with "--" and the
# command. Arguments after the profile name are passed on to the command.
profiles=/etc/ezcage/profiles
if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
  [ -f "$profiles/$1" ] || die "unknown profile: $1 (see $profiles)"
  mapfile -t pargs < "$profiles/$1"
  set -- "${pargs[@]}" "${@:2}"
fi

rw=() ro=() groups=() paths=() name="" workdir="" netns="" maingroup="" umask="" offline=0 git=0 gitname="" gitemail="" nix="" ssh_agent=0 agentsock="" user="ezcage" cmd=()

while [ $# -gt 0 ]; do
  case "$1" in
    --rw) rw+=("${2:?--rw needs a path}"); shift 2 ;;
    --ro) ro+=("${2:?--ro needs a path}"); shift 2 ;;
    --name) name="${2:?--name needs a name}"; shift 2 ;;
    --workdir) workdir="${2:?--workdir needs a directory}"; shift 2 ;;
    --netns) netns="${2:?--netns needs a name}"; shift 2 ;;
    --offline) offline=1; shift ;;
    --nix) nix=1; shift ;;
    --no-nix) nix=0; shift ;;
    --user) user="${2:?--user needs a user}"; shift 2 ;;
    --group) groups+=("${2:?--group needs a group}"); shift 2 ;;
    --main-group) maingroup="${2:?--main-group needs a group}"; shift 2 ;;
    --umask) umask="${2:?--umask needs a mask}"; shift 2 ;;
    --git) git=1; shift ;;
    # Internal: your git identity, read before sudo
    --git-name) gitname="${2:?}"; shift 2 ;;
    --git-email) gitemail="${2:?}"; shift 2 ;;
    --path) paths+=("${2:?--path needs a directory}"); shift 2 ;;
    --ssh-agent) ssh_agent=1; shift ;;
    # Internal: the relay socket set up before sudo
    --ssh-agent-socket) agentsock="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; cmd=("$@"); break ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ ${#cmd[@]} -gt 0 ] || { usage >&2; exit 1; }
[ -z "$netns" ] || [ "$offline" = 0 ] || die "--netns and --offline exclude each other"
[ -z "$name" ] || [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid name: $name"
[ -z "$umask" ] || [[ "$umask" =~ ^[0-7]{3,4}$ ]] || die "invalid umask: $umask"

# Absolute, symlink-free path. Whitespace and ':' would break the unit settings.
resolve() {
  local p
  p=$(realpath -e -- "$1" 2>/dev/null) || die "path not found: $1"
  [[ "$p" =~ [[:space:]:] ]] && die "path contains whitespace or ':': $p"
  printf '%s\n' "$p"
}

# Resolve only the directory and keep the name: multi-call binaries such as
# coreutils pick their behaviour from it. The directory (a profile's bin) is
# also put on the cage's PATH.
storepath() {
  printf '%s/%s\n' "$(realpath -e -- "$(dirname -- "$1")")" "$(basename -- "$1")"
}

# Everything that depends on the caller (relative paths, the current
# directory, the command on the caller's PATH) is resolved before sudo.
if [ "$EUID" -ne 0 ]; then
  args=()
  for p in "${rw[@]+"${rw[@]}"}"; do args+=(--rw "$(resolve "$p")"); done
  for p in "${ro[@]+"${ro[@]}"}"; do args+=(--ro "$(resolve "$p")"); done
  [ -n "$name" ] && args+=(--name "$name")
  [ -n "$netns" ] && args+=(--netns "$netns")
  [ "$offline" = 1 ] && args+=(--offline)
  [ "$nix" = 1 ] && args+=(--nix)
  [ "$nix" = 0 ] && args+=(--no-nix)
  if [ "$git" = 1 ]; then
    args+=(--git)
    # The cage can't read your git config: commit as you
    n=$(git config user.name 2>/dev/null) && args+=(--git-name "$n")
    e=$(git config user.email 2>/dev/null) && args+=(--git-email "$e")
  fi
  args+=(--user "$user")
  for g in "${groups[@]+"${groups[@]}"}"; do args+=(--group "$g"); done
  [ -n "$maingroup" ] && args+=(--main-group "$maingroup")
  [ -n "$umask" ] && args+=(--umask "$umask")
  for d in "${paths[@]+"${paths[@]}"}"; do args+=(--path "$d"); done
  if [ -n "$workdir" ]; then
    args+=(--workdir "$(resolve "$workdir")")
  else
    args+=(--workdir "$(pwd -P)")
  fi
  # A profile's packages come first, then the caller's PATH
  searchpath=$(IFS=:; echo "${paths[*]+${paths[*]}}")
  exe=$(PATH="${searchpath:+$searchpath:}$PATH" type -P -- "${cmd[0]}") || die "command not found: ${cmd[0]}"
  exe=$(storepath "$exe")
  if [ "$ssh_agent" = 1 ]; then
    [ -S "${SSH_AUTH_SOCK:-}" ] || die "--ssh-agent: no agent (SSH_AUTH_SOCK is not a socket)"
    # ssh-agent only answers its own user, and the cage runs as another one:
    # relay it as you, through a socket in a private directory that only the
    # cage gets mounted
    relaydir=$(mktemp -d)
    socat UNIX-LISTEN:"$relaydir/agent",fork,perm=0666 UNIX-CONNECT:"$SSH_AUTH_SOCK" 2>/dev/null &
    relay=$!
    trap 'kill "$relay" 2>/dev/null; rm -rf "$relaydir"' EXIT
    for _ in $(seq 50); do [ -S "$relaydir/agent" ] && break; sleep 0.1; done
    [ -S "$relaydir/agent" ] || die "--ssh-agent: relay did not start"
    args+=(--ssh-agent-socket "$relaydir/agent")
    rc=0
    sudo "$0" "${args[@]}" -- "$exe" "${cmd[@]:1}" || rc=$?
    exit "$rc"
  fi
  exec sudo "$0" "${args[@]}" -- "$exe" "${cmd[@]:1}"
fi

# Never root or a real account: only the users the module creates for cages
[[ "$user" =~ ^ezcage(-[A-Za-z0-9_-]+)?$ ]] || die "user must be ezcage or ezcage-*: $user"
getent passwd "$user" >/dev/null || die "user '$user' does not exist (enable programs.ezcage)"
for d in "${paths[@]+"${paths[@]}"}"; do
  [[ "$d" == /nix/store/* ]] || die "--path must be in /nix/store: $d"
done
for g in "${groups[@]+"${groups[@]}"}" ${maingroup:+"$maingroup"}; do
  getent group "$g" >/dev/null || die "group not found: $g"
done

for i in "${!rw[@]}"; do rw[i]=$(resolve "${rw[i]}"); done
for i in "${!ro[@]}"; do ro[i]=$(resolve "${ro[i]}"); done

# The command must be visible in the cage: keep it if it is in the store,
# else look it up on the system PATH.
exe="${cmd[0]}"
if [[ "$exe" != /nix/store/* ]]; then
  exe=$(PATH=/run/current-system/sw/bin type -P -- "$exe") || die "command not found: ${cmd[0]}"
  exe=$(storepath "$exe")
fi
[[ "$exe" == /nix/store/* ]] || die "command is not in /nix/store, so the cage can't see it: $exe"

if [ -n "$name" ]; then
  home="/var/lib/ezcage/$name"
else
  home="/tmp/home"
fi

# Start in the requested directory if the cage can see it, else in the home
inside() {
  local d="$1" p
  for p in "${rw[@]+"${rw[@]}"}" "${ro[@]+"${ro[@]}"}"; do
    [ "$d" = "$p" ] || [[ "$d" == "$p"/* ]] && return 0
  done
  return 1
}
if [ -z "$workdir" ] || ! inside "$workdir"; then
  workdir="$home"
fi

root=/run/ezcage/root
mkdir -p -m 0755 "$root"

props=(
  # Empty root with only the store, the system profile and a few /etc files
  -p RootDirectory="$root"
  -p TemporaryFileSystem=/
  -p MountAPIVFS=yes
  -p PrivateTmp=yes
  -p "BindReadOnlyPaths=/nix/store /run/current-system /etc/static -/etc/ssl /etc/passwd /etc/group -/etc/hosts -/etc/localtime"

  -p User="$user"
  -p SupplementaryGroups="ezcage${groups[*]+ ${groups[*]}}"

  -p NoNewPrivileges=yes
  -p PrivateDevices=yes
  -p PrivateIPC=yes
  -p ProtectProc=invisible
  -p ProcSubset=pid
  -p ProtectKernelTunables=yes
  -p ProtectKernelModules=yes
  -p ProtectControlGroups=yes
  -p SystemCallFilter=@system-service
  -p RestrictNamespaces=yes
  -p LockPersonality=yes
  -p "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK"
)

[ -n "$name" ] && props+=(-p StateDirectory="ezcage/$name")
[ -n "$maingroup" ] && props+=(-p Group="$maingroup")
[ -n "$umask" ] && props+=(-p UMask="$umask")

for p in "${rw[@]+"${rw[@]}"}"; do
  props+=(-p BindPaths="$p")
  # git hooks or .git/config written in the cage would run as you outside
  # it: every .git below the path, also nested repos
  if [ "$git" = 0 ]; then
    while IFS= read -r -d '' g; do
      props+=(-p BindReadOnlyPaths="$g")
    done < <(find "$p" -xdev -name .git -prune -print0 2>/dev/null)
  fi
done
for p in "${ro[@]+"${ro[@]}"}"; do
  props+=(-p BindReadOnlyPaths="$p")
done

if [ -n "$netns" ]; then
  [ -e "/run/netns/$netns" ] || die "network namespace not found: /run/netns/$netns"
  props+=(-p NetworkNamespacePath="/run/netns/$netns")
  # Only the DNS files: the folder also holds WireGuard private keys
  for f in resolv.conf nsswitch.conf; do
    [ -f "/etc/eznetns/$netns/$f" ] && props+=(-p BindReadOnlyPaths="/etc/eznetns/$netns/$f:/etc/$f")
  done
  if systemctl cat "eznetns-$netns.service" >/dev/null 2>&1; then
    props+=(-p BindsTo="eznetns-$netns.service" -p After="eznetns-$netns.service")
  fi
elif [ "$offline" = 1 ]; then
  props+=(-p PrivateNetwork=yes)
else
  props+=(-p "BindReadOnlyPaths=-/etc/resolv.conf -/etc/nsswitch.conf")
fi

# Nix through the daemon. Its builds run as root in the host network, which
# would bypass --netns and --offline, so those turn it off unless --nix is given.
if [ -z "$nix" ]; then
  if [ -n "$netns" ] || [ "$offline" = 1 ]; then nix=0; else nix=1; fi
fi
if [ "$nix" = 1 ]; then
  props+=(-p BindPaths=/nix/var/nix/daemon-socket -p BindReadOnlyPaths=-/etc/nix)
fi

if [ -n "$agentsock" ]; then
  [ -S "$agentsock" ] || die "--ssh-agent: relay socket not found: $agentsock"
  props+=(-p BindPaths="$agentsock:/run/ssh-agent.sock")
elif [ "$ssh_agent" = 1 ]; then
  die "--ssh-agent: run ezcage as your own user, not as root"
fi

env=(
  -E HOME="$home"
  -E USER="$user"
  -E PATH="$(IFS=:; echo "${paths[*]+${paths[*]}:}")$(dirname "$exe"):/run/current-system/sw/bin"
  -E TERM="${TERM:-dumb}"
  -E LANG="${LANG:-C.UTF-8}"
  # The repo's owner differs from the cage user, which git refuses by default
  -E GIT_CONFIG_COUNT=1
  -E GIT_CONFIG_KEY_0=safe.directory
  -E GIT_CONFIG_VALUE_0='*'
)
[ -n "${COLORTERM:-}" ] && env+=(-E COLORTERM="$COLORTERM")
[ -n "${LOCALE_ARCHIVE:-}" ] && env+=(-E LOCALE_ARCHIVE="$LOCALE_ARCHIVE")
[ -n "$agentsock" ] && env+=(-E SSH_AUTH_SOCK=/run/ssh-agent.sock)
[ -n "$gitname" ] && env+=(-E GIT_AUTHOR_NAME="$gitname" -E GIT_COMMITTER_NAME="$gitname")
[ -n "$gitemail" ] && env+=(-E GIT_AUTHOR_EMAIL="$gitemail" -E GIT_COMMITTER_EMAIL="$gitemail")

# No name: the home is created in the private /tmp before the command runs
if [ -z "$name" ]; then
  run=(/run/current-system/sw/bin/sh -c 'mkdir -p "$HOME" && cd "$0" 2>/dev/null; exec "$@"' "$workdir" "$exe" "${cmd[@]:1}")
  wd=()
else
  run=("$exe" "${cmd[@]:1}")
  wd=(--working-directory="$workdir")
fi

if [ -t 0 ] && [ -t 1 ]; then
  mode=(--pty)
else
  mode=(--pipe --wait)
fi

exec systemd-run --quiet --collect "${mode[@]}" \
  --description="ezcage ${name:-(temporary)}: ${cmd[0]}" \
  "${props[@]}" "${env[@]}" "${wd[@]+"${wd[@]}"}" \
  "${run[@]}"
