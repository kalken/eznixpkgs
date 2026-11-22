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

# Dialogs are yad. Without a display the questions are asked in the terminal.
GUI=
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v yad >/dev/null; then GUI=yad; fi

msg() {
  echo "ezlaunch: $*" >&2
  if [ -n "$GUI" ]; then
    yad --title ezlaunch --text "$*" --no-markup --image dialog-error --center --width 420 \
      --button OK:0 || true
  fi
}

die() {
  msg "$*"
  exit 1
}

info() {
  echo "ezlaunch: $*"
  if [ -n "$GUI" ]; then
    yad --title ezlaunch --text "$*" --no-markup --image dialog-information --center --width 420 \
      --button OK:0 || true
  fi
}

ask_file() { # prompt, start folder, [glob patterns to list first]
  local reply filter=()
  if [ -n "${3:-}" ]; then
    filter=(--file-filter "Windows programs | $3" --file-filter "All files | *")
  fi
  if [ -n "$GUI" ]; then
    yad --file --title "$1" --filename "$2" --center --width 900 --height 600 "${filter[@]}"
  else
    read -r -p "$1: " reply
    echo "$reply"
  fi
}

ask_yesno() { # question
  local reply
  if [ -n "$GUI" ]; then
    yad --title ezlaunch --text "$1" --no-markup --center --width 420 --button No:1 --button Yes:0
  else
    read -r -p "$1 [y/N] " reply
    [ "$reply" = y ]
  fi
}

# The installed Proton versions as a yad combo box list, the current one first
proton_choices() { # current
  local list="${1:+^$1}" version
  for version in "$TOOLS"/*/; do
    [ -d "$version" ] || continue
    version=$(basename "$version")
    if [ "$version" != "$1" ]; then list+="${list:+!}$version"; fi
  done
  echo "$list"
}

# Installer or a game that is already installed? Prints install or installed, then | and the
# chosen Proton version (empty if there is nothing to choose).
ask_mode() { # question, current Proton version
  local reply rc=0 choices
  if [ -n "$GUI" ]; then
    choices=$(proton_choices "$2")
    if [ -n "$choices" ]; then
      # yad shows the buttons in the order given: Cancel on the left, Install on the right
      reply=$(yad --form --title ezlaunch --text "$1" --no-markup --center --width 320 \
        --field "Proton version:CB" "$choices" \
        --buttons-layout edge --button Cancel:1 --button Add:2 --button Install:0) || rc=$?
      reply=${reply%%|*}
    else
      yad --title ezlaunch --text "$1" --no-markup --center --width 320 \
        --buttons-layout edge --button Cancel:1 --button Add:2 --button Install:0 || rc=$?
      reply=
    fi
    case $rc in
      0) echo "install|$reply" ;;
      2) echo "installed|$reply" ;;
      *) return 1 ;;
    esac
  else
    read -r -p "$1 [i]nstaller or [a]lready installed? " reply
    case $reply in
      i*) echo "install|" ;;
      a*) echo "installed|" ;;
      *) return 1 ;;
    esac
  fi
}

# Arrow-key menu of the games, for commands given no name
pick_game() { # [list of games, default all]
  local games=${1:-}
  if [ -z "$games" ]; then games=$(game_names); fi
  [ -n "$games" ] || die "no games to choose from"
  { [ -t 0 ] && [ -t 2 ]; } || die "game name missing"
  fzf --height 40% --reverse --border rounded --no-info --pointer ">" --prompt "> " \
    --header "Choose a game (arrows to move, Enter to select)" <<<"$games"
}

check_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*$ ]] || die "invalid game name: $1"
}

desktop_file() { # name
  local id
  id=$(basename "$(game_dir "$1")")
  echo "$APPS/ezlaunch-${id// /_}.desktop"
}

refresh_menu() {
  if [ -n "${NO_REFRESH:-}" ]; then return 0; fi
  update-desktop-database "$APPS" 2>/dev/null || true
}

# Last value of a KEY=value line in the given files, empty if there is none.
getv() { # key, files...
  local key=$1
  shift
  { grep -hs "^$key=" "$@" || true; } | tail -n1 | cut -d= -f2-
}

# The name of a game is a line in its config. A game added before that was named by its folder.
game_label() { # game dir
  local label
  label=$(getv EZLAUNCH_NAME "$1/config")
  echo "${label:-$(basename "$1")}"
}

# The folder of the game with this name, or fail
game_dir() { # name
  local dir
  for dir in "$GAMES"/*/; do
    dir=${dir%/}
    [ -f "$dir/config" ] || continue
    if [ "$(game_label "$dir")" = "$1" ]; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}

clean_name() {
  printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._-' | sed 's/^[^A-Za-z0-9]*//; s/ *$//'
}

# The name, or the name with 2, 3 and so on after it when a game has it already
unique_name() { # name
  local name=$1 n=2
  while game_dir "$name" >/dev/null; do
    name="$1 $n"
    n=$((n + 1))
  done
  echo "$name"
}

# The same file always gives the same checksum, wherever it is. Only the start of a big file is read.
file_checksum() { # file
  { head -c 16777216 "$1"; stat -c %s "$1"; } | sha256sum | cut -c1-16
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
  # A controller does not count as activity for the idle timer, so keep the screen awake
  # while the game runs. kde-inhibit on KDE, which ignores systemd's idle lock.
  local inhibit=()
  if [ "${EZLAUNCH_INHIBIT:-1}" != 0 ]; then
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]] && command -v kde-inhibit >/dev/null; then
      inhibit=(kde-inhibit --power --screenSaver)
    elif command -v systemd-inhibit >/dev/null; then
      inhibit=(systemd-inhibit --what=idle --who=ezlaunch "--why=Playing a game")
    fi
  fi
  # With a tray icon, stay alive while the game runs and remove the icon when it ends.
  # The icon has no WINEPREFIX, so its menu commands are not counted as the game.
  # yad has no tray icon on Wayland, so it runs through XWayland.
  if [ -n "${TRAY_NAME:-}" ]; then
    local status=0
    env -u WINEPREFIX GDK_BACKEND=x11 yad --notification --image "$TRAY_ICON" --text "$TRAY_NAME" --command menu \
      --menu "Stop!ezlaunch stop \"$TRAY_NAME\"|Settings!ezlaunch settings \"$TRAY_NAME\"" &
    TRAY_PID=$!
    trap 'kill "$TRAY_PID" 2>/dev/null || true' EXIT
    trap 'exit 143' TERM INT HUP
    # EZLAUNCH_WRAPPER is a command prefix, such as gamemoderun
    # shellcheck disable=SC2086
    "${inhibit[@]}" ${EZLAUNCH_WRAPPER:-} umu-run "$@" || status=$?
    exit "$status"
  fi
  # shellcheck disable=SC2086
  exec "${inhibit[@]}" ${EZLAUNCH_WRAPPER:-} umu-run "$@"
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
Actions=settings;exec;remove;

[Desktop Action settings]
Name=Settings
Exec=ezlaunch settings "$1"

[Desktop Action exec]
Name=Run a program in this prefix
Exec=ezlaunch exec "$1"

[Desktop Action remove]
Name=Remove
Exec=ezlaunch remove "$1"
EOF
  refresh_menu
}

# Pick one of the installed Proton versions, the default marked. Prints nothing without a choice.
ask_proton() { # current
  local rows=() version
  [ -n "$GUI" ] || return 0
  for version in "$TOOLS"/*/; do
    [ -d "$version" ] || continue
    version=$(basename "$version")
    if [ "$version" = "$1" ]; then rows+=(TRUE "$version"); else rows+=(FALSE "$version"); fi
  done
  [ "${#rows[@]}" -gt 0 ] || return 0
  yad --list --radiolist --title ezlaunch --text "Proton version" --center --width 420 \
    --height 360 --column "" --column Version --print-column 2 --separator '' \
    --button Cancel:1 --button OK:0 "${rows[@]}"
}

# The games an installer left shortcuts for, as lines of name|exe. The shortcuts are the .lnk
# files in the prefix's Start Menu and on its desktop. Uninstallers are left out.
shortcut_games() { # prefix
  local prefix=$1 lnk name target drive base exe seen=$'\n'
  while IFS= read -r -d '' lnk; do
    name=$(basename "$lnk")
    name=${name%.[Ll][Nn][Kk]}
    if [[ "${name,,}" == *uninstall* ]]; then continue; fi
    # The target is stored as a plain Windows path, such as C:\Games\Some Game\game.exe
    target=$(LC_ALL=C grep -aoE '[A-Za-z]:\\([^\\/:*?"<>|[:cntrl:]]+\\)*[^\\/:*?"<>|[:cntrl:]]+\.[Ee][Xx][Ee]' "$lnk" | head -n1) || true
    [ -n "$target" ] || continue
    drive=${target:0:1}
    base="$prefix/dosdevices/${drive,,}:"
    exe="$base/${target:3}"
    exe=${exe//\\//}
    # Windows paths do not care about upper and lower case
    if [ ! -f "$exe" ]; then
      exe=$(find -L "$base" -ipath "$exe" -print -quit 2>/dev/null) || true
    fi
    [ -f "$exe" ] || continue
    exe=$(readlink -f "$exe")
    if [[ "$(basename "${exe,,}")" == unins*.exe ]]; then continue; fi
    if [[ "$seen" == *$'\n'"$exe"$'\n'* ]]; then continue; fi
    seen+="$exe"$'\n'
    printf '%s|%s\n' "$name" "$exe"
  done < <(find "$prefix/drive_c/ProgramData" "$prefix/drive_c/users" -iname '*.lnk' \
    \( -ipath '*/start menu/*' -o -ipath '*/desktop/*' \) -print0 2>/dev/null)
}

# The name that goes with an exe in lines of name|exe
shortcut_name() { # lines of name|exe, exe
  local line
  while IFS= read -r line; do
    if [ "${line#*|}" = "$2" ]; then
      echo "${line%%|*}"
      return 0
    fi
  done <<<"$1"
}

# Which of the games is the one? Prints its exe, or nothing to pick a file by hand.
pick_shortcut() { # lines of name|exe
  local rows=() line count
  count=$(printf '%s\n' "$1" | wc -l)
  if [ "$count" = 1 ] || [ -z "$GUI" ]; then
    printf '%s\n' "$1" | head -n1 | cut -d'|' -f2-
    return 0
  fi
  while IFS= read -r line; do
    rows+=("${line%%|*}" "${line#*|}")
  done <<<"$1"
  local rc=0 reply
  reply=$(yad --list --title ezlaunch --text "Which one is the game?" --center --width 560 \
    --height 320 --column Name --column Executable --print-column 2 --separator '' \
    --button Cancel:1 --button "Other file:3" --button OK:0 "${rows[@]}") || rc=$?
  case $rc in
    0) echo "$reply" ;;
    3) ;;
    *) return 1 ;;
  esac
}

cmd_add() { # [--install | --installed] [--choose-proton] [exe]
  local mode='' installer name dir exe icon version='' reply picked='' choose='' games='' checksum id n
  while true; do
    case "${1:-}" in
      --install) mode=install ;;
      --installed) mode=installed ;;
      --choose-proton) choose=1 ;;
      *) break ;;
    esac
    shift
  done
  installer=${1:-}
  if [ -z "$installer" ]; then
    installer=$(ask_file "Choose the installer or the game executable" "$HOME/" "$EXE_FILTER")
  fi
  [ -f "$installer" ] || die "not a file: $installer"
  installer=$(readlink -f "$installer")

  if [ -z "$mode" ]; then
    reply=$(ask_mode "Is $(basename "$installer") an installer or a game to add?" \
      "$(getv PROTONPATH "$SYSTEM_CONF" "$USER_CONF")") || exit 1
    mode=${reply%%|*}
    version=${reply#*|}
    picked=1
  fi

  # The folder of a game is named after its file, so the same file is not added twice. A game
  # that was renamed does not count, and gets a folder of its own.
  checksum=$(file_checksum "$installer")
  id=$checksum
  n=2
  while [ -e "$GAMES/$id" ]; do
    if grep -qs '^EZLAUNCH_SOURCE=' "$GAMES/$id/config"; then
      die "already added as $(game_label "$GAMES/$id")"
    fi
    id="$checksum-$n"
    n=$((n + 1))
  done

  # Without the combined dialog above the default is used, unless --choose-proton asks for it
  if [ -z "$picked" ] && [ -n "$choose" ]; then
    version=$(ask_proton "$(getv PROTONPATH "$SYSTEM_CONF" "$USER_CONF")") || exit 1
  fi

  dir="$GAMES/$id"
  mkdir -p "$dir/prefix"
  touch "$dir/config"
  # A game that did not get as far as having an executable is not kept
  # shellcheck disable=SC2064
  trap "if ! grep -qs '^EZLAUNCH_EXE=' '$dir/config'; then rm -rf '$dir'; fi" EXIT
  if [ -n "$version" ]; then apply_proton "$dir" "$version"; fi

  name=
  if [ "$mode" = installed ]; then
    # A game that is already on the disk is run from where it is
    exe=$installer
  else
    (
      load_files "$SYSTEM_CONF" "$USER_CONF" "$dir/config"
      WINEPREFIX="$dir/prefix"
      cd "$(dirname "$installer")" || exit 1
      launch "$installer"
    ) || true

    # The shortcuts the installer made tell which file is the game, and what it is called
    exe=
    games=$(shortcut_games "$dir/prefix")
    if [ -n "$games" ]; then
      exe=$(pick_shortcut "$games") || exit 1
      name=$(shortcut_name "$games" "$exe")
    fi
    if [ -z "$exe" ]; then
      exe=$(ask_file "Choose the game executable" "$dir/prefix/drive_c/" "$EXE_FILTER")
    fi
    [ -f "$exe" ] || die "not a file: $exe"
  fi

  # Without a shortcut the game is called after the folder its exe is in
  if [ -z "$name" ]; then name=$(basename "$(dirname "$exe")"); fi
  name=$(clean_name "$name")
  if [ -z "$name" ]; then name=$(clean_name "$(basename "${exe%.*}")"); fi
  if [ -z "$name" ]; then name=Game; fi
  name=$(unique_name "$name")

  icon=applications-games
  extract_icon "$exe" "$dir/icon.png"
  if [ -f "$dir/icon.png" ]; then icon="$dir/icon.png"; fi

  {
    printf 'EZLAUNCH_NAME=%s\n' "$name"
    printf 'EZLAUNCH_SOURCE=%s\n' "$checksum"
    printf 'EZLAUNCH_EXE=%s\n' "$exe"
  } >>"$dir/config"
  write_desktop "$name" "$icon"
  info "Added $name to the start menu."
}

# The apply_ functions change one part of a game's config. They do not ask anything.

# Make exe the game's executable, with the icon taken from it
apply_exe() { # game dir, exe
  local dir=$1
  rm -f "$dir"/icon.*
  extract_icon "$2" "$dir/icon.png"
  { grep -v '^EZLAUNCH_EXE=' "$dir/config" || true; } >"$dir/config.new"
  printf 'EZLAUNCH_EXE=%s\n' "$2" >>"$dir/config.new"
  mv "$dir/config.new" "$dir/config"
}

apply_icon() { # game dir, an image, .ico or .exe
  local dir=$1 src=$2 new
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
}

apply_proton() { # game dir, version
  local cfg="$1/config"
  { grep -v '^PROTONPATH=' "$cfg" || true; } >"$cfg.new"
  # Only a version other than the default is saved for the game
  if [ "$2" != "$(getv PROTONPATH "$SYSTEM_CONF" "$USER_CONF")" ]; then
    echo "PROTONPATH=$2" >>"$cfg.new"
  fi
  mv "$cfg.new" "$cfg"
}

apply_options() { # game dir, checked keys one per line, custom variables
  local selected=$2 custom=$3 cfg="$1/config"
  local inherited=("$SYSTEM_CONF" "$USER_CONF") entry key on off label
  {
    # The name, the file it came from and the executable have their own places, keep them
    for key in EZLAUNCH_NAME EZLAUNCH_SOURCE EZLAUNCH_EXE; do
      if grep -q "^$key=" "$cfg"; then echo "$key=$(getv "$key" "$cfg")"; fi
    done
    # The Proton version has its own field, keep it
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
}

# Give a game another name. It then counts as its own game, not the one its file made.
apply_name() { # game dir, new name
  local dir=$1 new cfg="$1/config"
  new=$(clean_name "$2")
  [ -n "$new" ] || die "empty game name"
  if [ "$new" != "$(game_label "$dir")" ]; then
    if game_dir "$new" >/dev/null; then die "there is already a game called $new"; fi
    { grep -Ev '^(EZLAUNCH_NAME|EZLAUNCH_SOURCE)=' "$cfg" || true; } >"$cfg.new"
    echo "EZLAUNCH_NAME=$new" >>"$cfg.new"
    mv "$cfg.new" "$cfg"
  fi
}

# Write the start menu entry of every game again, so they follow this version of ezlaunch
refresh_entries() {
  local name dir
  NO_REFRESH=1
  while IFS= read -r name; do
    dir=$(game_dir "$name")
    if grep -qs '^EZLAUNCH_EXE=' "$dir/config"; then write_desktop "$name" "$(icon_for "$dir")"; fi
  done < <(game_names)
  NO_REFRESH=
  refresh_menu
  mkdir -p "$DATA/ezlaunch"
  readlink -f "$0" >"$DATA/ezlaunch/refreshed-by"
}

# Only when this is not the build that wrote the entries last
refresh_entries_if_new() {
  if [ "$(cat "$DATA/ezlaunch/refreshed-by" 2>/dev/null || true)" = "$(readlink -f "$0")" ]; then
    return 0
  fi
  refresh_entries
}

cmd_run() { # name, args...
  local name=${1:-} dir
  shift || true
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  dir=$(game_dir "$name") || die "unknown game: $name"
  refresh_entries_if_new
  load_files "$SYSTEM_CONF" "$USER_CONF" "$dir/config"
  [ -n "${EZLAUNCH_EXE:-}" ] || die "$name has no executable set"
  WINEPREFIX="$dir/prefix"
  # launch shows the game in the tray with these
  if [ "${EZLAUNCH_TRAY:-1}" != 0 ] && [ -n "$GUI" ] && command -v yad >/dev/null; then
    TRAY_NAME=$name
    TRAY_ICON=$(icon_for "$dir")
  fi
  cd "$(dirname "$EZLAUNCH_EXE")" || exit 1
  # EZLAUNCH_ARGS is a list of arguments for the game
  # shellcheck disable=SC2086
  launch "$EZLAUNCH_EXE" ${EZLAUNCH_ARGS:-} "$@"
}

# All the settings of a game in one window
cmd_settings() { # [name]
  local name=${1:-} dir cfg
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  dir=$(game_dir "$name") || die "unknown game: $name"
  cfg="$dir/config"
  command -v yad >/dev/null || die "settings needs yad. Edit $cfg instead."
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || die "settings needs a graphical session. Edit $cfg instead."

  local all=("$SYSTEM_CONF" "$USER_CONF" "$cfg")
  local fields=() entry key on off label state managed='EZLAUNCH_NAME|EZLAUNCH_SOURCE|EZLAUNCH_EXE|PROTONPATH'
  for entry in "${KNOWN[@]}"; do
    IFS='|' read -r key on off label <<<"$entry"
    state=FALSE
    if [ "$(getv "$key" "${all[@]}")" = "$on" ]; then state=TRUE; fi
    fields+=(--field "$label:CHK" "$state")
    managed+="|$key"
  done

  # The Proton versions that are installed, with the current one marked
  local current versions=() version versions_field=
  current=$(getv PROTONPATH "${all[@]}")
  for version in "$TOOLS"/*/; do
    if [ -d "$version" ]; then versions+=("$(basename "$version")"); fi
  done
  if [ -n "$current" ] && [[ ! " ${versions[*]} " == *" $current "* ]]; then versions+=("$current"); fi
  for version in "${versions[@]}"; do
    if [ "$version" = "$current" ]; then version="^$version"; fi
    versions_field+="${versions_field:+!}$version"
  done

  local current_exe current_icon custom_in
  current_exe=$(getv EZLAUNCH_EXE "$cfg")
  current_icon=$(icon_for "$dir")
  if [ ! -f "$current_icon" ]; then current_icon=; fi
  # yad takes line breaks in a text field as \n
  custom_in=$({ grep -Ev "^($managed)=" "$cfg" || true; })
  custom_in=${custom_in//$'\n'/\\n}

  local out
  out=$(yad --form --title ezlaunch --text "Settings for $name" --width 600 \
    --file-filter "Programs | *.exe *.EXE" \
    --file-filter "Images and icons | *.png *.svg *.ico *.xpm *.exe *.EXE" \
    --file-filter "All files | *" \
    --field "Name:" "$name" \
    "${fields[@]}" \
    --field "Proton version:CB" "$versions_field" \
    --field "Executable:FL" "$current_exe" \
    --field "Icon:FL" "$current_icon" \
    --field "Custom variables, KEY=value one per line:TXT" "$custom_in" \
    --button Cancel:1 --button Save:0 --separator '|') || exit 0

  # One value per field, in order. The custom variables come last and may hold a |.
  local parts=() n=${#KNOWN[@]} i selected='' exe icon custom new_name
  IFS='|' read -ra parts <<<"$out"
  new_name=${parts[0]:-}
  for ((i = 0; i < n; i++)); do
    IFS='|' read -r key _ <<<"${KNOWN[i]}"
    if [ "${parts[i + 1]:-}" = TRUE ]; then selected+="$key"$'\n'; fi
  done
  version=${parts[n + 1]:-}
  exe=${parts[n + 2]:-}
  icon=${parts[n + 3]:-}
  custom=$(
    IFS='|'
    echo "${parts[*]:n+4}"
  )
  custom=${custom//\\n/$'\n'}
  # yad ends the text with a line break, which would add a blank line at every save
  custom=$(printf '%s' "$custom")

  apply_name "$dir" "$new_name"
  name=$(game_label "$dir")
  apply_options "$dir" "$selected" "$custom"
  if [ -n "$version" ]; then apply_proton "$dir" "$version"; fi
  if [ -n "$exe" ] && [ "$exe" != "$current_exe" ]; then
    [ -f "$exe" ] || die "not a file: $exe"
    apply_exe "$dir" "$exe"
  fi
  if [ -n "$icon" ] && [ "$icon" != "$current_icon" ]; then
    [ -f "$icon" ] || die "not a file: $icon"
    apply_icon "$dir" "$icon"
  fi
  write_desktop "$name" "$(icon_for "$dir")"
  info "Saved the settings for $name."
}

cmd_remove() { # name
  local name=${1:-} dir entry
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  dir=$(game_dir "$name") || die "unknown game: $name"
  ask_yesno "Remove $name? Its prefix, with saved games inside it, is deleted." || exit 0
  entry=$(desktop_file "$name")
  rm -rf "${dir:?}"
  rm -f "$entry"
  refresh_menu
}

# Process IDs whose environment holds the prefix of a game, which is every process it started
game_pids() { # name
  local prefix file
  prefix=$(game_dir "$1") || return 0
  prefix="$prefix/prefix"
  for file in /proc/[0-9]*/environ; do
    if grep -zqxF -- "WINEPREFIX=$prefix" "$file" 2>/dev/null; then
      file=${file#/proc/}
      echo "${file%/environ}"
    fi
  done
}

# Run any program in a game's prefix, such as a redistributable installer the game needs
cmd_exec() { # name, [file]
  local name=${1:-} file=${2:-} dir
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  dir=$(game_dir "$name") || die "unknown game: $name"
  if [ -z "$file" ]; then
    file=$(ask_file "Choose the program to run in the prefix of $name" "$HOME/" '*.exe *.EXE *.msi *.MSI')
  fi
  [ -f "$file" ] || die "not a file: $file"
  file=$(readlink -f "$file")
  load_files "$SYSTEM_CONF" "$USER_CONF" "$dir/config"
  WINEPREFIX="$dir/prefix"
  cd "$(dirname "$file")" || exit 1
  launch "$file"
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
  game_dir "$name" >/dev/null || die "unknown game: $name"
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
    dir=${dir%/}
    if [ -f "$dir/config" ]; then game_label "$dir"; fi
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

  add [file.exe]        add a game: an installer is run in a new prefix, a game that is
                        already installed is added as it is. It asks which, unless
                        --install or --installed is given
  add --install [file]  treat the file as an installer
  add --installed [file]
                        treat the file as an installed game, without an installer
  run [game] [args]     start a game
  exec [game] [file]    run a program in a game's prefix, such as a redistributable
  settings [game]       all settings of a game in one window
  remove [game]         delete a game, its prefix and its start menu entry
  list                  list the games, marking the ones that are running
  running               list the games that are running
  stop [game]           close a running game
  refresh [--if-new]    write the start menu entries of all games again (--if-new: only
                        when ezlaunch was updated since they were last written)

Without a game name, run, settings, remove and stop show a menu to choose from.

Defaults for new games: $SYSTEM_CONF and $USER_CONF (KEY=value lines).
EOF
}

case "${1:-}" in
  add) shift && cmd_add "$@" ;;
  run) shift && cmd_run "$@" ;;
  settings) shift && cmd_settings "$@" ;;
  remove) shift && cmd_remove "$@" ;;
  list) cmd_list ;;
  running) cmd_running ;;
  stop) shift && cmd_stop "$@" ;;
  refresh)
    if [ "${2:-}" = --if-new ]; then refresh_entries_if_new; else refresh_entries; fi
    ;;
  exec) shift && cmd_exec "$@" ;;
  *)
    usage
    exit 1
    ;;
esac
