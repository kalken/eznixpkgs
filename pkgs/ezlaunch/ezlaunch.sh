# shellcheck shell=bash
# ezlaunch: install and launch Windows games with Proton (umu-launcher).
# Run with no arguments for usage.

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
GAMES="$DATA/ezlaunch/games"
APPS="$DATA/applications"
USER_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ezlaunch/config"
SYSTEM_CONF=/etc/ezlaunch/config
# Where ezproton installs Proton
TOOLS="$HOME/.local/share/Steam/compatibilitytools.d"

# KEY|value when on|value when off|label, the options in the settings dialog
KNOWN=(
  "PROTON_ENABLE_HDR|1|0|HDR"
  "PROTON_ENABLE_WAYLAND|1|0|Native Wayland"
  "PROTON_USE_NTSYNC|1|0|NTSync"
  "PROTON_ENABLE_NVAPI|1|0|NVIDIA NVAPI (DLSS)"
  "PROTON_USE_WINED3D|1|0|WineD3D instead of DXVK"
  "PROTON_NO_ESYNC|1|0|Disable esync"
  "PROTON_NO_FSYNC|1|0|Disable fsync"
  "PROTON_LOG|1|0|Proton log"
  "MANGOHUD|1|0|MangoHud overlay"
  "EZLAUNCH_WRAPPER|gamemoderun||GameMode"
)

# The dialog tool: kdialog on KDE, otherwise zenity, otherwise whichever exists
GUI=
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  if [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]] && command -v kdialog >/dev/null; then
    GUI=kdialog
  elif command -v zenity >/dev/null; then
    GUI=zenity
  elif command -v kdialog >/dev/null; then
    GUI=kdialog
  fi
fi

msg() {
  echo "ezlaunch: $*" >&2
  case $GUI in
    zenity) zenity --error --no-markup --text "$*" || true ;;
    kdialog) kdialog --error "$*" || true ;;
    *) ;;
  esac
}

die() {
  msg "$*"
  exit 1
}

info() {
  echo "ezlaunch: $*"
  case $GUI in
    zenity) zenity --info --no-markup --text "$*" || true ;;
    kdialog) kdialog --msgbox "$*" || true ;;
    *) ;;
  esac
}

ask_text() { # prompt, default
  local reply
  case $GUI in
    zenity) zenity --entry --title ezlaunch --text "$1" --entry-text "$2" ;;
    kdialog) kdialog --title ezlaunch --inputbox "$1" "$2" ;;
    *)
      read -r -p "$1 [$2] " reply
      echo "${reply:-$2}"
      ;;
  esac
}

ask_file() { # prompt, start folder
  local reply
  case $GUI in
    zenity) zenity --file-selection --title "$1" --filename "$2" ;;
    kdialog) kdialog --title "$1" --getopenfilename "$2" ;;
    *)
      read -r -p "$1: " reply
      echo "$reply"
      ;;
  esac
}

ask_yesno() { # question
  local reply
  case $GUI in
    zenity) zenity --question --no-markup --text "$1" ;;
    kdialog) kdialog --yesno "$1" ;;
    *)
      read -r -p "$1 [y/N] " reply
      [ "$reply" = y ]
      ;;
  esac
}

ask_edit() { # title, text
  case $GUI in
    zenity) printf '%s\n' "$2" | zenity --text-info --editable --title "$1" --width 500 --height 300 ;;
    kdialog) kdialog --title ezlaunch --textinputbox "$1" "$2" 500 300 ;;
    *) die "this needs a graphical session" ;;
  esac
}

# prompt, then key label on|off triplets. Prints the checked keys, one per line.
ask_checklist() {
  local prompt=$1
  shift
  local args=()
  case $GUI in
    zenity)
      while [ $# -gt 0 ]; do
        if [ "$3" = on ]; then args+=(TRUE "$1" "$2"); else args+=(FALSE "$1" "$2"); fi
        shift 3
      done
      zenity --list --checklist --title ezlaunch --text "$prompt" --width 360 --height 440 \
        --column "" --column Key --column Setting --hide-column 2 --print-column 2 \
        --separator $'\n' "${args[@]}"
      ;;
    kdialog) kdialog --title ezlaunch --separate-output --checklist "$prompt" "$@" ;;
    *) die "this needs a graphical session" ;;
  esac
}

# prompt, then name on|off pairs. Prints the chosen name.
ask_radio() {
  local prompt=$1
  shift
  local args=()
  case $GUI in
    zenity)
      while [ $# -gt 0 ]; do
        if [ "$2" = on ]; then args+=(TRUE "$1"); else args+=(FALSE "$1"); fi
        shift 2
      done
      zenity --list --radiolist --title ezlaunch --text "$prompt" --width 360 --height 300 \
        --column "" --column Version "${args[@]}"
      ;;
    kdialog)
      while [ $# -gt 0 ]; do
        args+=("$1" "$1" "$2")
        shift 2
      done
      kdialog --title ezlaunch --radiolist "$prompt" "${args[@]}"
      ;;
    *) die "this needs a graphical session" ;;
  esac
}

check_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*$ ]] || die "invalid game name: $1"
}

desktop_file() { # name
  echo "$APPS/ezlaunch-${1// /_}.desktop"
}

refresh_menu() {
  update-desktop-database "$APPS" 2>/dev/null || true
}

# Last value of a KEY=value line in the given files, empty if there is none.
getv() { # key, files...
  local key=$1
  shift
  { grep -hs "^$key=" "$@" || true; } | tail -n1 | cut -d= -f2-
}

# Export the KEY=value lines of the given files, later files winning.
load_files() {
  local file line
  for file in "$@"; do
    [ -f "$file" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" == [A-Za-z_]*=* ]] || continue
      export "${line%%=*}=${line#*=}"
    done <"$file"
  done
}

# Run a program in the prefix of $WINEPREFIX with the loaded settings.
launch() { # program, args...
  export WINEPREFIX GAMEID="${GAMEID:-0}"
  # A name from ezproton (GE-Proton-Latest) becomes its full path. Anything else, such as a
  # path or a version umu downloads itself, is left to umu.
  if [ -n "${PROTONPATH:-}" ] && [[ "$PROTONPATH" != */* ]] && [ -d "$TOOLS/$PROTONPATH" ]; then
    export PROTONPATH="$TOOLS/$PROTONPATH"
  fi
  # EZLAUNCH_WRAPPER is a command prefix, such as gamemoderun
  # shellcheck disable=SC2086
  exec ${EZLAUNCH_WRAPPER:-} umu-run "$@"
}

extract_icon() { # exe, output png
  local tmp ico png
  tmp=$(mktemp -d)
  wrestool -x -t14 -o "$tmp" "$1" 2>/dev/null || true
  ico=$(find "$tmp" -name '*.ico' | sort | sed -n 1p)
  if [ -n "$ico" ]; then
    icotool -x -o "$tmp" "$ico" 2>/dev/null || true
    png=$(find "$tmp" -name '*.png' -printf '%s %p\n' | sort -rn | sed -n 1p | cut -d' ' -f2-)
    if [ -n "$png" ]; then cp "$png" "$2"; fi
  fi
  rm -rf "$tmp"
}

write_desktop() { # name, icon
  mkdir -p "$APPS"
  cat >"$(desktop_file "$1")" <<EOF
[Desktop Entry]
Type=Application
Name=$1
Exec=ezlaunch run "$1"
Icon=$2
Categories=Game;
Terminal=false
Actions=settings;remove;

[Desktop Action settings]
Name=Settings
Exec=ezlaunch settings "$1"

[Desktop Action remove]
Name=Remove
Exec=ezlaunch remove "$1"
EOF
  refresh_menu
}

cmd_add() { # [installer]
  local installer=${1:-} name dir exe icon
  if [ -z "$installer" ]; then installer=$(ask_file "Choose the installer" "$HOME/"); fi
  [ -f "$installer" ] || die "not a file: $installer"
  installer=$(readlink -f "$installer")

  name=$(ask_text "Name of the game" "$(basename "$(dirname "$installer")")")
  name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9 ._-' | sed 's/^[ .]*//; s/ *$//')
  [ -n "$name" ] || die "empty game name"
  dir="$GAMES/$name"
  if grep -qs '^EZLAUNCH_EXE=' "$dir/config"; then die "already added: $name"; fi

  mkdir -p "$dir/prefix"
  touch "$dir/config"

  # A game that was installed but never got its executable picked skips the installer
  if [ ! -f "$dir/.installed" ]; then
    (
      load_files "$SYSTEM_CONF" "$USER_CONF" "$dir/config"
      WINEPREFIX="$dir/prefix"
      cd "$(dirname "$installer")" || exit 1
      launch "$installer"
    ) || true
    touch "$dir/.installed"
  fi

  exe=$(ask_file "Choose the game executable" "$dir/prefix/drive_c/")
  [ -f "$exe" ] || die "not a file: $exe"

  icon=applications-games
  extract_icon "$exe" "$dir/icon.png"
  if [ -f "$dir/icon.png" ]; then icon="$dir/icon.png"; fi

  printf 'EZLAUNCH_EXE=%s\n' "$exe" >>"$dir/config"
  write_desktop "$name" "$icon"
  info "Added $name to the start menu."
}

cmd_run() { # name, args...
  local name=${1:?game name missing} dir
  shift
  check_name "$name"
  dir="$GAMES/$name"
  [ -f "$dir/config" ] || die "unknown game: $name"
  load_files "$SYSTEM_CONF" "$USER_CONF" "$dir/config"
  [ -n "${EZLAUNCH_EXE:-}" ] || die "$name has no executable set"
  WINEPREFIX="$dir/prefix"
  cd "$(dirname "$EZLAUNCH_EXE")" || exit 1
  # EZLAUNCH_ARGS is a list of arguments for the game
  # shellcheck disable=SC2086
  launch "$EZLAUNCH_EXE" ${EZLAUNCH_ARGS:-} "$@"
}

cmd_settings() { # name
  local name=${1:?game name missing} cfg
  check_name "$name"
  cfg="$GAMES/$name/config"
  [ -f "$cfg" ] || die "unknown game: $name"
  [ -n "$GUI" ] || die "settings needs a graphical session. Edit $cfg instead."

  local inherited=("$SYSTEM_CONF" "$USER_CONF") all=("$SYSTEM_CONF" "$USER_CONF" "$cfg")
  local entry key on off label state items=() managed=EZLAUNCH_EXE\|PROTONPATH
  for entry in "${KNOWN[@]}"; do
    IFS='|' read -r key on off label <<<"$entry"
    state=off
    if [ "$(getv "$key" "${all[@]}")" = "$on" ]; then state=on; fi
    items+=("$key" "$label" "$state")
    managed+="|$key"
  done
  local selected
  selected=$(ask_checklist "Settings for $name" "${items[@]}")

  local version current versions=() dir pairs=()
  current=$(getv PROTONPATH "${all[@]}")
  for dir in "$TOOLS"/*/; do
    if [ -d "$dir" ]; then versions+=("$(basename "$dir")"); fi
  done
  if [ -n "$current" ] && [[ ! " ${versions[*]} " == *" $current "* ]]; then versions+=("$current"); fi
  version=$current
  if [ ${#versions[@]} -gt 0 ]; then
    for dir in "${versions[@]}"; do
      if [ "$dir" = "$current" ]; then pairs+=("$dir" on); else pairs+=("$dir" off); fi
    done
    version=$(ask_radio "Proton version" "${pairs[@]}")
  fi

  local custom
  custom=$({ grep -Ev "^($managed)=" "$cfg" || true; })
  custom=$(ask_edit "Custom variables (KEY=value, one per line)" "$custom")

  {
    echo "EZLAUNCH_EXE=$(getv EZLAUNCH_EXE "$cfg")"
    if [ -n "$version" ] && [ "$version" != "$(getv PROTONPATH "${inherited[@]}")" ]; then
      echo "PROTONPATH=$version"
    fi
    for entry in "${KNOWN[@]}"; do
      IFS='|' read -r key on off label <<<"$entry"
      if grep -qx "$key" <<<"$selected"; then
        if [ "$(getv "$key" "${inherited[@]}")" != "$on" ]; then echo "$key=$on"; fi
      elif [ "$(getv "$key" "${inherited[@]}")" = "$on" ]; then
        echo "$key=$off"
      fi
    done
    if [ -n "$custom" ]; then printf '%s\n' "$custom"; fi
  } >"$cfg.new"
  mv "$cfg.new" "$cfg"
  info "Saved the settings for $name."
}

cmd_remove() { # name
  local name=${1:?game name missing}
  check_name "$name"
  [ -f "$GAMES/$name/config" ] || die "unknown game: $name"
  ask_yesno "Remove $name? Its prefix, with saved games inside it, is deleted." || exit 0
  rm -rf "${GAMES:?}/$name"
  rm -f "$(desktop_file "$name")"
  refresh_menu
}

cmd_list() {
  local dir
  for dir in "$GAMES"/*/; do
    if [ -f "$dir/config" ]; then basename "$dir"; fi
  done
}

usage() {
  cat <<EOF
Usage: ezlaunch <command>

  add [installer.exe]   run an installer in a new prefix and add the game to the start menu
  run <game> [args]     start a game
  settings <game>       change Proton version and options for a game
  remove <game>         delete a game, its prefix and its start menu entry
  list                  list the games

Defaults for new games: $SYSTEM_CONF and $USER_CONF (KEY=value lines).
EOF
}

case "${1:-}" in
  add) shift && cmd_add "$@" ;;
  run) shift && cmd_run "$@" ;;
  settings) shift && cmd_settings "$@" ;;
  remove) shift && cmd_remove "$@" ;;
  list) cmd_list ;;
  *)
    usage
    exit 1
    ;;
esac
