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

# KEY|value when on|value when off|label|tooltip, the options in the settings dialog.
# A tooltip must not hold a | : or !
KNOWN=(
  "PROTON_ENABLE_HDR|1|0|HDR|High dynamic range. Needs Native Wayland and an HDR screen"
  "PROTON_ENABLE_WAYLAND|1|0|Native Wayland|Draw the game with Wayland directly instead of through XWayland"
  "PROTON_USE_NTSYNC|1|0|NTSync|Faster syncing between threads, needs the ntsync kernel module"
  "PROTON_ENABLE_NVAPI|1|0|NVIDIA NVAPI (DLSS)|Lets the game use NVIDIA features such as DLSS. Only for NVIDIA cards"
  "PROTON_USE_WINED3D|1|0|WineD3D instead of DXVK|Older, slower way to run DirectX. Try it if a game shows graphics errors"
  "PROTON_NO_ESYNC|1|0|Disable esync|Try it if a game hangs or crashes"
  "PROTON_NO_FSYNC|1|0|Disable fsync|Try it if a game hangs or crashes"
  "PROTON_LOG|1|0|Proton log|Write a log to the home folder (steam-ID.log), to find out why a game fails"
  "MANGOHUD|1|0|MangoHud overlay|Shows frame rate, CPU and GPU use over the game"
  "EZLAUNCH_WRAPPER|gamemoderun||GameMode|Tunes the system for games while this one runs, needs GameMode installed"
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
  local reply rc=0 choices fields=() parts=() version='' category='' name='' sep=$'\x1f' width prefixes existing
  if [ -n "$GUI" ]; then
    choices=$(proton_choices "$2")
    # Wide enough for the whole suggested name
    width=$((${#4} * 9 + 220))
    if [ "$width" -lt 520 ]; then width=520; fi
    if [ "$width" -gt 1600 ]; then width=1600; fi
    # A new prefix by default. The list also has the ones that exist, to put the program in one.
    prefixes="^$4"
    while IFS= read -r existing; do
      if [ -n "$existing" ] && [ "$existing" != "$4" ]; then prefixes+="!$existing"; fi
    done < <(game_names)
    fields+=(--field "Installation prefix!Type a name for a new prefix, or choose one that exists to put the program in it. Proton version and Category are only for a new prefix:CBE" "$prefixes")
    if [ -n "$choices" ]; then fields+=(--field "Proton version!The Proton the game runs with. Can be changed later in Settings:CB" "$choices"); fi
    fields+=(--field "Category!Where the game goes in the start menu:CB" "$(category_choices "$3")")
    # yad shows the buttons in the order given: Cancel on the left, Install on the right.
    # The fields are told apart by a character nobody types, so a name may hold anything.
    reply=$(yad --form --title ezlaunch --text "$1" --no-markup --center --width "$width" \
      --separator "$sep" "${fields[@]}" \
      --buttons-layout edge --button Cancel:1 \
      --button "Add!!The game is already installed. Run it from where it is:2" \
      --button "Install!!Run this installer in a new prefix, then choose the game exe:0") || rc=$?
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
  local name=$1 icon=$2 dir="$GAMES/$1" id category title lname lexe licon n=0
  id=${name// /_}
  # The entry is named after the Windows shortcut it came from, if there was one
  title=$(getv EZLAUNCH_TITLE "$dir/config")
  mkdir -p "$APPS"
  # A game with more than one shortcut gets a menu folder of its own. Otherwise it goes under
  # its category.
  if [ -s "$dir/links" ]; then category="X-ezlaunch-$id"; else category=$(game_category "$dir/config"); fi
  cat >"$(desktop_file "$name")" <<EOF
[Desktop Entry]
Type=Application
Name=${title:-$name}
Exec=ezlaunch run "$name"
Icon=$icon
Categories=$category;
Terminal=false
Actions=settings;shortcuts;rename;remove;

[Desktop Action settings]
Name=Settings
Exec=ezlaunch settings "$name"

[Desktop Action shortcuts]
Name=Choose shortcuts
Exec=ezlaunch shortcuts "$name"

[Desktop Action rename]
Name=Rename prefix
Exec=ezlaunch rename "$name"

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


# A program's path as it is easiest to read: C:\Game\game.exe inside a prefix, ~/... in the home
short_path() { # exe
  local exe=$1 rest
  if [[ "$exe" == "$GAMES"/*/prefix/drive_c/* ]]; then
    rest=${exe#"$GAMES"/*/prefix/drive_c/}
    echo "C:\\${rest//\//\\}"
  elif [[ "$exe" == "$HOME"/* ]]; then
    # A ~ to show, not to expand
    # shellcheck disable=SC2088
    echo "~/${exe#"$HOME"/}"
  else
    echo "$exe"
  fi
}

# Which of the shortcuts get a start menu entry? Prints the chosen lines of name|exe. The first
# argument is the lines to choose from. A second one, even an empty one, is the exes that start
# ticked, and also means there is no "Other file" button. Prints nothing to pick a file by hand.
# A name emptied in the list, or chosen with Original name, gets its own name back (own_name).
pick_shortcuts() { # lines of name|exe, [exes that start ticked, one per line]
  local rows=() line rc=0 reply picked='' state buttons=(--button Cancel:1) lname lshort lexe
  local sel self chosen
  local -A listed_as=()
  [ -n "$1" ] || return 0
  if [ -z "$GUI" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  if [ -z "${2+x}" ]; then buttons+=(--button "Other file:3"); fi
  while IFS= read -r line; do
    state=TRUE
    if [ -n "${2+x}" ] && ! grep -qxF -- "${line#*|}" <<<"$2"; then state=FALSE; fi
    rows+=("$state" "${line%%|*}" "$(short_path "${line#*|}")" "${line#*|}")
    listed_as[${line#*|}]=${line%%|*}
  done <<<"$1"

  # The chosen row is written to a file, so Original name knows which one it is. Original name
  # closes the list and opens it again with that name changed and the rest as it was.
  sel=$(mktemp)
  self=$(readlink -f "$0")
  while true; do
    : >"$sel"
    rc=0
    reply=$(yad --list --checklist --title ezlaunch \
      --text "Which shortcuts go in the start menu? Double-click a name to change it." \
      --editable --editable-cols 2 --print-all --select-action "'$self' _select '$sel'" \
      --center --width 560 --height 320 --column "" --column Name --column Program --column Path:HD \
      --separator '|' "${buttons[@]}" \
      --button "Original name!!Give the chosen shortcut back the name of its Windows shortcut:4" \
      --button OK:0 "${rows[@]}") || rc=$?
    case $rc in
      0 | 4) ;;
      3)
        rm -f "$sel"
        return 0
        ;;
      *)
        rm -f "$sel"
        return 1
        ;;
    esac
    chosen=$(cat "$sel")
    rows=()
    picked=
    while IFS='|' read -r state lname lshort lexe _; do
      # Rows added with the right-click menu have no program
      if [ -z "$lexe" ] || [ ! -f "$lexe" ]; then continue; fi
      if [ -z "$lname" ] || { [ "$rc" = 4 ] && [ "$lexe" = "$chosen" ]; }; then
        lname=$(own_name "$lexe")
      fi
      rows+=("$state" "$lname" "$lshort" "$lexe")
      if [ "$state" = TRUE ]; then picked+="$lname|$lexe"$'\n'; fi
    done <<<"$reply"
    if [ "$rc" = 0 ]; then break; fi
    # The list goes to stdout, so the message must not
    if [ -z "$chosen" ]; then info "Choose a shortcut first." >&2; fi
  done
  rm -f "$sel"
  printf '%s' "$picked"
}

# The name a shortcut has of its own: its Windows shortcut's, from the caller's own_names
# (exe => name), or without own_names the name it was listed with, else the exe's file name
own_name() { # exe
  local name
  if [ -n "${own_names[$1]+x}" ]; then
    echo "${own_names[$1]}"
  elif ! declare -p own_names >/dev/null 2>&1 && [ -n "${listed_as[$1]:-}" ]; then
    # Listed with their own names already, as right after an install
    echo "${listed_as[$1]}"
  else
    name=$(basename "$1")
    echo "${name%.*}"
  fi
}

# The list's chosen row is written to a file: its last column, the program's full path
cmd_select() { # file, columns...
  printf '%s' "${*: -1}" >"$1"
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

# Run an installer in the prefix of a game that exists, then offer the new shortcuts
install_in_prefix() { # name, installer
  local name=$1 installer=$2 dir="$GAMES/$1" before after new='' line
  before=$(shortcut_games "$dir/prefix" | cut -d'|' -f2-)
  (
    load_files "$SYSTEM_CONF" "$USER_CONF" "$dir/config"
    WINEPREFIX="$dir/prefix"
    cd "$(dirname "$installer")" || exit 1
    launch "$installer"
  ) || true
  after=$(shortcut_games "$dir/prefix" | cut -d'|' -f2-)
  while IFS= read -r line; do
    if [ -n "$line" ] && ! grep -qxF -- "$line" <<<"$before"; then new+="$line"$'\n'; fi
  done <<<"$after"
  if [ -z "$GUI" ]; then
    info "Installed in the prefix of $name. Run: ezlaunch shortcuts \"$name\""
    return 0
  fi
  cmd_shortcuts "$name" "$new"
}

# Ask which of the games' prefixes to use
ask_prefix() { # question
  local name
  [ -n "$(game_names)" ] || die "no games yet, double-click the exe to make the first prefix"
  if [ -n "$GUI" ]; then
    name=$(game_names | yad --list --title ezlaunch --text "$1" --no-markup --center \
      --width 420 --height 360 --column Prefix --no-headers \
      --button Cancel:1 --button OK:0) || exit 1
    name=${name%|}
  else
    name=$(pick_game)
  fi
  check_name "$name"
  [ -f "$GAMES/$name/config" ] || die "unknown game: $name"
  echo "$name"
}

# Open With: run an installer in the prefix of a game that exists
cmd_install_in() { # [exe]
  local installer=${1:-} name
  if [ -z "$installer" ]; then
    installer=$(ask_file "Choose the installer" "$HOME/" "$EXE_FILTER")
  fi
  [ -f "$installer" ] || die "not a file: $installer"
  installer=$(readlink -f "$installer")
  name=$(ask_prefix "Install $(basename "$installer") in which prefix?") || exit 1
  install_in_prefix "$name" "$installer"
}

# Settings: put another program in this prefix, by running its installer or adding it as it is
cmd_add_in() { # name, [exe]
  local name=${1:-} file=${2:-} rc=0
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  [ -f "$GAMES/$name/config" ] || die "unknown game: $name"
  if [ -z "$file" ]; then
    file=$(ask_file "Choose an installer, or a program that is already on the disk" "$HOME/" "$EXE_FILTER")
  fi
  [ -f "$file" ] || die "not a file: $file"
  file=$(readlink -f "$file")
  if [ -n "$GUI" ]; then
    yad --title ezlaunch --text "Is $(basename "$file") an installer or a program to add?" --no-markup \
      --center --width 420 --buttons-layout edge --button Cancel:1 \
      --button "Add!!The program is already installed. Run it from where it is:2" \
      --button "Install!!Run this installer in the prefix, then choose its shortcuts:0" || rc=$?
  else
    read -r -p "[i]nstaller or [a]lready installed? " rc
    case $rc in i*) rc=0 ;; a*) rc=2 ;; *) rc=1 ;; esac
  fi
  case $rc in
    0) install_in_prefix "$name" "$file" ;;
    2) add_to_prefix "$name" "$file" ;;
    *) exit 0 ;;
  esac
}

# Open With: a program that is already on the disk becomes another start menu entry of a game
cmd_add_to() { # [exe]
  local exe=${1:-} name
  if [ -z "$exe" ]; then
    exe=$(ask_file "Choose the program" "$HOME/" "$EXE_FILTER")
  fi
  [ -f "$exe" ] || die "not a file: $exe"
  exe=$(readlink -f "$exe")
  name=$(ask_prefix "Add $(basename "$exe") to which prefix?") || exit 1
  add_to_prefix "$name" "$exe"
}

# A program that is on the disk becomes another start menu entry of a prefix
add_to_prefix() { # name, exe
  local name=$1 exe=$2 dir="$GAMES/$1" label lines
  if [ "$exe" = "$(getv EZLAUNCH_EXE "$dir/config")" ] || grep -qxF -- "|$exe" <(sed 's/^[^|]*//' "$dir/links" 2>/dev/null); then
    die "already in the start menu: $(basename "$exe")"
  fi
  label=$(basename "$exe")
  label=$(ask_text "Name in the start menu" "${label%.*}")
  label=$(printf '%s' "$label" | tr -d '|\n')
  [ -n "$label" ] || die "empty name"
  lines=$(cat "$dir/links" 2>/dev/null || true)
  lines+=${lines:+$'\n'}"$label|$exe"
  set_links "$dir" "$lines"
  write_desktop "$name" "$(icon_for "$dir")"
  info "Added $label to the start menu."
}

cmd_add() { # [--install | --installed] [exe]
  local mode='' installer name='' dir exe icon version='' category='' reply picked='' picks links='' title=''
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
  # A prefix that exists gets the program as another of its shortcuts
  if grep -qs '^EZLAUNCH_EXE=' "$dir/config"; then
    if [ "$mode" = install ]; then
      install_in_prefix "$name" "$installer"
    else
      add_to_prefix "$name" "$installer"
    fi
    return 0
  fi

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
      title=$(sed -n 1p <<<"$picks" | cut -d'|' -f1)
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
  apply_title "$name" "$title"
  touch "$dir/.titled"
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
  # The shortcut name belonged to the old exe
  { grep -Ev '^(EZLAUNCH_EXE|EZLAUNCH_TITLE)=' "$dir/config" || true; } >"$dir/config.new"
  printf 'EZLAUNCH_EXE=%s\n' "$2" >>"$dir/config.new"
  mv "$dir/config.new" "$dir/config"
}

# The name of the main start menu entry, taken from its Windows shortcut. Empty: the game's name.
apply_title() { # name, title
  local cfg="$GAMES/$1/config" title
  title=$(printf '%s' "$2" | tr -d '\n')
  { grep -v '^EZLAUNCH_TITLE=' "$cfg" || true; } >"$cfg.new"
  if [ -n "$title" ] && [ "$title" != "$1" ]; then echo "EZLAUNCH_TITLE=$title" >>"$cfg.new"; fi
  mv "$cfg.new" "$cfg"
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
    # The entry's name comes from the shortcut, keep it
    if grep -q '^EZLAUNCH_TITLE=' "$cfg"; then echo "EZLAUNCH_TITLE=$(getv EZLAUNCH_TITLE "$cfg")"; fi
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

# Bring a game added by an older ezlaunch up to date, once: its entry gets the name of the Windows
# shortcut its exe came from, and the right-click actions added since. .titled marks it done.
upgrade_game() { # name
  local dir="$GAMES/$1" main line title=
  if [ -f "$dir/.titled" ] || [ ! -f "$dir/config" ]; then return 0; fi
  main=$(getv EZLAUNCH_EXE "$dir/config")
  if [ -n "$main" ] && [ -z "$(getv EZLAUNCH_TITLE "$dir/config")" ]; then
    while IFS= read -r line; do
      if [ "${line#*|}" = "$main" ]; then
        title=${line%%|*}
        break
      fi
    done < <(shortcut_games "$dir/prefix")
    apply_title "$1" "$title"
  fi
  touch "$dir/.titled"
  write_desktop "$1" "$(icon_for "$dir")"
}

cmd_run() { # name, args...
  local name=${1:-} dir
  shift || true
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  dir="$GAMES/$name"
  [ -f "$dir/config" ] || die "unknown game: $name"
  upgrade_game "$name"
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
  upgrade_game "$name"
  command -v yad >/dev/null || die "settings needs yad. Edit $cfg instead."
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || die "settings needs a graphical session. Edit $cfg instead."

  local all=("$SYSTEM_CONF" "$USER_CONF" "$cfg")
  local fields=() entry key on off label tip state managed='EZLAUNCH_EXE|EZLAUNCH_TITLE|PROTONPATH|EZLAUNCH_CATEGORY'
  for entry in "${KNOWN[@]}"; do
    IFS='|' read -r key on off label tip <<<"$entry"
    state=FALSE
    if [ "$(getv "$key" "${all[@]}")" = "$on" ]; then state=TRUE; fi
    fields+=(--field "$label!$tip:CHK" "$state")
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

  local custom_in
  # yad takes line breaks in a text field as \n
  custom_in=$({ grep -Ev "^($managed)=" "$cfg" || true; })
  custom_in=${custom_in//$'\n'/\\n}

  # Choose shortcuts and Add open their own window and leave this one open
  local out rc=0 self q
  self=$(readlink -f "$0")
  q="'$name'"
  out=$(yad --form --title ezlaunch --text "Settings for $name" --width 600 \
    "${fields[@]}" \
    --field "Proton version!The Proton the game runs with, from compatibilitytools.d:CB" "$versions_field" \
    --field "Category!Where the game goes in the start menu:CB" "$(category_choices "$(game_category "$cfg")")" \
    --field "Custom variables, KEY=value one per line!Any Proton or Wine environment variable, such as DXVK_HUD=fps:TXT" "$custom_in" \
    --button Cancel:1 \
    --button "Choose shortcuts!!Which shortcuts of the prefix are in the start menu, and their names:'$self' shortcuts $q" \
    --button "Add!!Install another program in this prefix, or add one that is on the disk:'$self' add-in $q" \
    --button Save:0 --separator '|') || rc=$?
  [ "$rc" = 0 ] || return 0

  # One value per field, in order. The custom variables come last and may hold a |.
  local parts=() n=${#KNOWN[@]} i selected='' custom category
  IFS='|' read -ra parts <<<"$out"
  for ((i = 0; i < n; i++)); do
    IFS='|' read -r key _ <<<"${KNOWN[i]}"
    if [ "${parts[i]:-}" = TRUE ]; then selected+="$key"$'\n'; fi
  done
  version=${parts[n]:-}
  category=$(category_value "${parts[n + 1]:-}")
  custom=$(
    IFS='|'
    echo "${parts[*]:n+2}"
  )
  custom=${custom//\\n/$'\n'}
  # yad ends the text with a line break, which would add a blank line at every save
  custom=$(printf '%s' "$custom")

  apply_options "$name" "$selected" "$custom"
  if [ -n "$version" ]; then apply_proton "$name" "$version"; fi
  apply_category "$name" "$category"
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

# Give a game's prefix folder a new name. The start menu entries keep the name they show.
cmd_rename() { # [name], [new name]
  local name=${1:-} new=${2:-} old_dir new_dir file line out shown
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  old_dir="$GAMES/$name"
  [ -f "$old_dir/config" ] || die "unknown game: $name"
  upgrade_game "$name"
  [ -z "$(game_pids "$name")" ] || die "$name is running. Stop it first."
  if [ -z "$new" ]; then new=$(ask_text "New name for the prefix $name" "$name") || exit 0; fi
  new=$(printf '%s' "$new" | tr -cd 'A-Za-z0-9 ._-' | sed 's/^[ .]*//; s/ *$//')
  [ -n "$new" ] || die "empty game name"
  [ "$new" != "$name" ] || exit 0
  new_dir="$GAMES/$new"
  [ ! -e "$new_dir" ] || die "already exists: $new"
  shown=$(getv EZLAUNCH_TITLE "$old_dir/config")
  shown=${shown:-$name}

  mv "$old_dir" "$new_dir"
  # The game's exe, its other shortcuts and custom variables can point into the old folder
  for file in "$new_dir/config" "$new_dir/links"; do
    [ -f "$file" ] || continue
    out=
    while IFS= read -r line || [ -n "$line" ]; do
      out+="${line//"$old_dir/"/"$new_dir/"}"$'\n'
    done <"$file"
    printf '%s' "$out" >"$file"
  done

  rm -f "$(desktop_file "$name")" "$APPS/ezlaunch-${name// /_}.link-"*.desktop \
    "$MENUS/ezlaunch-${name// /_}.menu" "$DIRECTORIES/ezlaunch-${name// /_}.directory"
  # The start menu entry keeps showing what it showed. Settings changes that name.
  apply_title "$new" "$shown"
  touch "$new_dir/.titled"
  write_desktop "$new" "$(icon_for "$new_dir")"
  echo "ezlaunch: renamed $name to $new"
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
cmd_shortcuts() { # [name], [exes to tick besides the current ones]
  local name=${1:-} dir found current picks main keep links line listed='' title
  if [ -z "$name" ]; then name=$(pick_game); fi
  check_name "$name"
  dir="$GAMES/$name"
  [ -f "$dir/config" ] || die "unknown game: $name"
  [ -n "$GUI" ] || die "shortcuts needs a graphical session"
  upgrade_game "$name"
  main=$(getv EZLAUNCH_EXE "$dir/config")

  # Every shortcut in the prefix, and the entries the game has even if no shortcut is found.
  # An entry that is in the start menu is listed with the name it has there.
  local -A named=() seen=() own_names=()
  local exe
  title=$(getv EZLAUNCH_TITLE "$dir/config")
  named[$main]=${title:-$name}
  if [ -s "$dir/links" ]; then
    while IFS= read -r line; do
      exe=${line#*|}
      if [ -z "${named[$exe]+x}" ]; then named[$exe]=${line%%|*}; fi
    done <"$dir/links"
  fi
  found=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    exe=${line#*|}
    own_names[$exe]=${line%%|*}
    if [ -n "${named[$exe]+x}" ]; then line="${named[$exe]}|$exe"; fi
    found+="$line"$'\n'
    seen[$exe]=1
    if [ "$exe" = "$main" ]; then listed=1; fi
  done < <(shortcut_games "$dir/prefix")
  if [ -z "$listed" ]; then found="${named[$main]}|$main"$'\n'"$found"; fi
  if [ -s "$dir/links" ]; then
    while IFS= read -r line; do
      exe=${line#*|}
      if [ -z "${seen[$exe]+x}" ]; then
        found+="${named[$exe]}|$exe"$'\n'
        seen[$exe]=1
      fi
    done <"$dir/links"
  fi
  found=${found%$'\n'}
  current="$main"$'\n'$(cut -d'|' -f2- "$dir/links" 2>/dev/null || true)$'\n'${2:-}

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
  # The entry is named after the shortcut that was ticked for it
  title=
  while IFS= read -r line; do
    if [ "${line#*|}" = "$keep" ]; then
      title=${line%%|*}
      break
    fi
  done <<<"$picks"
  apply_title "$name" "$title"
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

# One window with the prefixes. Add makes a new one, Rename, Remove and Stop act on the chosen one.
# Settings, or a double-click, opens the
# settings of the chosen one, where everything else is. The list is read again afterwards.
cmd_gui() {
  [ -n "$GUI" ] || die "the window needs a graphical session"
  local name rc rows status out
  while IFS= read -r name; do upgrade_game "$name"; done < <(game_names)
  while true; do
    rows=()
    while IFS= read -r name; do
      status=
      if [ -n "$(game_pids "$name")" ]; then status=running; fi
      rows+=("$name" "$status")
    done < <(game_names)
    rc=0
    out=$(yad --list --title ezlaunch --no-markup \
      --text "Choose a prefix and press Settings, or double-click it." \
      --center --width 640 --height 460 --column Prefix --column Status --separator '|' \
      --button Close:1 --button "Refresh!!Update the list and what is running:60" \
      --button "Rename!!Give the chosen prefix folder a new name. The start menu names stay:20" \
      --button "Remove!!Delete the chosen prefix, with saved games inside it, and its start menu entries:30" \
      --button "Stop!!Close everything that runs in the chosen prefix:40" \
      --button "Add!!New prefix. Install a program or add one that is on the disk:10" \
      --button "Settings!!Options, shortcuts and adding programs for the chosen prefix:0" \
      "${rows[@]}") || rc=$?
    case $rc in
      0)
        name=${out%%|*}
        if [ -n "$name" ]; then "$0" settings "$name" || true; else info "Choose a prefix first."; fi
        ;;
      10) "$0" add || true ;;
      20)
        name=${out%%|*}
        if [ -n "$name" ]; then "$0" rename "$name" || true; else info "Choose a prefix first."; fi
        ;;
      30)
        name=${out%%|*}
        if [ -n "$name" ]; then "$0" remove "$name" || true; else info "Choose a prefix first."; fi
        ;;
      40)
        name=${out%%|*}
        if [ -n "$name" ]; then "$0" stop "$name" || true; else info "Choose a prefix first."; fi
        ;;
      60) ;;
      *) return 0 ;;
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
  install-in [file.exe] run an installer in the prefix of a game that exists, then choose
                        which of the new shortcuts go in the start menu
  add-to [file.exe]     add a program that is on the disk as another start menu entry of
                        a game that exists, in the same prefix
  add-in <game> [file]  put another program in this prefix: run its installer or add it as it is
  run [game] [args]     start a game
  settings [game]       all settings of a game in one window
  shortcuts [game]      choose which of the shortcuts in the game's prefix are in the start menu
  remove [game]         delete a game, its prefix and its start menu entry
  rename [game] [new]   give a game's prefix folder a new name, the start menu name stays
  list                  list the games, marking the ones that are running
  running               list the games that are running
  stop [game]           close a running game

Without a game name, run, settings, rename, remove and stop show a menu to choose from.

Defaults for new games: $SYSTEM_CONF and $USER_CONF (KEY=value lines).
EOF
}

case "${1:-}" in
  gui) cmd_gui ;;
  add) shift && cmd_add "$@" ;;
  install-in) shift && cmd_install_in "$@" ;;
  add-to) shift && cmd_add_to "$@" ;;
  add-in) shift && cmd_add_in "$@" ;;
  _select) shift && cmd_select "$@" ;;
  run) shift && cmd_run "$@" ;;
  settings) shift && cmd_settings "$@" ;;
  shortcuts) shift && cmd_shortcuts "$@" ;;
  remove) shift && cmd_remove "$@" ;;
  rename) shift && cmd_rename "$@" ;;
  list) cmd_list ;;
  running) cmd_running ;;
  stop) shift && cmd_stop "$@" ;;
  *)
    usage
    exit 1
    ;;
esac
