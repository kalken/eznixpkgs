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

# Shown first when choosing a game's executable. The file dialog also offers all files.
EXE_FILTER='*.exe *.EXE'

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
    zenity) zenity --entry --title ezlaunch --width 480 --text "$1" --entry-text "$2" ;;
    kdialog) kdialog --title ezlaunch --inputbox "$1" "$2" ;;
    *)
      read -r -p "$1 [$2] " reply
      echo "${reply:-$2}"
      ;;
  esac
}

ask_file() { # prompt, start folder, [glob patterns to list first]
  local reply filter=() kfilter=()
  if [ -n "${3:-}" ]; then
    filter=(--file-filter "Windows programs | $3" --file-filter "All files | *")
    kfilter=("$3|Windows programs"$'\n'"*|All files")
  fi
  case $GUI in
    zenity) zenity --file-selection --title "$1" --filename "$2" "${filter[@]}" ;;
    kdialog) kdialog --title "$1" --getopenfilename "$2" "${kfilter[@]}" ;;
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
    zenity) printf '%s\n' "$2" | zenity --text-info --editable --title "$1" --width 700 --height 450 ;;
    kdialog) kdialog --title ezlaunch --textinputbox "$1" "$2" 700 450 ;;
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
      zenity --list --checklist --title ezlaunch --text "$prompt" --width 640 --height 640 \
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
      zenity --list --radiolist --title ezlaunch --text "$prompt" --width 520 --height 480 \
        --column "" --column Choice "${args[@]}"
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

# Arrow-key menu of the games, for commands given no name
pick_game() { # [list of games, default all]
  local games=${1:-}
  if [ -z "$games" ]; then games=$(game_names); fi
  [ -n "$games" ] || die "no games to choose from"
  { [ -t 0 ] && [ -t 2 ]; } || die "game name missing"
  fzf --height 40% --reverse --prompt "game> " <<<"$games"
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

ico_to_png() { # ico, output png
  local tmp png
  tmp=$(mktemp -d)
  icotool -x -o "$tmp" "$1" 2>/dev/null || true
  png=$(find "$tmp" -name '*.png' -printf '%s %p\n' | sort -rn | sed -n 1p | cut -d' ' -f2-)
  if [ -n "$png" ]; then cp "$png" "$2"; fi
  rm -rf "$tmp"
}

extract_icon() { # exe, output png
  local tmp ico
  tmp=$(mktemp -d)
  wrestool -x -t14 -o "$tmp" "$1" 2>/dev/null || true
  ico=$(find "$tmp" -name '*.ico' | sort | sed -n 1p)
  if [ -n "$ico" ]; then ico_to_png "$ico" "$2"; fi
  rm -rf "$tmp"
}

# The game's icon file, or a generic icon name if it has none
icon_for() { # game dir
  local file
  file=$(find "$1" -maxdepth 1 -name 'icon.*' | sed -n 1p)
  echo "${file:-applications-games}"
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
Actions=settings;stop;remove;

[Desktop Action settings]
Name=Settings
Exec=ezlaunch settings "$1"

[Desktop Action stop]
Name=Stop
Exec=ezlaunch stop "$1"

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

  exe=$(ask_file "Choose the game executable" "$dir/prefix/drive_c/" "$EXE_FILTER")
  [ -f "$exe" ] || die "not a file: $exe"

  icon=applications-games
  extract_icon "$exe" "$dir/icon.png"
  if [ -f "$dir/icon.png" ]; then icon="$dir/icon.png"; fi

  printf 'EZLAUNCH_EXE=%s\n' "$exe" >>"$dir/config"
  write_desktop "$name" "$icon"
  info "Added $name to the start menu."
}

cmd_exe() { # name
  local name=${1:-} dir exe icon
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  dir="$GAMES/$name"
  [ -f "$dir/config" ] || die "unknown game: $name"
  [ -n "$GUI" ] || die "this needs a graphical session. Edit EZLAUNCH_EXE in $dir/config instead."

  exe=$(getv EZLAUNCH_EXE "$dir/config")
  exe=$(ask_file "Choose the game executable" "$(dirname "${exe:-$dir/prefix/drive_c/x}")/" "$EXE_FILTER")
  [ -f "$exe" ] || die "not a file: $exe"

  rm -f "$dir"/icon.*
  extract_icon "$exe" "$dir/icon.png"

  { grep -v '^EZLAUNCH_EXE=' "$dir/config" || true; } >"$dir/config.new"
  printf 'EZLAUNCH_EXE=%s\n' "$exe" >>"$dir/config.new"
  mv "$dir/config.new" "$dir/config"
  # Also gives a game added earlier the current menu actions
  write_desktop "$name" "$(icon_for "$dir")"
  info "$name now starts $(basename "$exe")."
}

cmd_icon() { # name
  local name=${1:-} dir src new
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  dir="$GAMES/$name"
  [ -f "$dir/config" ] || die "unknown game: $name"
  [ -n "$GUI" ] || die "this needs a graphical session"

  src=$(ask_file "Choose an icon (image, .ico or .exe)" "$HOME/")
  [ -f "$src" ] || die "not a file: $src"
  case "${src,,}" in
    *.png | *.svg | *.xpm)
      new="$dir/new-icon.${src##*.}"
      cp "$src" "$new"
      ;;
    *.ico)
      new="$dir/new-icon.png"
      ico_to_png "$src" "$new"
      ;;
    *)
      new="$dir/new-icon.png"
      extract_icon "$src" "$new"
      ;;
  esac
  [ -f "$new" ] || die "no icon found in $src"
  rm -f "$dir"/icon.*
  mv "$new" "$dir/icon.${new##*.}"
  write_desktop "$name" "$(icon_for "$dir")"
  info "Changed the icon of $name."
}

cmd_run() { # name, args...
  local name=${1:-} dir
  shift || true
  if [ -z "$name" ]; then name=$(pick_game); fi
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

settings_options() { # name
  local name=${1:-} cfg
  if [ -z "$name" ]; then name=$(pick_game); fi
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

  local custom
  custom=$({ grep -Ev "^($managed)=" "$cfg" || true; })
  custom=$(ask_edit "Custom variables (KEY=value, one per line)" "$custom")

  {
    echo "EZLAUNCH_EXE=$(getv EZLAUNCH_EXE "$cfg")"
    # The Proton version is set in its own dialog, keep it
    if grep -q '^PROTONPATH=' "$cfg"; then echo "PROTONPATH=$(getv PROTONPATH "$cfg")"; fi
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

settings_proton() { # name
  local name=$1 cfg="$GAMES/$1/config" current version dir versions=() pairs=()
  current=$(getv PROTONPATH "$SYSTEM_CONF" "$USER_CONF" "$cfg")
  for dir in "$TOOLS"/*/; do
    if [ -d "$dir" ]; then versions+=("$(basename "$dir")"); fi
  done
  if [ -n "$current" ] && [[ ! " ${versions[*]} " == *" $current "* ]]; then versions+=("$current"); fi
  [ ${#versions[@]} -gt 0 ] || die "no Proton found in $TOOLS. Install one with ezproton."
  for dir in "${versions[@]}"; do
    if [ "$dir" = "$current" ]; then pairs+=("$dir" on); else pairs+=("$dir" off); fi
  done
  version=$(ask_radio "Proton version for $name" "${pairs[@]}")

  { grep -v '^PROTONPATH=' "$cfg" || true; } >"$cfg.new"
  # Only a version other than the default is saved for the game
  if [ "$version" != "$(getv PROTONPATH "$SYSTEM_CONF" "$USER_CONF")" ]; then
    echo "PROTONPATH=$version" >>"$cfg.new"
  fi
  mv "$cfg.new" "$cfg"
  info "$name now uses $version."
}

cmd_settings() { # [name]
  local name=${1:-} choice
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  [ -f "$GAMES/$name/config" ] || die "unknown game: $name"
  [ -n "$GUI" ] || die "settings needs a graphical session. Edit $GAMES/$name/config instead."

  choice=$(ask_radio "Settings for $name" "Options" on "Proton version" off "Change executable" off "Change icon" off)
  case $choice in
    "Proton version") settings_proton "$name" ;;
    "Change executable") cmd_exe "$name" ;;
    "Change icon") cmd_icon "$name" ;;
    *) settings_options "$name" ;;
  esac
}

cmd_remove() { # name
  local name=${1:-}
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  [ -f "$GAMES/$name/config" ] || die "unknown game: $name"
  ask_yesno "Remove $name? Its prefix, with saved games inside it, is deleted." || exit 0
  rm -rf "${GAMES:?}/$name"
  rm -f "$(desktop_file "$name")"
  refresh_menu
}

# Process IDs whose environment holds the prefix of a game, which is every process it started
game_pids() { # name
  local prefix="$GAMES/$1/prefix" file
  for file in /proc/[0-9]*/environ; do
    if grep -zqxF -- "WINEPREFIX=$prefix" "$file" 2>/dev/null; then
      file=${file#/proc/}
      echo "${file%/environ}"
    fi
  done
}

cmd_running() {
  local name
  while IFS= read -r name; do
    if [ -n "$(game_pids "$name")" ]; then echo "$name"; fi
  done < <(game_names)
}

cmd_stop() { # [name]
  local name=${1:-} pids running
  if [ -z "$name" ]; then
    running=$(cmd_running)
    [ -n "$running" ] || die "no games running"
    name=$(pick_game "$running")
  fi
  check_name "$name"
  [ -f "$GAMES/$name/config" ] || die "unknown game: $name"
  pids=$(game_pids "$name")
  [ -n "$pids" ] || die "$name is not running"

  # Ask nicely, then kill what is left after five seconds
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    sleep 1
    pids=$(game_pids "$name")
    if [ -z "$pids" ]; then break; fi
  done
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
  fi
  echo "ezlaunch: stopped $name"
}

game_names() {
  local dir
  for dir in "$GAMES"/*/; do
    if [ -f "$dir/config" ]; then basename "$dir"; fi
  done
}

cmd_list() {
  local name
  while IFS= read -r name; do
    if [ -n "$(game_pids "$name")" ]; then echo "$name (running)"; else echo "$name"; fi
  done < <(game_names)
}

usage() {
  cat <<EOF
Usage: ezlaunch <command>

  add [installer.exe]   run an installer in a new prefix and add the game to the start menu
  run [game] [args]     start a game
  settings [game]       options, Proton version, executable and icon of a game
  exe [game]            choose another executable for a game
  icon [game]           choose another icon for a game
  remove [game]         delete a game, its prefix and its start menu entry
  list                  list the games, marking the ones that are running
  running               list the games that are running
  stop [game]           close a running game

Without a game name, run, settings, exe, icon, remove and stop show a menu to choose from.

Defaults for new games: $SYSTEM_CONF and $USER_CONF (KEY=value lines).
EOF
}

case "${1:-}" in
  add) shift && cmd_add "$@" ;;
  run) shift && cmd_run "$@" ;;
  settings) shift && cmd_settings "$@" ;;
  exe) shift && cmd_exe "$@" ;;
  icon) shift && cmd_icon "$@" ;;
  remove) shift && cmd_remove "$@" ;;
  list) cmd_list ;;
  running) cmd_running ;;
  stop) shift && cmd_stop "$@" ;;
  *)
    usage
    exit 1
    ;;
esac
