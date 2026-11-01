#!/usr/bin/env bash
# ezcage for macOS: run a program that can only read and write the paths it is
# granted, using the built-in sandbox (sandbox-exec). Weaker than the Linux
# version: blocked paths stay visible by name, it runs as you, and there is no
# --netns. See modules/ezcage.md.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ezcage [options] -- COMMAND [ARGS]...
       ezcage PROFILE [ARGS]...     (profiles from programs.ezcage.profiles)

  --rw PATH         grant read-write access (repeatable)
  --ro PATH         grant read-only access (repeatable)
  --name NAME       keep a home in /Users/Shared/ezcage/USER/NAME across runs
                    (default: temporary home, gone after the run)
  --workdir DIR     start in DIR (default: current directory if granted, else home)
  --offline         no network, loopback only (default: network)
  --nix, --no-nix   allow or deny Nix commands such as nix shell (default:
                    allowed, except with --offline)
  --umask MASK      umask for the cage, e.g. 0002 for group-writable files
  --path DIR        put DIR on the cage's PATH (repeatable)
  --ssh-agent       let the cage use your SSH agent (from SSH_AUTH_SOCK): it can
                    sign as you, e.g. git push, but still can't read the keys
  -h, --help        show this help

  Not on macOS: --netns, --user, --group, --main-group.
EOF
}

die() { echo "ezcage: $*" >&2; exit 1; }

profiles=/etc/ezcage/profiles
if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
  [ -f "$profiles/$1" ] || die "unknown profile: $1 (see $profiles)"
  mapfile -t pargs < "$profiles/$1"
  set -- "${pargs[@]}" "${@:2}"
fi

rw=() ro=() paths=() name="" workdir="" umask="" offline=0 nix="" ssh_agent=0 cmd=()

while [ $# -gt 0 ]; do
  case "$1" in
    --rw) rw+=("${2:?--rw needs a path}"); shift 2 ;;
    --ro) ro+=("${2:?--ro needs a path}"); shift 2 ;;
    --name) name="${2:?--name needs a name}"; shift 2 ;;
    --workdir) workdir="${2:?--workdir needs a directory}"; shift 2 ;;
    --offline) offline=1; shift ;;
    --nix) nix=1; shift ;;
    --no-nix) nix=0; shift ;;
    --ssh-agent) ssh_agent=1; shift ;;
    --umask) umask="${2:?--umask needs a mask}"; shift 2 ;;
    --path) paths+=("${2:?--path needs a directory}"); shift 2 ;;
    --netns|--user|--group|--main-group) die "$1 is not supported on macOS" ;;
    -h|--help) usage; exit 0 ;;
    --) shift; cmd=("$@"); break ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ ${#cmd[@]} -gt 0 ] || { usage >&2; exit 1; }
[ -z "$name" ] || [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid name: $name"
[ -z "$umask" ] || [[ "$umask" =~ ^[0-7]{3,4}$ ]] || die "invalid umask: $umask"

# The sandbox matches real paths (/tmp is /private/tmp), so resolve symlinks.
# Quotes and backslashes would break the sandbox profile.
resolve() {
  local p
  p=$(realpath -- "$1" 2>/dev/null) && [ -e "$p" ] || die "path not found: $1"
  [[ "$p" == *[\"\\]* ]] && die "path contains a quote or backslash: $p"
  printf '%s\n' "$p"
}

for i in "${!rw[@]}"; do rw[i]=$(resolve "${rw[i]}"); done
for i in "${!ro[@]}"; do ro[i]=$(resolve "${ro[i]}"); done
for i in "${!paths[@]}"; do paths[i]=$(resolve "${paths[i]}"); done

searchpath=$(IFS=:; echo "${paths[*]+${paths[*]}}")
exe=$(PATH="${searchpath:+$searchpath:}$PATH" type -P -- "${cmd[0]}") || die "command not found: ${cmd[0]}"
# The program file itself (often behind a symlink, e.g. in Homebrew) must be readable
exereal=$(resolve "$exe")

tmphome=""
if [ -n "$name" ]; then
  # Outside your home folder: its parents get listed (see parents below)
  home="/Users/Shared/ezcage/$USER/$name"
  mkdir -p "$home"
  chmod 700 "/Users/Shared/ezcage/$USER"
else
  tmphome=$(mktemp -d "${TMPDIR:-/tmp}/ezcage.XXXXXX")
  home="$tmphome"
fi
home=$(resolve "$home")
mkdir -p "$home/tmp"

inside() {
  local d="$1" p
  for p in "${rw[@]+"${rw[@]}"}" "${ro[@]+"${ro[@]}"}"; do
    [ "$d" = "$p" ] || [[ "$d" == "$p"/* ]] && return 0
  done
  return 1
}
if [ -n "$workdir" ]; then
  workdir=$(resolve "$workdir")
else
  workdir=$(pwd -P)
fi
inside "$workdir" || workdir="$home"

[ -n "$nix" ] || { [ "$offline" = 1 ] && nix=0 || nix=1; }

agent=""
if [ "$ssh_agent" = 1 ]; then
  [ -S "${SSH_AUTH_SOCK:-}" ] || die "--ssh-agent: no agent (SSH_AUTH_SOCK is not a socket)"
  agent=$(resolve "$SSH_AUTH_SOCK")
fi

q() { printf '"%s"' "$1"; }

# Nix opens every directory on the way to its home and /etc, so those
# parents may be listed: names only, not their contents.
parents() {
  local d
  for d in "$@"; do
    d=$(dirname "$d")
    while [ "$d" != / ]; do
      echo "(allow file-read-data (literal $(q "$d")))"
      d=$(dirname "$d")
    done
  done | sort -u
}

profile=$(mktemp "${TMPDIR:-/tmp}/ezcage-profile.XXXXXX")
cleanup() { rm -f "$profile"; [ -z "$tmphome" ] || rm -rf "$tmphome"; }
trap cleanup EXIT

{
  cat <<'EOF'
(version 1)
(deny default)
(allow process-exec process-fork)
(allow signal (target self))
(allow sysctl-read ipc-posix-shm ipc-posix-sem pseudo-tty)

; Only the system services programs need: users, DNS, network config,
; certificates, logging, preferences. Not LaunchServices, the clipboard or
; AppleEvents, which could reach outside the sandbox.
(allow mach-lookup (global-name
  "com.apple.system.opendirectoryd.libinfo"
  "com.apple.system.notification_center"
  "com.apple.dnssd.service"
  "com.apple.SystemConfiguration.configd"
  "com.apple.SystemConfiguration.DNSConfiguration"
  "com.apple.trustd" "com.apple.trustd.agent"
  "com.apple.system.logger" "com.apple.logd" "com.apple.diagnosticd"
  "com.apple.cfprefsd.daemon" "com.apple.cfprefsd.agent"
  "com.apple.FSEvents"))

; Names and metadata of every path are visible; contents only where allowed
(allow file-read-metadata)
(allow file-read* (literal "/")
  (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin")
  (subpath "/private/etc") (subpath "/private/var/db/timezone")
  (subpath "/Library/Preferences") (subpath "/dev")
  (subpath "/opt/homebrew") (subpath "/nix/store") (subpath "/nix/var/nix/profiles"))
(allow file-write* (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper")
  (regex #"^/dev/ttys[0-9]+$") (subpath "/dev/fd"))
(allow file-ioctl (literal "/dev/tty") (regex #"^/dev/ttys[0-9]+$"))
EOF
  echo "(allow file-read* (subpath $(q "$(dirname "$exereal")")))"
  echo "(allow file-read* file-write* (subpath $(q "$home")))"
  parents "$home" /private/etc
  for p in "${ro[@]+"${ro[@]}"}"; do
    echo "(allow file-read* (subpath $(q "$p")))"
  done
  for p in "${rw[@]+"${rw[@]}"}"; do
    echo "(allow file-read* file-write* (subpath $(q "$p")))"
    # git hooks written in the cage would run as you outside it
    [ -d "$p/.git" ] && echo "(deny file-write* (subpath $(q "$p/.git")))"
  done
  for p in "${paths[@]+"${paths[@]}"}"; do
    echo "(allow file-read* (subpath $(q "$p")))"
  done
  # IP only: Unix sockets outside the cage's home, such as your SSH agent,
  # could act as you even though the cage can't read the keys
  if [ "$offline" = 1 ]; then
    echo '(allow network* (local ip "localhost:*") (remote ip "localhost:*"))'
  else
    echo '(allow network* (local ip) (remote ip))'
    # DNS lookups go through this socket
    echo '(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))'
  fi
  echo "(allow network* (local unix-socket (subpath $(q "$home"))) (remote unix-socket (subpath $(q "$home"))))"
  # Sockets are often links (the Nix socket to /var/run/nix-daemon.socket);
  # the sandbox checks the real path
  if [ "$nix" = 1 ]; then
    sock=$(realpath /nix/var/nix/daemon-socket/socket 2>/dev/null || echo /nix/var/nix/daemon-socket/socket)
    echo "(allow network-outbound (remote unix-socket (path-literal $(q "$sock"))))"
  fi
  if [ -n "$agent" ]; then
    echo "(allow network-outbound (remote unix-socket (path-literal $(q "$agent"))))"
  fi
} > "$profile"

syspath="/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cagepath="${searchpath:+$searchpath:}$(dirname "$exe"):$syspath"

env=(
  HOME="$home"
  USER="$USER"
  LOGNAME="$USER"
  TMPDIR="$home/tmp"
  PATH="$cagepath"
  TERM="${TERM:-dumb}"
  LANG="${LANG:-en_US.UTF-8}"
  # The cage's git can't read your ~/.gitconfig
  GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0=safe.directory
  GIT_CONFIG_VALUE_0='*'
)
[ -n "${COLORTERM:-}" ] && env+=(COLORTERM="$COLORTERM")
[ -n "$agent" ] && env+=(SSH_AUTH_SOCK="$agent")

cd "$workdir"
rc=0
[ -n "$umask" ] && umask "$umask"
env -i "${env[@]}" sandbox-exec -f "$profile" "$exe" "${cmd[@]:1}" || rc=$?
exit "$rc"
