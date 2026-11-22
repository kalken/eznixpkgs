# shellcheck shell=bash
# ezlaunch: install and launch Windows games with Proton (umu-launcher).
# Run with no arguments for usage.

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
GAMES="$DATA/ezlaunch/games"
APPS="$DATA/applications"
MENUS="${XDG_CONFIG_HOME:-$HOME/.config}/menus/applications-merged"
DIRECTORIES="$DATA/desktop-directories"
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

# label|category, where an entry goes in the start menu
CATEGORIES=(
  "Game|Game"
  "Utility|Utility"
  "Office|Office"
  "Internet|Network"
  "Development|Development"
  "Graphics|Graphics"
  "Multimedia|AudioVideo"
  "System|System"
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

ask_text() { # prompt, default
  local reply
  if [ -n "$GUI" ]; then
    yad --entry --title ezlaunch --text "$1" --no-markup --entry-text "$2" --center --width 480 \
      --button Cancel:1 --button OK:0
  else
    read -r -p "$1 [$2] " reply
    echo "${reply:-$2}"
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

# The categories as a yad combo box list, the current one first
category_choices() { # current category
  local entry label value list=
  for entry in "${CATEGORIES[@]}"; do
    IFS='|' read -r label value <<<"$entry"
    if [ "$value" = "$1" ]; then label="^$label"; fi
    list+="${list:+!}$label"
  done
  echo "$list"
}

# The category that goes with a label from the list
category_value() { # label
  local entry label value
  for entry in "${CATEGORIES[@]}"; do
    IFS='|' read -r label value <<<"$entry"
    if [ "$label" = "$1" ]; then
      echo "$value"
      return 0
    fi
  done
  echo Game
}

# The category a game has: its own, else the default, else Game
game_category() { # game config
  local category
  category=$(getv EZLAUNCH_CATEGORY "$SYSTEM_CONF" "$USER_CONF" "$1")
  echo "${category:-Game}"
}

# Installer or a game that is already installed? Prints install or installed, then | the chosen
# Proton version (empty if there is nothing to choose), | the category and | the name.
ask_mode() { # question, current Proton version, current category, suggested name
  local reply rc=0 choices fields=() parts=() version='' category='' name='' sep=$'\x1f' width
  if [ -n "$GUI" ]; then
    choices=$(proton_choices "$2")
    # Wide enough for the whole suggested name
    width=$((${#4} * 9 + 220))
    if [ "$width" -lt 520 ]; then width=520; fi
    if [ "$width" -gt 1600 ]; then width=1600; fi
    fields+=(--field "Name" "$4")
    if [ -n "$choices" ]; then fields+=(--field "Proton version:CB" "$choices"); fi
    fields+=(--field "Category:CB" "$(category_choices "$3")")
    # yad shows the buttons in the order given: Cancel on the left, Install on the right.
    # The fields are told apart by a character nobody types, so a name may hold anything.
    reply=$(yad --form --title ezlaunch --text "$1" --no-markup --center --width "$width" \
      --separator "$sep" "${fields[@]}" \
      --buttons-layout edge --button Cancel:1 --button Add:2 --button Install:0) || rc=$?
    IFS="$sep" read -ra parts <<<"$reply"
    name=${parts[0]:-}
    if [ -n "$choices" ]; then
      version=${parts[1]:-}
      category=$(category_value "${parts[2]:-}")
    else
      category=$(category_value "${parts[1]:-}")
    fi
    case $rc in
      0) echo "install|$version|$category|$name" ;;
      2) echo "installed|$version|$category|$name" ;;
      *) return 1 ;;
    esac
  else
    read -r -p "$1 [i]nstaller or [a]lready installed? " reply
    case $reply in
      i*) echo "install|||" ;;
      a*) echo "installed|||" ;;
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
  echo "$APPS/ezlaunch-${1// /_}.desktop"
}

refresh_menu() {
  update-desktop-database "$APPS" 2>/dev/null || true
  # KDE keeps its own copy of the menu
  if command -v kbuildsycoca6 >/dev/null; then kbuildsycoca6 >/dev/null 2>&1 || true; fi
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
  local name=$1 icon=$2 dir="$GAMES/$1" id category lname lexe licon n=0
  id=${name// /_}
  mkdir -p "$APPS"
  # A game with more than one shortcut gets a menu folder of its own. Otherwise it goes under
  # its category.
  if [ -s "$dir/links" ]; then category="X-ezlaunch-$id"; else category=$(game_category "$dir/config"); fi
  cat >"$(desktop_file "$name")" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Exec=ezlaunch run "$name"
Icon=$icon
Categories=$category;
Terminal=false
Actions=settings;shortcuts;remove;

[Desktop Action settings]
Name=Settings
Exec=ezlaunch settings "$name"

[Desktop Action shortcuts]
Name=Choose shortcuts
Exec=ezlaunch shortcuts "$name"

[Desktop Action remove]
Name=Remove
Exec=ezlaunch remove "$name"
EOF
  # The other shortcuts of the same install, started with their own exe in the same prefix
  rm -f "$APPS/ezlaunch-$id.link-"*.desktop
  if [ -s "$dir/links" ]; then
    while IFS='|' read -r lname lexe; do
      n=$((n + 1))
      licon="$dir/link-$n.png"
      if [ ! -f "$licon" ]; then licon=applications-games; fi
      cat >"$APPS/ezlaunch-$id.link-$n.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$lname
Exec=ezlaunch run "$name" --exe "${lexe//%/%%}"
Icon=$licon
Categories=$category;
Terminal=false
Actions=settings;

[Desktop Action settings]
Name=Settings
Exec=ezlaunch settings "$name"
EOF
    done <"$dir/links"
    mkdir -p "$MENUS" "$DIRECTORIES"
    cat >"$MENUS/ezlaunch-$id.menu" <<EOF
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
 "http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">
<Menu>
  <Name>Applications</Name>
  <Menu>
    <Name>ezlaunch-$id</Name>
    <Directory>ezlaunch-$id.directory</Directory>
    <Include>
      <Category>X-ezlaunch-$id</Category>
    </Include>
  </Menu>
</Menu>
EOF
    cat >"$DIRECTORIES/ezlaunch-$id.directory" <<EOF
[Desktop Entry]
Type=Directory
Name=$name
Icon=$icon
EOF
  else
    rm -f "$MENUS/ezlaunch-$id.menu" "$DIRECTORIES/ezlaunch-$id.directory"
  fi
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


# Which of the shortcuts get a start menu entry? Prints the chosen lines of name|exe. The first
# argument is the lines to choose from. A second one, even an empty one, is the exes that start
# ticked, and also means there is no "Other file" button. Prints nothing to pick a file by hand.
pick_shortcuts() { # lines of name|exe, [exes that start ticked, one per line]
  local rows=() line rc=0 reply picked='' state buttons=(--button Cancel:1)
  [ -n "$1" ] || return 0
  if [ -z "$GUI" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  if [ -z "${2+x}" ]; then buttons+=(--button "Other file:3"); fi
  while IFS= read -r line; do
    state=TRUE
    if [ -n "${2+x}" ] && ! grep -qxF -- "${line#*|}" <<<"$2"; then state=FALSE; fi
    rows+=("$state" "${line%%|*}" "${line#*|}")
  done <<<"$1"
  reply=$(yad --list --checklist --title ezlaunch \
    --text "Which shortcuts go in the start menu?" \
    --center --width 560 --height 320 --column "" --column Name --column Executable \
    --separator '|' "${buttons[@]}" --button OK:0 "${rows[@]}") || rc=$?
  case $rc in
    0) ;;
    3) return 0 ;;
    *) return 1 ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line=${line#TRUE|}
    line=${line%|}
    picked+="$line"$'\n'
  done <<<"$reply"
  printf '%s' "$picked"
}

# Save the shortcuts of a game besides the game itself, with an icon for each
set_links() { # game dir, lines of name|exe
  local dir=$1 lname lexe n=0
  rm -f "$dir/links" "$dir"/link-*.png
  if [ -z "$2" ]; then return 0; fi
  printf '%s\n' "$2" >"$dir/links"
  while IFS='|' read -r lname lexe; do
    n=$((n + 1))
    extract_icon "$lexe" "$dir/link-$n.png"
  done <"$dir/links"
}

cmd_add() { # [--install | --installed] [exe]
  local mode='' installer name='' dir exe icon version='' category='' reply picked='' picks links=''
  case "${1:-}" in
    --install)
      mode=install
      shift
      ;;
    --installed)
      mode=installed
      shift
      ;;
    *) ;;
  esac
  installer=${1:-}
  if [ -z "$installer" ]; then
    installer=$(ask_file "Choose the installer or the game executable" "$HOME/" "$EXE_FILTER")
  fi
  [ -f "$installer" ] || die "not a file: $installer"
  installer=$(readlink -f "$installer")

  if [ -z "$mode" ]; then
    reply=$(ask_mode "Is $(basename "$installer") an installer or a game to add?" \
      "$(getv PROTONPATH "$SYSTEM_CONF" "$USER_CONF")" \
      "$(game_category /dev/null)" \
      "$(basename "$(dirname "$installer")")") || exit 1
    mode=${reply%%|*}
    reply=${reply#*|}
    version=${reply%%|*}
    reply=${reply#*|}
    category=${reply%%|*}
    name=${reply#*|}
    picked=1
  fi

  # Without the dialog above (--install, --installed) the name is asked on its own
  if [ -z "$name" ]; then
    name=$(ask_text "Name of the game" "$(basename "$(dirname "$installer")")")
  fi
  name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9 ._-' | sed 's/^[ .]*//; s/ *$//')
  [ -n "$name" ] || die "empty game name"
  dir="$GAMES/$name"
  if grep -qs '^EZLAUNCH_EXE=' "$dir/config"; then die "already added: $name"; fi

  # Without the combined dialog above (--install, --installed) the version is asked on its own
  if [ -z "$picked" ]; then
    version=$(ask_proton "$(getv PROTONPATH "$SYSTEM_CONF" "$USER_CONF")") || exit 1
  fi

  mkdir -p "$dir/prefix"
  touch "$dir/config"
  if [ -n "$version" ]; then apply_proton "$name" "$version"; fi
  if [ -n "$category" ]; then apply_category "$name" "$category"; fi

  if [ "$mode" = installed ]; then
    # A game that is already on the disk is run from where it is
    exe=$installer
  else
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

    # The shortcuts the installer made tell which files are the game and its programs
    exe=
    picks=$(pick_shortcuts "$(shortcut_games "$dir/prefix")") || exit 1
    if [ -n "$picks" ]; then
      exe=$(sed -n 1p <<<"$picks" | cut -d'|' -f2-)
      links=$(sed -n '2,$p' <<<"$picks")
    fi
    if [ -z "$exe" ]; then
      exe=$(ask_file "Choose the game executable" "$dir/prefix/drive_c/" "$EXE_FILTER")
    fi
    [ -f "$exe" ] || die "not a file: $exe"
  fi

  icon=applications-games
  extract_icon "$exe" "$dir/icon.png"
  if [ -f "$dir/icon.png" ]; then icon="$dir/icon.png"; fi

  printf 'EZLAUNCH_EXE=%s\n' "$exe" >>"$dir/config"
  set_links "$dir" "$links"
  write_desktop "$name" "$icon"
  info "Added $name to the start menu."
}

# The apply_ functions change one part of a game's config. They do not ask anything.

# Make exe the game's executable, with the icon taken from it
apply_exe() { # name, exe
  local dir="$GAMES/$1"
  rm -f "$dir"/icon.*
  extract_icon "$2" "$dir/icon.png"
  { grep -v '^EZLAUNCH_EXE=' "$dir/config" || true; } >"$dir/config.new"
  printf 'EZLAUNCH_EXE=%s\n' "$2" >>"$dir/config.new"
  mv "$dir/config.new" "$dir/config"
}

apply_icon() { # name, an image, .ico or .exe
  local dir="$GAMES/$1" src=$2 new
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

apply_proton() { # name, version
  local cfg="$GAMES/$1/config"
  { grep -v '^PROTONPATH=' "$cfg" || true; } >"$cfg.new"
  # Only a version other than the default is saved for the game
  if [ "$2" != "$(getv PROTONPATH "$SYSTEM_CONF" "$USER_CONF")" ]; then
    echo "PROTONPATH=$2" >>"$cfg.new"
  fi
  mv "$cfg.new" "$cfg"
}

apply_category() { # name, category
  local cfg="$GAMES/$1/config"
  { grep -v '^EZLAUNCH_CATEGORY=' "$cfg" || true; } >"$cfg.new"
  # Only a category other than the default is saved for the game
  if [ "$2" != "$(game_category /dev/null)" ]; then
    echo "EZLAUNCH_CATEGORY=$2" >>"$cfg.new"
  fi
  mv "$cfg.new" "$cfg"
}

apply_options() { # name, checked keys one per line, custom variables
  local selected=$2 custom=$3 cfg="$GAMES/$1/config"
  local inherited=("$SYSTEM_CONF" "$USER_CONF") entry key on off label
  {
    echo "EZLAUNCH_EXE=$(getv EZLAUNCH_EXE "$cfg")"
    # The category has its own field, keep it
    if grep -q '^EZLAUNCH_CATEGORY=' "$cfg"; then echo "EZLAUNCH_CATEGORY=$(getv EZLAUNCH_CATEGORY "$cfg")"; fi
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

cmd_run() { # name, args...
  local name=${1:-} dir
  shift || true
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  dir="$GAMES/$name"
  [ -f "$dir/config" ] || die "unknown game: $name"
  load_files "$SYSTEM_CONF" "$USER_CONF" "$dir/config"
  # --exe starts another program of the same prefix, from its start menu entry
  if [ "${1:-}" = --exe ]; then
    EZLAUNCH_EXE=${2:-}
    shift 2 || true
  fi
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
  dir="$GAMES/$name"
  cfg="$dir/config"
  [ -f "$cfg" ] || die "unknown game: $name"
  command -v yad >/dev/null || die "settings needs yad. Edit $cfg instead."
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || die "settings needs a graphical session. Edit $cfg instead."

  local all=("$SYSTEM_CONF" "$USER_CONF" "$cfg")
  local fields=() entry key on off label state managed='EZLAUNCH_EXE|PROTONPATH|EZLAUNCH_CATEGORY'
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
    "${fields[@]}" \
    --field "Proton version:CB" "$versions_field" \
    --field "Category:CB" "$(category_choices "$(game_category "$cfg")")" \
    --field "Executable:FL" "$current_exe" \
    --field "Icon:FL" "$current_icon" \
    --field "Custom variables, KEY=value one per line:TXT" "$custom_in" \
    --button Cancel:1 --button Save:0 --separator '|') || exit 0

  # One value per field, in order. The custom variables come last and may hold a |.
  local parts=() n=${#KNOWN[@]} i selected='' exe icon custom category
  IFS='|' read -ra parts <<<"$out"
  for ((i = 0; i < n; i++)); do
    IFS='|' read -r key _ <<<"${KNOWN[i]}"
    if [ "${parts[i]:-}" = TRUE ]; then selected+="$key"$'\n'; fi
  done
  version=${parts[n]:-}
  category=$(category_value "${parts[n + 1]:-}")
  exe=${parts[n + 2]:-}
  icon=${parts[n + 3]:-}
  custom=$(
    IFS='|'
    echo "${parts[*]:n+4}"
  )
  custom=${custom//\\n/$'\n'}
  # yad ends the text with a line break, which would add a blank line at every save
  custom=$(printf '%s' "$custom")

  apply_options "$name" "$selected" "$custom"
  if [ -n "$version" ]; then apply_proton "$name" "$version"; fi
  apply_category "$name" "$category"
  if [ -n "$exe" ] && [ "$exe" != "$current_exe" ]; then
    [ -f "$exe" ] || die "not a file: $exe"
    apply_exe "$name" "$exe"
  fi
  if [ -n "$icon" ] && [ "$icon" != "$current_icon" ]; then
    [ -f "$icon" ] || die "not a file: $icon"
    apply_icon "$name" "$icon"
  fi
  write_desktop "$name" "$(icon_for "$dir")"
  info "Saved the settings for $name."
}

cmd_remove() { # name
  local name=${1:-}
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  [ -f "$GAMES/$name/config" ] || die "unknown game: $name"
  ask_yesno "Remove $name? Its prefix, with saved games inside it, is deleted." || exit 0
  rm -rf "${GAMES:?}/$name"
  rm -f "$(desktop_file "$name")" "$APPS/ezlaunch-${name// /_}.link-"*.desktop \
    "$MENUS/ezlaunch-${name// /_}.menu" "$DIRECTORIES/ezlaunch-${name// /_}.directory"
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

# Choose again which shortcuts of a game are in the start menu
cmd_shortcuts() { # [name]
  local name=${1:-} dir found current picks main keep links line listed=
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  dir="$GAMES/$name"
  [ -f "$dir/config" ] || die "unknown game: $name"
  [ -n "$GUI" ] || die "shortcuts needs a graphical session"
  main=$(getv EZLAUNCH_EXE "$dir/config")

  # Every shortcut in the prefix, and the entries the game has even if no shortcut is found
  found=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    found+="$line"$'\n'
    if [ "${line#*|}" = "$main" ]; then listed=1; fi
  done < <(shortcut_games "$dir/prefix")
  if [ -z "$listed" ]; then found="$name|$main"$'\n'"$found"; fi
  if [ -s "$dir/links" ]; then
    while IFS= read -r line; do
      if ! grep -qxF -- "$line" <<<"$found"; then found+="$line"$'\n'; fi
    done <"$dir/links"
  fi
  found=${found%$'\n'}
  current="$main"$'\n'$(cut -d'|' -f2- "$dir/links" 2>/dev/null || true)

  picks=$(pick_shortcuts "$found" "$current") || exit 0
  [ -n "$picks" ] || die "A game needs at least one shortcut. Use Remove to delete the whole game."

  # The game stays what it was if it is still ticked, otherwise the first ticked one takes over
  keep=$main
  if ! grep -qF -- "|$main" <<<"$picks"; then keep=$(sed -n 1p <<<"$picks" | cut -d'|' -f2-); fi
  links=
  while IFS= read -r line; do
    if [ -n "$line" ] && [ "${line#*|}" != "$keep" ]; then links+="$line"$'\n'; fi
  done <<<"$picks"
  links=${links%$'\n'}
  if [ "$keep" != "$main" ]; then apply_exe "$name" "$keep"; fi
  set_links "$dir" "$links"
  write_desktop "$name" "$(icon_for "$dir")"
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

# One window with the games and a button for each thing the commands do
cmd_gui() {
  [ -n "$GUI" ] || die "the window needs a graphical session"
  local name rc rows status
  while true; do
    rows=()
    while IFS= read -r name; do
      status=
      if [ -n "$(game_pids "$name")" ]; then status=running; fi
      rows+=("$name" "$status" "$(getv EZLAUNCH_EXE "$GAMES/$name/config")")
    done < <(game_names)
    rc=0
    name=$(yad --list --title ezlaunch --text "Choose a game, then a button. Add game works without one." \
      --center --width 800 --height 460 --column Game --column Status --column Executable \
      --print-column 1 --separator '' \
      --button Close:1 --button Refresh:60 --button "Add game:10" --button Remove:20 \
      --button "Choose shortcuts:30" --button Settings:40 --button Stop:50 --button Run:0 \
      "${rows[@]}") || rc=$?
    case $rc in
      1 | 252) return 0 ;;
      60) continue ;;
      10)
        "$0" add || true
        continue
        ;;
      *) ;;
    esac
    if [ -z "$name" ]; then
      info "Choose a game first."
      continue
    fi
    # Each is a command of its own, so it works the same as in a terminal
    case $rc in
      0) nohup "$0" run "$name" >/dev/null 2>&1 & ;;
      20) "$0" remove "$name" || true ;;
      30) "$0" shortcuts "$name" || true ;;
      40) "$0" settings "$name" || true ;;
      50) "$0" stop "$name" || true ;;
      *) ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: ezlaunch <command>

  gui                   open a window with the games and buttons for all of this
  add [file.exe]        add a game: an installer is run in a new prefix, a game that is
                        already installed is added as it is. It asks which.
  add --install [file]  treat the file as an installer
  add --installed [file]
                        treat the file as an installed game, without an installer
  run [game] [args]     start a game
  settings [game]       all settings of a game in one window
  shortcuts [game]      choose which of the shortcuts in the game's prefix are in the start menu
  remove [game]         delete a game, its prefix and its start menu entry
  list                  list the games, marking the ones that are running
  running               list the games that are running
  stop [game]           close a running game

Without a game name, run, settings, remove and stop show a menu to choose from.

Defaults for new games: $SYSTEM_CONF and $USER_CONF (KEY=value lines).
EOF
}

case "${1:-}" in
  gui) cmd_gui ;;
  add) shift && cmd_add "$@" ;;
  run) shift && cmd_run "$@" ;;
  settings) shift && cmd_settings "$@" ;;
  shortcuts) shift && cmd_shortcuts "$@" ;;
  remove) shift && cmd_remove "$@" ;;
  list) cmd_list ;;
  running) cmd_running ;;
  stop) shift && cmd_stop "$@" ;;
  *)
    usage
    exit 1
    ;;
esac
