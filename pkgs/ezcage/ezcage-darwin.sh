#!/usr/bin/env bash
# ezcage for macOS: run a program that can only read and write the paths it is
# granted, using the built-in sandbox (sandbox-exec). Weaker than the Linux
# version: blocked paths stay visible by name, it runs as you, and there is no
# --netns. See modules/ezcage.md.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ezcage [options] -- COMMAND [ARGS]...
       ezcage [options] PROFILE [ARGS]...     (profiles from programs.ezcage.profiles;
                                              options before it are added to its own)

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
                    sign as you, e.g. git push, but still can't read the keys.
                    It may also read ~/.ssh/known_hosts and ~/.ssh/config
  --git             let the cage write .git folders, so it can commit (and push,
                    with --ssh-agent). It can then run commands as you, outside
                    the cage, through hooks or .git/config. Default: every .git
                    below a --rw path is read-only, and none can be created
  --claude-token    with --name: ask for a token from `claude setup-token` and
                    keep it in the cage's home, so Claude stays logged in
                    (the cage can't use the Keychain)
  -h, --help        show this help

  Not on macOS: --netns, --user, --group, --main-group.
EOF
}

die() { echo "ezcage: $*" >&2; exit 1; }

profiles=/etc/ezcage/profiles
# Options can come before the profile name: ezcage --ro DIR PROFILE [ARGS]...
# They are put first, so a profile's own value for --name or --workdir wins, while
# --rw, --ro and --path add up.
pre=()
while [ $# -gt 0 ] && [[ "$1" == -* ]] && [[ "$1" != -- && "$1" != -h && "$1" != --help ]]; do
  case "$1" in
    --rw|--ro|--name|--workdir|--umask|--path|--netns|--user|--group|--main-group)
      pre+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
    *) pre+=("$1"); shift ;;
  esac
done
if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
  [ -f "$profiles/$1" ] || die "unknown profile: $1 (see $profiles)"
  mapfile -t pargs < "$profiles/$1"
  set -- "${pre[@]+"${pre[@]}"}" "${pargs[@]}" "${@:2}"
else
  set -- "${pre[@]+"${pre[@]}"}" "$@"
fi

rw=() ro=() paths=() name="" workdir="" umask="" offline=0 nix="" ssh_agent=0 claude_token=0 git=0 cmd=()

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
    --claude-token) claude_token=1; shift ;;
    --git) git=1; shift ;;
    --umask) umask="${2:?--umask needs a mask}"; shift 2 ;;
    --path) paths+=("${2:?--path needs a directory}"); shift 2 ;;
    --netns|--user|--group|--main-group) die "$1 is not supported on macOS" ;;
    -h|--help) usage; exit 0 ;;
    --) shift; cmd=("$@"); break ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ "$claude_token" = 0 ] || [ -n "$name" ] || die "--claude-token needs --name"
[ ${#cmd[@]} -gt 0 ] || [ "$claude_token" = 1 ] || { usage >&2; exit 1; }
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

# Claude Code keeps its login in the Keychain, which the cage can't reach.
# A token from `claude setup-token` in the cage's home works instead.
tokenfile="$home/.claude-oauth-token"
if [ "$claude_token" = 1 ]; then
  read -rsp "Token from 'claude setup-token': " token; echo
  [ -n "$token" ] || die "no token given"
  (umask 077; printf '%s\n' "$token" > "$tokenfile")
  echo "Saved in $tokenfile"
  [ ${#cmd[@]} -gt 0 ] || exit 0
fi

searchpath=$(IFS=:; echo "${paths[*]+${paths[*]}}")
exe=$(PATH="${searchpath:+$searchpath:}$PATH" type -P -- "${cmd[0]}") || die "command not found: ${cmd[0]}"
# The program file itself (often behind a symlink, e.g. in Homebrew) must be readable
exereal=$(resolve "$exe")

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
# Your global gitignore, so git in the cage ignores what it ignores outside
gitignore=$(git config --global --path core.excludesFile 2>/dev/null) \
  || gitignore="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
if [ -f "$gitignore" ]; then gitignore=$(resolve "$gitignore"); else gitignore=""; fi

# ssh reads ~/.ssh from your real home, not HOME: let it check host keys
sshfiles=()
if [ -n "$agent" ]; then
  for f in "$HOME/.ssh/known_hosts" "$HOME/.ssh/config"; do
    [ -f "$f" ] && sshfiles+=("$(resolve "$f")")
  done
fi

q() { printf '"%s"' "$1"; }
# A path as a regex that matches it literally
rx() { printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|]/\\&/g'; }

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
; Itself and what runs in this cage (a test server it started, a build), nothing outside it
(allow signal (target same-sandbox))
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
; /dev/ptmx is what openpty() opens to make a pseudo-terminal: without write and
; ioctl on it a program in here cannot start a shell of its own (a terminal
; server, script, expect), and fails with "out of pty devices".
(allow file-write* (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper")
  (literal "/dev/ptmx") (regex #"^/dev/ttys[0-9]+$") (subpath "/dev/fd"))
(allow file-ioctl (literal "/dev/tty") (literal "/dev/ptmx") (regex #"^/dev/ttys[0-9]+$"))
EOF
  echo "(allow file-read* (subpath $(q "$(dirname "$exereal")")))"
  # /usr/bin/git and friends are shims that run the developer tools via xcrun
  devdir=$(xcode-select -p 2>/dev/null) && devdir=$(realpath -- "$devdir" 2>/dev/null) \
    && echo "(allow file-read* (subpath $(q "$devdir")) (literal \"/private/var/db/xcode_select_link\"))"
  echo "(allow file-read* file-write* (subpath $(q "$home")))"
  parents "$home" /private/etc
  for p in "${ro[@]+"${ro[@]}"}"; do
    echo "(allow file-read* (subpath $(q "$p")))"
  done
  for p in "${rw[@]+"${rw[@]}"}"; do
    echo "(allow file-read* file-write* (subpath $(q "$p")))"
    # git hooks or .git/config written in the cage would run as you outside
    # it: every .git below the path, also nested repos and new ones
    [ "$git" = 1 ] || echo "(deny file-write* (regex #\"^$(rx "$p")/(.*/)?\\.git(/|$)\"))"
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
  [ -n "$gitignore" ] && echo "(allow file-read* (literal $(q "$gitignore")))"
  for f in "${sshfiles[@]+"${sshfiles[@]}"}"; do
    echo "(allow file-read* (literal $(q "$f")))"
  done
} > "$profile"

syspath="/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cagepath="${searchpath:+$searchpath:}$(dirname "$exe"):$syspath"

env=(
  HOME="$home"
  USER="$USER"
  LOGNAME="$USER"
  TMPDIR="$home/tmp"
  # Claude Code ignores TMPDIR and would use /tmp/claude-<uid>
  CLAUDE_CODE_TMPDIR="$home/tmp"
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
[ -n "$gitignore" ] && env+=(GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_1=core.excludesFile GIT_CONFIG_VALUE_1="$gitignore")
# The cage can't read your git config: commit as you
if [ "$git" = 1 ]; then
  n=$(git config user.name 2>/dev/null) && env+=(GIT_AUTHOR_NAME="$n" GIT_COMMITTER_NAME="$n")
  e=$(git config user.email 2>/dev/null) && env+=(GIT_AUTHOR_EMAIL="$e" GIT_COMMITTER_EMAIL="$e")
fi
[ -s "$tokenfile" ] && env+=(CLAUDE_CODE_OAUTH_TOKEN="$(cat "$tokenfile")")

cd "$workdir"
rc=0
[ -n "$umask" ] && umask "$umask"
env -i "${env[@]}" sandbox-exec -f "$profile" "$exe" "${cmd[@]:1}" || rc=$?
exit "$rc"
