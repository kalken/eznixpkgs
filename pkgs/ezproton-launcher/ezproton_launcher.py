#!/usr/bin/env python3
"""ezproton-launcher: install and launch Windows programs and games with Proton (umu-launcher).

Run with no arguments for usage. The windows are Qt (PySide6), loaded only when one is shown, so
starting a prefix never does: the start menu entries run each prefix's launch script, which hands over
to umu. Without a display the questions are asked in the terminal.
"""

import os
import html
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from contextlib import contextmanager, nullcontext
import time
import zipfile
from datetime import date
from pathlib import Path

APP = "ezproton-launcher"
HOME = Path.home()
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share")
CONFIG_HOME = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
PREFIXES = DATA / APP / "prefixes"
APPS = DATA / "applications"
MENUS = CONFIG_HOME / "menus/applications-merged"
DIRECTORIES = DATA / "desktop-directories"
USER_CONF = CONFIG_HOME / APP / "config"
SYSTEM_CONF = Path("/etc") / APP / "config"
# Where ezproton installs Proton
TOOLS = HOME / ".local/share/Steam/compatibilitytools.d"
GENERIC_ICON = "applications-games"

# The options in the settings window: key, value when on, value when off, label, tooltip
KNOWN = [
    ("PROTON_ENABLE_HDR", "1", "0", "HDR", "High dynamic range. Needs Native Wayland and an HDR screen"),
    ("DXVK_ENABLE_NVAPI", "1", "0", "HDR in Unreal Engine 4 games", "DXVK turns HDR off in Unreal Engine 4 games (an exe ending in -Win64-Shipping) in case they run DirectX 11. Tick it for one that runs DirectX 12 and offers no HDR. Needs HDR"),
    ("PROTON_ENABLE_WAYLAND", "1", "0", "Native Wayland", "Draw the program with Wayland directly instead of through XWayland"),
    ("PROTON_USE_NTSYNC", "1", "0", "NTSync", "Faster syncing between threads, needs the ntsync kernel module"),
    ("PROTON_ENABLE_NVAPI", "1", "0", "NVIDIA NVAPI (DLSS)", "Lets the program use NVIDIA features such as DLSS. Only for NVIDIA cards"),
    ("PROTON_USE_WINED3D", "1", "0", "WineD3D instead of DXVK", "Older, slower way to run DirectX. Try it if a program shows graphics errors"),
    ("PROTON_NO_ESYNC", "1", "0", "Disable esync", "Try it if a program hangs or crashes"),
    ("PROTON_NO_FSYNC", "1", "0", "Disable fsync", "Try it if a program hangs or crashes"),
    ("MANGOHUD", "1", "0", "MangoHud overlay", "Shows frame rate, CPU and GPU use over the program"),
    ("LAUNCHER_WRAPPER", "gamemoderun", "", "GameMode", "Tunes the system for performance while this program runs, needs GameMode installed"),
    ("PROTON_FSR4_UPGRADE", "1", "0", "FSR 4 upgrade", "Swaps a game's FSR 3.1 for FSR 4. Only for AMD RDNA4 cards, needs GE or CachyOS Proton"),
    ("PROTON_DLSS_UPGRADE", "1", "0", "DLSS upgrade", "Swaps a game's DLSS for the newest one. Only for NVIDIA cards, needs GE or CachyOS Proton"),
    ("PROTON_HIDE_NVIDIA_GPU", "1", "0", "Hide NVIDIA GPU", "Shows the program an AMD card instead. Try it if a program crashes or acts up on an NVIDIA card"),
    ("DXVK_HUD", "fps", "", "FPS counter", "Shows the frame rate in a corner, lighter than MangoHud"),
]

# Label and menu category, where an entry goes in the start menu
CATEGORIES = [
    ("Game", "Game"),
    ("Utility", "Utility"),
    ("Office", "Office"),
    ("Internet", "Network"),
    ("Development", "Development"),
    ("Graphics", "Graphics"),
    ("Multimedia", "AudioVideo"),
    ("System", "System"),
]

# Keys with a field of their own in the settings window, not shown as custom variables
MANAGED = {"LAUNCHER_EXE", "LAUNCHER_TITLE", "PROTONPATH", "LAUNCHER_CATEGORY"} | {k[0] for k in KNOWN}

EXE_FILTER = "Windows programs (*.exe *.EXE);;All files (*)"
ZIP_FILTER = "Save backups (*.zip);;All files (*)"


class Abort(Exception):
    """Stops a command with a message for the user."""


class Cancelled(Exception):
    """The user closed a question. Stops the command without a message."""


# ---------------------------------------------------------------------------------------------
# Config files: KEY=value lines, later files winning


def read_conf(path):
    pairs = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f.read().splitlines():
                if re.match(r"[A-Za-z_][A-Za-z0-9_]*=", line):
                    key, _, value = line.partition("=")
                    pairs.append((key, value))
    except OSError:
        pass
    return pairs


def getv(key, *files):
    value = ""
    for path in files:
        for k, v in read_conf(path):
            if k == key:
                value = v
    return value


def load_conf(*files):
    env = {}
    for path in files:
        env.update(read_conf(path))
    return env


def default(key):
    return getv(key, SYSTEM_CONF, USER_CONF)


def default_category():
    return default("LAUNCHER_CATEGORY") or "Game"


def category_label(value):
    return next((label for label, v in CATEGORIES if v == value), CATEGORIES[0][0])


def category_value(label):
    return next((v for lab, v in CATEGORIES if lab == label), "Game")


def proton_versions():
    try:
        return sorted(p.name for p in TOOLS.iterdir() if p.is_dir())
    except OSError:
        return []


# ---------------------------------------------------------------------------------------------
# Prefixes: one folder each, with config, links, the Wine prefix in prefix/, icons and the launch script


class Prefix:
    def __init__(self, name):
        check_name(name)
        self.name = name
        self.dir = PREFIXES / name
        self.config = self.dir / "config"
        # The Wine prefix itself, with drive_c
        self.wine = self.dir / "prefix"
        self.links_file = self.dir / "links"

    def exists(self):
        return self.config.is_file()

    def require(self):
        if not self.exists():
            raise Abort(f"unknown prefix: {self.name}")
        return self

    def get(self, key):
        return getv(key, self.config)

    # A prefix has all its settings in its own config: the defaults are only what a new one starts with
    def setting(self, key):
        return self.get(key)

    @property
    def exe(self):
        return self.get("LAUNCHER_EXE")

    @property
    def title(self):
        return self.get("LAUNCHER_TITLE")

    @property
    def category(self):
        return self.get("LAUNCHER_CATEGORY") or "Game"

    def set_keys(self, changes):
        """Set (value) or remove (None) keys of the config, keeping the other lines as they are."""
        try:
            lines = self.config.read_text(encoding="utf-8").splitlines()
        except OSError:
            lines = []
        lines = [line for line in lines if line.partition("=")[0] not in changes]
        lines += [f"{k}={v}" for k, v in changes.items() if v is not None]
        write_lines(self.config, lines)

    def links(self):
        """The other start menu entries of the prefix, as (name, exe, category). Lines are
        name|category|exe, or name|exe from before entries had a category of their own (they get
        the main entry's)."""
        try:
            text = self.links_file.read_text(encoding="utf-8")
        except OSError:
            return []
        values = {v for _, v in CATEGORIES}
        links = []
        for line in text.splitlines():
            parts = line.split("|", 2)
            if len(parts) == 3 and parts[1] in values:
                links.append((parts[0], parts[2], parts[1]))
            elif len(parts) >= 2:
                links.append((parts[0], line.split("|", 1)[1], self.category))
        return links

    def icon(self):
        icons = sorted(self.dir.glob("icon.*"))
        return str(icons[0]) if icons else GENERIC_ICON

    def pids(self):
        return wine_pids(self.wine)

    def running(self):
        return bool(self.pids())


def write_lines(path, lines):
    tmp = Path(str(path) + ".new")
    tmp.write_text("".join(line + "\n" for line in lines), encoding="utf-8")
    tmp.replace(path)


def check_name(name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._ -]*", name or ""):
        raise Abort(f"invalid prefix name: {name}")


def clean_name(name):
    name = re.sub(r"[^A-Za-z0-9 ._-]", "", name or "")
    return re.sub(r"^[ .]*", "", name).rstrip(" ")


def prefix_names():
    try:
        names = [p.name for p in PREFIXES.iterdir() if (p / "config").is_file()]
    except OSError:
        return []
    return sorted(names, key=str.lower)


def prefix_pids():
    """Every running process with a WINEPREFIX, as prefix: process IDs. One look at all processes,
    which is how what a prefix started is found."""
    found = {}
    for entry in os.listdir("/proc") if os.path.isdir("/proc") else []:
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/environ", "rb") as f:
                env = f.read()
        except OSError:
            continue
        for var in env.split(b"\0"):
            if var.startswith(b"WINEPREFIX="):
                found.setdefault(os.fsdecode(var[11:]), []).append(int(entry))
                break
    return found


def wine_pids(wine):
    """Processes whose environment holds the Wine prefix folder, which is every process a program in
    it started."""
    return prefix_pids().get(str(wine), [])


def running_names():
    """The prefixes that have something running, with one look at all processes."""
    running = prefix_pids()
    return {n for n in prefix_names() if str(Prefix(n).wine) in running}


# ---------------------------------------------------------------------------------------------
# Windows shortcuts and icons

LNK_TARGET = re.compile(r'[A-Za-z]:\\(?:[^\\/:*?"<>|\x00-\x1f\x7f]+\\)*[^\\/:*?"<>|\x00-\x1f\x7f]+\.[Ee][Xx][Ee]')


def lnk_targets(data):
    """Windows paths of .exe files in a .lnk file, stored as plain or as UTF-16 text."""
    texts = [data.decode("latin-1")]
    texts += [data[i:].decode("utf-16-le", errors="ignore") for i in (0, 1)]
    for text in texts:
        for match in LNK_TARGET.finditer(text):
            yield match.group(0)


def windows_to_unix(wine, target):
    """The file a Windows path points to in a Wine prefix, found without regard to upper and lower case."""
    path = wine / "dosdevices" / f"{target[0].lower()}:"
    for part in target[3:].split("\\"):
        nxt = path / part
        if not nxt.exists():
            try:
                match = next((c for c in os.listdir(path) if c.casefold() == part.casefold()), None)
            except OSError:
                return None
            if match is None:
                return None
            nxt = path / match
        path = nxt
    return os.path.realpath(path) if path.is_file() else None


def shortcut_programs(wine):
    """The programs an installer left shortcuts for, as (name, exe). The shortcuts are the .lnk
    files in the prefix's Start Menu and on its desktop. Uninstallers are left out."""
    found, seen = [], set()
    for top in ("ProgramData", "users"):
        for root, dirs, files in os.walk(wine / "drive_c" / top):
            dirs.sort()
            for file in sorted(files):
                path = os.path.join(root, file)
                low = path.lower()
                if not low.endswith(".lnk") or not ("/start menu/" in low or "/desktop/" in low):
                    continue
                name = file[:-4]
                if "uninstall" in name.lower():
                    continue
                try:
                    data = Path(path).read_bytes()
                except OSError:
                    continue
                exe = next((e for e in map(lambda t: windows_to_unix(wine, t), lnk_targets(data)) if e), None)
                if not exe or re.fullmatch(r"unins.*\.exe", os.path.basename(exe).lower()) or exe in seen:
                    continue
                seen.add(exe)
                found.append((name, exe))
    # The program itself usually has the shortest name (Game, Game Editor, Game Launcher), and the
    # first one becomes the prefix's main entry
    return sorted(found, key=lambda f: (len(f[0]), f[0].lower()))


def extract_icon(exe, png):
    """The largest icon of an exe as a png, with icoutils. Nothing is written without one."""
    if not (shutil.which("wrestool") and shutil.which("icotool")):
        return
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["wrestool", "-x", "-t14", "-o", tmp, exe], stderr=subprocess.DEVNULL, check=False)
        icos = sorted(Path(tmp).glob("*.ico"))
        if not icos:
            return
        out = Path(tmp) / "png"
        out.mkdir()
        subprocess.run(["icotool", "-x", "-o", str(out), str(icos[0])], stderr=subprocess.DEVNULL, check=False)
        pngs = sorted(out.glob("*.png"), key=lambda p: p.stat().st_size, reverse=True)
        if pngs:
            shutil.copy(pngs[0], png)


def short_path(exe):
    """A program's path as it is easiest to read: C:\\Program\\program.exe inside a prefix, ~/... in the home."""
    parts = Path(exe).parts
    base = PREFIXES.parts
    if parts[: len(base)] == base and parts[len(base) + 1 : len(base) + 3] == ("prefix", "drive_c"):
        return "C:\\" + "\\".join(parts[len(base) + 3 :])
    if exe.startswith(str(HOME) + "/"):
        return "~/" + exe[len(str(HOME)) + 1 :]
    return exe


def stem(path):
    return os.path.splitext(os.path.basename(path))[0]


def program_name(exe):
    """A start menu name made from a file name: underscores are spaces and each word starts with a
    capital, so hollow_knight.exe is Hollow Knight. The rest of each word stays as it is."""
    words = [w for w in stem(exe).split("_") for w in w.split() if w]
    return " ".join(w[:1].upper() + w[1:] for w in words) or stem(exe)


# Left in a file by the programs that make most Windows installers
INSTALLER_MARKERS = [b"Inno Setup", b"Nullsoft", b"NullsoftInst", b"InstallShield", b".wixburn", b"WiX Toolset",
                     b"7zS.sfx", b"Setup Factory", b"InstallAware", b"Wise Installation"]


def looks_like_installer(exe):
    """A guess, for which button the question offers first: a setup or install name, or the marks
    of a known installer maker in the first few MB."""
    if re.search(r"setup|install", os.path.basename(exe), re.I):
        return True
    try:
        with open(exe, "rb") as f:
            data = f.read(8 * 1024 * 1024)
    except OSError:
        return False
    return any(m in data for m in INSTALLER_MARKERS)


def kind_question(exe):
    """The install-or-add question for exe, with the guess said first and offered as the default."""
    name = os.path.basename(exe)
    if looks_like_installer(exe):
        return "install", (f"{name} looks like an installer. Install runs it, then you choose which of its "
                           "shortcuts go in the start menu. Press Add instead if it is the program itself.")
    return "installed", (f"{name} looks like a program. Add puts it in the start menu, and will run it from where it is. "
                         "Press Install instead if it is an installer.")


# ---------------------------------------------------------------------------------------------
# Start menu entries


def desktop_id(name):
    return f"{APP}-prefix-{name.replace(' ', '_')}"


def exec_arg(arg):
    """An argument for an Exec line, quoted as the desktop entry spec says."""
    if re.fullmatch(r"[A-Za-z0-9_./=+-]+", arg):
        quoted = arg
    else:
        quoted = '"' + re.sub(r'(["`$\\])', r"\\\1", arg) + '"'
    return quoted.replace("\\", "\\\\").replace("%", "%%")


def exec_line(*args):
    return " ".join(exec_arg(a) for a in (APP, *args))


def exec_script(prefix, *args):
    """An Exec line that runs the prefix's launch script directly, without this program."""
    return " ".join(exec_arg(a) for a in (str(launch_script(prefix)), *args))


def one_line(text):
    return " ".join(str(text).split())


def remove_desktop(name):
    pid = desktop_id(name)
    for path in [APPS / f"{pid}.desktop", MENUS / f"{pid}.menu", DIRECTORIES / f"{pid}.directory"]:
        path.unlink(missing_ok=True)
    for path in APPS.glob(f"{pid}.link-*.desktop"):
        path.unlink(missing_ok=True)


def desktop_files(prefix):
    """The start menu files of a prefix, as path: text: the main entry and one per other shortcut,
    each in its own category."""
    pid = desktop_id(prefix.name)
    icon = prefix.icon()
    links = prefix.links()

    def entry(name, run, icon, log, rename, category):
        return f"""[Desktop Entry]
Type=Application
Name={one_line(name)}
Exec={run}
Icon={icon}
Categories={category};
Terminal=false
Actions=log;rename;settings;

[Desktop Action log]
Name=Run with log
Exec={log}

[Desktop Action rename]
Name=Rename
Exec={rename}

[Desktop Action settings]
Name=Settings
Exec={exec_line("settings", prefix.name)}
"""

    files = {
        APPS / f"{pid}.desktop": entry(prefix.title or prefix.name, exec_script(prefix), icon,
                                       exec_line("run", prefix.name, "--log"), exec_line("rename-shortcut", prefix.name),
                                       prefix.category),
    }
    # The other shortcuts of the prefix, started with their own exe in the same prefix
    for n, (lname, lexe, lcategory) in enumerate(links, 1):
        licon = prefix.dir / f"link-{n}.png"
        files[APPS / f"{pid}.link-{n}.desktop"] = entry(
            lname, exec_script(prefix, lexe), licon if licon.is_file() else GENERIC_ICON,
            exec_line("run", prefix.name, "--log", "--exe", lexe), exec_line("rename-shortcut", prefix.name, lexe),
            lcategory)
    return files


def write_desktop(prefix):
    """Write the prefix's start menu files. A prefix whose shortcuts were all unticked has none."""
    write_launch_script(prefix)
    remove_desktop(prefix.name)
    if not prefix.exe:
        refresh_menu()
        return
    for path, text in desktop_files(prefix).items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    refresh_menu()


def upgrade_all():
    """Prefixes made by an older version, or moved here by hand, get the current launch script, and
    start menu files that are missing or differ from what this version writes are written again."""
    # Start menu files were called ezproton-launcher-game-* once
    for old in [*APPS.glob(f"{APP}-game-*.desktop"), *MENUS.glob(f"{APP}-game-*.menu"),
                *DIRECTORIES.glob(f"{APP}-game-*.directory")]:
        old.unlink(missing_ok=True)
    for name in prefix_names():
        prefix = Prefix(name)
        write_launch_script(prefix)
        if not prefix.exe:
            continue
        want = desktop_files(prefix)
        pid = desktop_id(name)
        have = {p for p in APPS.glob(f"{pid}.link-*.desktop")}
        # A menu folder of the prefix is from before entries had a category each
        stale = (have - set(want)) | {p for p in (MENUS / f"{pid}.menu", DIRECTORIES / f"{pid}.directory") if p.exists()}
        if stale or any(not p.is_file() or p.read_text(errors="replace") != t for p, t in want.items()):
            write_desktop(prefix)


def refresh_menu():
    if shutil.which("update-desktop-database"):
        subprocess.run(["update-desktop-database", str(APPS)], stderr=subprocess.DEVNULL, check=False)
    # KDE keeps its own copy of the menu
    if shutil.which("kbuildsycoca6"):
        subprocess.run(["kbuildsycoca6"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def set_links(prefix, links):
    """Save the shortcuts of a prefix besides its main one, as (name, exe, category), with an icon
    for each."""
    prefix.links_file.unlink(missing_ok=True)
    for png in prefix.dir.glob("link-*.png"):
        png.unlink()
    if not links:
        return
    write_lines(prefix.links_file, [f"{n}|{c}|{e}" for n, e, c in links])
    for i, (_, exe, _) in enumerate(links, 1):
        extract_icon(exe, prefix.dir / f"link-{i}.png")


# ---------------------------------------------------------------------------------------------
# Changing a prefix's config. These do not ask anything.


def apply_exe(prefix, exe):
    """Make exe the prefix's main program, with the icon taken from it. The old title belonged to the old exe."""
    for icon in prefix.dir.glob("icon.*"):
        icon.unlink()
    extract_icon(exe, prefix.dir / "icon.png")
    prefix.set_keys({"LAUNCHER_EXE": exe, "LAUNCHER_TITLE": None})


def apply_title(prefix, title):
    """The name of the main start menu entry. Empty or the prefix's name: the prefix's name."""
    title = one_line(title or "")
    prefix.set_keys({"LAUNCHER_TITLE": title if title and title != prefix.name else None})


def apply_proton(prefix, version):
    prefix.set_keys({"PROTONPATH": version})


def apply_category(prefix, category):
    prefix.set_keys({"LAUNCHER_CATEGORY": category})


def apply_options(prefix, selected, custom):
    """The settings window's checkboxes (keys ticked) and custom variables (text)."""
    keep = {k: v for k, v in read_conf(prefix.config) if k in MANAGED - {k[0] for k in KNOWN}}
    lines = [f"{k}={v}" for k, v in keep.items()]
    # A ticked option is saved, an unticked one left out, since nothing else is read
    lines += [f"{key}={on}" for key, on, _, _, _ in KNOWN if key in selected]
    lines += [line for line in custom.splitlines() if line.strip()]
    write_lines(prefix.config, lines)


# ---------------------------------------------------------------------------------------------
# Running programs


# Each prefix has a small shell script, launch, that starts a program in it with Proton. The start
# menu entries run it directly, so starting a program involves neither Python nor this one. It
# reads the prefix's config every time, so changed settings apply at once. It finds its own folder,
# so it keeps working when the prefix is renamed.
LAUNCH_SCRIPT = r"""#!/bin/sh
# Starts a program in this prefix with Proton. Written by ezproton-launcher, which overwrites changes.
# Usage: launch [program.exe [arguments]]. Without a program: the prefix's main one (LAUNCHER_EXE),
# with LAUNCHER_ARGS.
dir=$(cd "$(dirname "$0")" && pwd)

# KEY=value lines
load() {
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      [A-Za-z_]*=*) export "${line%%=*}=${line#*=}" ;;
    esac
  done <"$1"
}
load "$dir/config"

if [ $# -gt 0 ]; then
  exe=$1
  shift
else
  exe=${LAUNCHER_EXE:-}
  eval "set -- ${LAUNCHER_ARGS:-}"
fi
if [ -z "$exe" ]; then
  echo "launch: no program set in $dir/config" >&2
  exit 1
fi
if ! command -v umu-run >/dev/null; then
  echo "launch: umu-run is not installed" >&2
  command -v notify-send >/dev/null && notify-send @APP@ "umu-run is not installed"
  exit 127
fi

export WINEPREFIX="$dir/prefix" GAMEID="${GAMEID:-0}"
# A Proton log (PROTON_LOG=1) goes in the prefix's folder, where @APP@ log finds it
export PROTON_LOG_DIR="${PROTON_LOG_DIR:-$dir}"
# A name from ezproton (GE-Proton-Latest) becomes its full path. Anything else, such as a path or
# a version umu downloads itself, is left to umu.
case ${PROTONPATH:-} in
  '' | */*) ;;
  *) if [ -d "$HOME/.local/share/Steam/compatibilitytools.d/$PROTONPATH" ]; then
    export PROTONPATH="$HOME/.local/share/Steam/compatibilitytools.d/$PROTONPATH"
  fi ;;
esac

set -- umu-run "$exe" "$@"
# LAUNCHER_WRAPPER is a command prefix, such as gamemoderun
if [ -n "${LAUNCHER_WRAPPER:-}" ]; then eval "set -- $LAUNCHER_WRAPPER \"\$@\""; fi
# A controller does not count as activity for the idle timer, so keep the screen awake while the
# program runs. kde-inhibit on KDE, which ignores systemd's idle lock.
if [ "${LAUNCHER_INHIBIT:-1}" != 0 ]; then
  case ${XDG_CURRENT_DESKTOP:-} in
    *KDE*) command -v kde-inhibit >/dev/null && set -- kde-inhibit --power --screenSaver "$@" ;;
    *) command -v systemd-inhibit >/dev/null &&
      set -- systemd-inhibit --what=idle --who=@APP@ "--why=Running a Windows program" "$@" ;;
  esac
fi
cd "$(dirname "$exe")" || exit 1
exec "$@"
"""


def launch_script(prefix):
    return prefix.dir / "launch"


def seed_defaults(prefix):
    """Add the defaults the prefix's config does not set yet to it."""
    try:
        lines = prefix.config.read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    have = {k for k, _ in read_conf(prefix.config)}
    add = [f"{k}={v}" for k, v in load_conf(SYSTEM_CONF, USER_CONF).items()
           if k not in have and k not in ("LAUNCHER_EXE", "LAUNCHER_TITLE")]
    if add:
        write_lines(prefix.config, lines + add)


def write_launch_script(prefix):
    """Write the prefix's launch script, or bring it up to date. A new prefix gets the defaults in its
    config here, and so does one whose script still read them itself (from before every setting was in
    the prefix's config), so it runs as it did."""
    text = LAUNCH_SCRIPT.replace("@APP@", APP)
    path = launch_script(prefix)
    try:
        old = path.read_text(encoding="utf-8")
    except OSError:
        old = None
    if old == text:
        return path
    prefix.dir.mkdir(parents=True, exist_ok=True)
    if old is None or f"load {SYSTEM_CONF}" in old:
        seed_defaults(prefix)
    tmp = path.with_name("launch.new")
    tmp.write_text(text, encoding="utf-8")
    tmp.chmod(0o755)
    tmp.replace(path)
    return path


def clear_logs(prefix):
    for path in [*prefix.dir.glob("steam-*.log"), prefix.dir / "umu.log"]:
        path.unlink(missing_ok=True)


def run_logged(ui, prefix, args):
    """Run the launch script with umu's output and a Proton log, then show them."""
    clear_logs(prefix)
    env = dict(os.environ, PROTON_LOG="1")
    with open(prefix.dir / "umu.log", "wb") as out:
        subprocess.run([str(write_launch_script(prefix)), *args], env=env, stdout=out, stderr=subprocess.STDOUT, check=False)
    try:
        cmd_log(ui, prefix.name)
    except Abort as e:
        ui.error(str(e))


def run_in_prefix(ui, prefix, exe, log=False):
    """Run a program, such as an installer, in a prefix and wait for it. With log, with
    umu's output and a Proton log, shown when it ends."""
    if log:
        run_logged(ui, prefix, [exe])
    else:
        subprocess.run([str(write_launch_script(prefix)), exe], check=False)


# ---------------------------------------------------------------------------------------------
# Talking to the user: windows with a display, the terminal without one


class TermUI:
    gui = False

    def busy(self):
        """Around work that takes a while, after the questions."""
        return nullcontext()

    def error(self, message):
        print(f"{APP}: {message}", file=sys.stderr)

    def info(self, message):
        print(f"{APP}: {message}")

    def _input(self, prompt):
        try:
            return input(prompt)
        except EOFError:
            raise Cancelled() from None

    def ask_text(self, prompt, suggestion):
        return self._input(f"{prompt} [{suggestion}] ").strip() or suggestion

    def ask_file(self, title, start, filter=EXE_FILTER):
        reply = self._input(f"{title}: ").strip()
        if not reply:
            raise Cancelled()
        return os.path.expanduser(reply)

    def ask_save(self, title, suggestion, filter=ZIP_FILTER):
        return os.path.expanduser(self.ask_text(title, suggestion))

    def ask_folder(self, title, start):
        reply = self._input(f"{title}: ").strip()
        if not reply:
            raise Cancelled()
        return os.path.expanduser(reply)

    def ask_yesno(self, question):
        return self._input(f"{question} [y/N] ").strip().lower() == "y"

    def ask_kind(self, question, guess="install"):
        hint = "[I]nstall or [a]dd" if guess == "install" else "[i]nstall or [A]dd"
        reply = self._input(f"{question} {hint}? ").strip().lower()
        if not reply:
            return guess
        if reply.startswith("i"):
            return "install"
        if reply.startswith("a"):
            return "installed"
        raise Cancelled()

    def ask_add(self, question, suggested, names, guess="install"):
        return {"mode": self.ask_kind(question, guess), "name": "", "version": None, "category": None, "log": False}

    def ask_proton(self, current):
        return None

    def pick_prefix(self, names, prompt):
        if not names:
            raise Abort("no prefixes to choose from")
        if not (sys.stdin.isatty() and sys.stderr.isatty()):
            raise Abort("prefix name missing")
        if shutil.which("fzf"):
            r = subprocess.run(
                ["fzf", "--height", "40%", "--reverse", "--border", "rounded", "--no-info", "--pointer", ">",
                 "--prompt", "> ", "--header", f"{prompt} (arrows to move, Enter to select)"],
                input="\n".join(names), stdout=subprocess.PIPE, text=True, check=False)
            if r.returncode != 0 or not r.stdout.strip():
                raise Cancelled()
            return r.stdout.strip()
        for i, name in enumerate(names, 1):
            print(f"{i}) {name}", file=sys.stderr)
        reply = self._input(f"{prompt} (number): ").strip()
        if reply.isdigit() and 1 <= int(reply) <= len(names):
            return names[int(reply) - 1]
        raise Cancelled()

    def pick_shortcuts(self, rows, ticked=None, own_names=None, add=False, category=None):
        return [(r[0], r[1], r[1], category or default_category()) for r in rows]

    def show_log(self, name, text):
        if sys.stdout.isatty() and shutil.which("less"):
            subprocess.run(["less", "+G"], input=text, text=True, check=False)
        else:
            print(text)


_qt = None
_app = None
_tips = None


def qt():
    """PySide6, loaded on first use, with the one application object."""
    global _qt, _app, _tips
    if _qt is None:
        from PySide6 import QtCore, QtGui, QtWidgets

        _qt = (QtCore, QtGui, QtWidgets)
        _app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([APP])
        _app.setApplicationName(APP)
        _app.setDesktopFileName(f"{APP}-manager")
        _app.setQuitOnLastWindowClosed(False)

        # Qt wraps only rich-text tooltips, so long plain ones are made rich text when shown
        class WrapTips(QtCore.QObject):
            def eventFilter(self, obj, event):
                if event.type() == QtCore.QEvent.ToolTip and isinstance(obj, QtWidgets.QWidget):
                    tip = obj.toolTip()
                    if tip and not tip.startswith("<qt>"):
                        obj.setToolTip(f"<qt>{html.escape(tip)}</qt>")
                return False

        _tips = WrapTips()
        _app.installEventFilter(_tips)
    return _qt


def gui_available():
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return False
    import importlib.util

    return importlib.util.find_spec("PySide6") is not None


class QtUI(TermUI):
    gui = True

    @contextmanager
    def busy(self):
        QtCore, QtGui, QtWidgets = qt()
        QtWidgets.QApplication.setOverrideCursor(QtCore.Qt.WaitCursor)
        try:
            yield
        finally:
            QtWidgets.QApplication.restoreOverrideCursor()

    # Building blocks

    def dialog(self, title, width=520):
        QtCore, QtGui, QtWidgets = qt()
        dlg = QtWidgets.QDialog(QtWidgets.QApplication.activeWindow())
        dlg.setWindowTitle(title)
        dlg.resize(width, 10)
        layout = QtWidgets.QVBoxLayout(dlg)
        return dlg, layout

    def label(self, text, width):
        """A label that wraps long text onto more lines, with room for all of them. Qt sizes a window
        as if a wrapped label had one line, which cuts the text off."""
        QtCore, QtGui, QtWidgets = qt()
        lab = QtWidgets.QLabel(text)
        lab.setWordWrap(True)
        lab.setMinimumHeight(lab.heightForWidth(width - 40))
        return lab

    def buttons(self, dlg, layout, specs, left=1):
        """A row of buttons. The first, the one that closes the window (Cancel, Close, No), is on the
        left, with the next left - 1 beside it, the rest on the right. A spec is (label, tooltip,
        result code or function)."""
        QtCore, QtGui, QtWidgets = qt()
        row = QtWidgets.QHBoxLayout()
        made = {}
        for i, (label, tip, action) in enumerate(specs):
            button = QtWidgets.QPushButton(label)
            button.setAutoDefault(False)
            if tip:
                button.setToolTip(tip)
            if callable(action):
                button.clicked.connect(action)
            else:
                button.clicked.connect(lambda _=False, code=action: dlg.done(code))
            row.addWidget(button)
            if i == left - 1:
                row.addStretch(1)
            made[label] = button
        layout.addLayout(row)
        return made

    def message(self, text, icon):
        QtCore, QtGui, QtWidgets = qt()
        box = QtWidgets.QMessageBox(icon, APP, text, QtWidgets.QMessageBox.Ok, QtWidgets.QApplication.activeWindow())
        box.exec()

    # The questions

    def error(self, message):
        super().error(message)
        self.message(message, qt()[2].QMessageBox.Warning)

    def info(self, message):
        super().info(message)
        self.message(message, qt()[2].QMessageBox.Information)

    def ask_text(self, prompt, suggestion):
        QtCore, QtGui, QtWidgets = qt()
        dlg, layout = self.dialog(APP, 480)
        layout.addWidget(self.label(prompt, 480))
        entry = QtWidgets.QLineEdit(suggestion)
        entry.selectAll()
        layout.addWidget(entry)
        made = self.buttons(dlg, layout, [("Cancel", None, 0), ("OK", None, 1)])
        made["OK"].setDefault(True)
        if not dlg.exec():
            raise Cancelled()
        return entry.text().strip()

    def ask_file(self, title, start, filter=EXE_FILTER):
        QtCore, QtGui, QtWidgets = qt()
        path, _ = QtWidgets.QFileDialog.getOpenFileName(QtWidgets.QApplication.activeWindow(), title, str(start), filter)
        if not path:
            raise Cancelled()
        return path

    def ask_folder(self, title, start):
        QtCore, QtGui, QtWidgets = qt()
        path = QtWidgets.QFileDialog.getExistingDirectory(QtWidgets.QApplication.activeWindow(), title, str(start))
        if not path:
            raise Cancelled()
        return path

    def ask_save(self, title, suggestion, filter=ZIP_FILTER):
        """A file to write. The dialog asks before replacing one that exists."""
        QtCore, QtGui, QtWidgets = qt()
        path, _ = QtWidgets.QFileDialog.getSaveFileName(QtWidgets.QApplication.activeWindow(), title, str(suggestion), filter)
        if not path:
            raise Cancelled()
        return path

    def ask_yesno(self, question):
        QtCore, QtGui, QtWidgets = qt()
        dlg, layout = self.dialog(APP, 420)
        layout.addWidget(self.label(question, 420))
        made = self.buttons(dlg, layout, [("No", None, 0), ("Yes", None, 1)])
        made["No"].setDefault(True)
        return bool(dlg.exec())

    def ask_kind(self, question, guess="install"):
        QtCore, QtGui, QtWidgets = qt()
        dlg, layout = self.dialog(APP, 420)
        layout.addWidget(self.label(question, 420))
        made = self.buttons(dlg, layout, [
            ("Cancel", None, 0),
            ("Add", "The program is already installed. Run it from where it is", 2),
            ("Install", "Run this installer in the prefix, then choose its shortcuts", 1),
        ])
        made["Install" if guess == "install" else "Add"].setDefault(True)
        code = dlg.exec()
        if code == 1:
            return "install"
        if code == 2:
            return "installed"
        raise Cancelled()

    def ask_add(self, question, suggested, names, guess="install"):
        """The question for a double-clicked exe: install or add, which prefix, Proton version and
        whether to run with logs. Categories are set per entry, in Shortcuts."""
        QtCore, QtGui, QtWidgets = qt()
        width = max(520, min(1600, len(suggested) * 9 + 260))
        dlg, layout = self.dialog(APP, width)
        form = QtWidgets.QFormLayout()
        layout.addLayout(form)

        def row(label, widget, tip):
            widget.setToolTip(tip)
            lab = QtWidgets.QLabel(label)
            lab.setToolTip(tip)
            form.addRow(lab, widget)

        # A new prefix by default. The list also has the ones that exist, to put the program in one.
        prefix_box = QtWidgets.QComboBox()
        prefix_box.setEditable(True)
        prefix_box.addItems([suggested] + [n for n in names if n != suggested])
        row("Installation prefix", prefix_box, "A prefix is a Windows installation of its own, with its own C: drive and "
            "settings. One per program is best, so they cannot break each other. Type a name for a new one, or choose one that exists to put the program in it. Proton version "
            "is only for a new prefix")
        versions = proton_versions()
        current = default("PROTONPATH")
        proton = None
        if versions:
            proton = QtWidgets.QComboBox()
            proton.addItems(versions + ([current] if current and current not in versions else []))
            if current:
                proton.setCurrentText(current)
            row("Proton version", proton, "The Proton the programs in this prefix run with. Can be changed later in Settings")
        log = QtWidgets.QCheckBox("Run with log")
        log.setToolTip("Install: log the installer. Add: start the program once with logs. The logs open in a "
                       "window when it ends, to find out why something fails")
        form.addRow("", log)
        # What the file looks like, and so which button is the default, right above the buttons
        layout.addSpacing(6)
        layout.addWidget(self.label(question, width))
        made = self.buttons(dlg, layout, [
            ("Cancel", None, 0),
            ("Add", "The program is already installed. Run it from where it is", 2),
            ("Install", "Run this installer in a new prefix, then choose the program's exe", 1),
        ])
        made["Install" if guess == "install" else "Add"].setDefault(True)
        code = dlg.exec()
        if code not in (1, 2):
            raise Cancelled()
        return {
            "mode": "install" if code == 1 else "installed",
            "name": prefix_box.currentText(),
            "version": proton.currentText() if proton else None,
            "category": None,
            "log": log.isChecked(),
        }

    def ask_proton(self, current):
        versions = proton_versions()
        if not versions:
            return None
        QtCore, QtGui, QtWidgets = qt()
        dlg, layout = self.dialog(APP, 420)
        layout.addWidget(QtWidgets.QLabel("Proton version"))
        box = QtWidgets.QComboBox()
        box.addItems(versions)
        if current in versions:
            box.setCurrentText(current)
        layout.addWidget(box)
        made = self.buttons(dlg, layout, [("Cancel", None, 0), ("OK", None, 1)])
        made["OK"].setDefault(True)
        if not dlg.exec():
            raise Cancelled()
        return box.currentText()

    def pick_prefix(self, names, prompt):
        if not names:
            raise Abort("no prefixes to choose from")
        QtCore, QtGui, QtWidgets = qt()
        dlg, layout = self.dialog(APP, 420)
        dlg.resize(420, 360)
        layout.addWidget(self.label(prompt, 420))
        lst = QtWidgets.QListWidget()
        lst.addItems(names)
        lst.setCurrentRow(0)
        lst.itemDoubleClicked.connect(lambda _: dlg.done(1))
        layout.addWidget(lst)
        made = self.buttons(dlg, layout, [("Cancel", None, 0), ("OK", None, 1)])
        made["OK"].setDefault(True)
        if not dlg.exec() or not lst.currentItem():
            raise Cancelled()
        return lst.currentItem().text()

    def pick_shortcuts(self, rows, ticked=None, own_names=None, add=False, category=None):
        """Which shortcuts get a start menu entry, their names, programs and categories. Returns the
        ticked (name, exe, exe it was listed with, category) in order; double-clicking a program path
        points the row to another one. rows are (name, exe), or with the exe they were listed with
        and their category; category is for rows without one. ticked is the exes
        that start ticked; without it all are, and there is an Other file button, which returns an
        empty list to choose the file by hand. own_names (exe: name) is what Original name and an
        emptied name give back. With add there is an Add button, which returns ("add", all rows as
        they are now, the exes ticked now) to put a program in and open the list again."""
        category = category or default_category()
        if not rows and not add:
            return []
        QtCore, QtGui, QtWidgets = qt()
        own_names = own_names or {}

        def own(exe):
            return own_names.get(exe) or program_name(exe)

        dlg, layout = self.dialog(APP, 640)
        dlg.resize(640, 360)
        layout.addWidget(self.label("Which shortcuts go in the start menu? Double-click a name to change it, or a "
                                    "program to point the shortcut to another one.", 640))
        table = QtWidgets.QTableWidget(len(rows), 4)
        table.setHorizontalHeaderLabels(["", "Name", "Category", "Program"])
        table.verticalHeader().hide()
        table.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectRows)
        table.setSelectionMode(QtWidgets.QAbstractItemView.SingleSelection)
        table.setEditTriggers(QtWidgets.QAbstractItemView.DoubleClicked | QtWidgets.QAbstractItemView.EditKeyPressed)
        def category_box(value):
            box = QtWidgets.QComboBox()
            box.addItems([label for label, _ in CATEGORIES])
            box.setCurrentText(category_label(value))
            box.setToolTip("Where this entry goes in the start menu")
            return box

        for r, row in enumerate(rows):
            name, exe = row[0], row[1]
            listed = row[2] if len(row) > 2 else exe
            row_category = row[3] if len(row) > 3 else category
            check = QtWidgets.QTableWidgetItem()
            check.setFlags(QtCore.Qt.ItemIsUserCheckable | QtCore.Qt.ItemIsEnabled | QtCore.Qt.ItemIsSelectable)
            on = ticked is None or exe in ticked
            check.setCheckState(QtCore.Qt.Checked if on else QtCore.Qt.Unchecked)
            table.setItem(r, 0, check)
            table.setItem(r, 1, QtWidgets.QTableWidgetItem(name))
            table.setCellWidget(r, 2, category_box(row_category))
            program = QtWidgets.QTableWidgetItem(short_path(exe))
            program.setFlags(QtCore.Qt.ItemIsEnabled | QtCore.Qt.ItemIsSelectable)
            program.setToolTip(exe)
            # The program now, and the one the row was listed with
            program.setData(QtCore.Qt.UserRole, exe)
            program.setData(QtCore.Qt.UserRole + 1, listed)
            table.setItem(r, 3, program)
        header = table.horizontalHeader()
        header.setSectionResizeMode(0, QtWidgets.QHeaderView.ResizeToContents)
        header.setSectionResizeMode(1, QtWidgets.QHeaderView.Interactive)
        header.setSectionResizeMode(2, QtWidgets.QHeaderView.ResizeToContents)
        header.setSectionResizeMode(3, QtWidgets.QHeaderView.Stretch)
        table.setColumnWidth(1, 200)
        layout.addWidget(table)

        def original_name():
            r = table.currentRow()
            if r < 0:
                self.info("Choose a shortcut first.")
                return
            table.item(r, 1).setText(own(table.item(r, 3).data(QtCore.Qt.UserRole + 1)))

        def change_program(r, column):
            if column != 3:
                return
            item = table.item(r, 3)
            current = item.data(QtCore.Qt.UserRole)
            try:
                exe = os.path.realpath(self.ask_file("Choose the program this shortcut starts", os.path.dirname(current)))
            except Cancelled:
                return
            item.setText(short_path(exe))
            item.setToolTip(exe)
            item.setData(QtCore.Qt.UserRole, exe)

        table.cellDoubleClicked.connect(change_program)

        specs = [("Cancel", None, 0)]
        if ticked is None:
            specs.append(("Other file", "None of these: choose the program's file by hand", 3))
        if add:
            specs.append(("Add", "Install another program in this prefix, or add one that is on the disk", 4))
        specs += [
            ("Original name", "Give the chosen shortcut back the name of its Windows shortcut", original_name),
            ("OK", None, 1),
        ]
        made = self.buttons(dlg, layout, specs)
        made["OK"].setDefault(True)
        code = dlg.exec()
        if code == 3:
            return []
        if code == 4:
            state = [(table.item(r, 1).text(), table.item(r, 3).data(QtCore.Qt.UserRole),
                      table.item(r, 3).data(QtCore.Qt.UserRole + 1), category_value(table.cellWidget(r, 2).currentText()))
                     for r in range(table.rowCount())]
            now = {table.item(r, 3).data(QtCore.Qt.UserRole) for r in range(table.rowCount())
                   if table.item(r, 0).checkState() == QtCore.Qt.Checked}
            return ("add", state, now)
        if code != 1:
            raise Cancelled()
        picked = []
        for r in range(table.rowCount()):
            if table.item(r, 0).checkState() == QtCore.Qt.Checked:
                exe = table.item(r, 3).data(QtCore.Qt.UserRole)
                listed = table.item(r, 3).data(QtCore.Qt.UserRole + 1)
                name = one_line(table.item(r, 1).text()).replace("|", "") or own(listed)
                picked.append((name, exe, listed, category_value(table.cellWidget(r, 2).currentText())))
        return picked

    def show_log(self, name, text):
        QtCore, QtGui, QtWidgets = qt()
        dlg, layout = self.dialog(f"{APP}: log of {name}", 1000)
        dlg.resize(1000, 650)
        view = QtWidgets.QPlainTextEdit()
        view.setReadOnly(True)
        view.setLineWrapMode(QtWidgets.QPlainTextEdit.NoWrap)
        view.setFont(QtGui.QFontDatabase.systemFont(QtGui.QFontDatabase.FixedFont))
        view.setPlainText(text)
        view.moveCursor(QtGui.QTextCursor.End)
        layout.addWidget(view)

        def save():
            path, _ = QtWidgets.QFileDialog.getSaveFileName(dlg, f"Save the log of {name}", str(HOME / f"{APP}-{name}.log"))
            if path:
                Path(path).write_text(text, encoding="utf-8")

        self.buttons(dlg, layout, [
            ("Close", None, 0),
            ("Save log", "Save the whole log to a file, to share it or look at it later", save),
        ])
        dlg.exec()

    def settings(self, prefix):
        """All the settings of a prefix in one window. Returns the prefix after Save (renamed if its name
        was changed at the top), None after Cancel or Remove. Shortcuts opens its own window
        and leave this one open."""
        QtCore, QtGui, QtWidgets = qt()
        dlg, layout = self.dialog(f"{APP}: {prefix.name}", 640)
        # The prefix's name as the title, renamed by double-clicking it, with Remove on the right
        class NameEdit(QtWidgets.QLineEdit):
            """Looks like a bold label until double-clicked. Enter keeps the new name, for Save to rename
            the prefix with; Escape or leaving it puts the name back."""

            def __init__(self, text):
                super().__init__(text)
                self.value = text
                font = self.font()
                font.setBold(True)
                self.setFont(font)
                self.setToolTip("Double-click to give the prefix a new name, then Enter and Save. Escape leaves it. "
                                "The start menu names stay")
                self.editing(False)

            def editing(self, on):
                self.setReadOnly(not on)
                self.setFrame(on)
                palette = self.palette()
                role = QtGui.QPalette.Base if on else QtGui.QPalette.Window
                palette.setColor(QtGui.QPalette.Base, QtWidgets.QApplication.palette().color(role))
                self.setPalette(palette)
                if on:
                    self.selectAll()
                    self.setFocus()
                else:
                    self.deselect()

            def finish(self, commit):
                if self.isReadOnly():
                    return
                self.editing(False)
                new = clean_name(self.text())
                if commit and new:
                    self.value = new
                self.setText(self.value)

            def mouseDoubleClickEvent(self, event):
                if self.isReadOnly():
                    self.editing(True)
                else:
                    super().mouseDoubleClickEvent(event)

            def keyPressEvent(self, event):
                # Enter and Escape are for the name while it is edited, not for the window's buttons
                if not self.isReadOnly() and event.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter):
                    self.finish(True)
                elif not self.isReadOnly() and event.key() == QtCore.Qt.Key_Escape:
                    self.finish(False)
                else:
                    super().keyPressEvent(event)

            def focusOutEvent(self, event):
                self.finish(False)
                super().focusOutEvent(event)

        top = QtWidgets.QHBoxLayout()
        title = NameEdit(prefix.name)
        top.addWidget(title, 1)
        remove_button = QtWidgets.QPushButton("Remove")
        remove_button.setAutoDefault(False)
        remove_button.setToolTip("Delete the prefix, with what is installed and saved in it, and its start menu entries")
        top.addWidget(remove_button)
        layout.addLayout(top)
        # Proton version first, then the checkboxes, then the custom variables. Each start menu entry has
        # its own category, in Shortcuts.
        grid = QtWidgets.QGridLayout()
        boxes = {}
        for i, (key, on, _, label, tip) in enumerate(KNOWN):
            box = QtWidgets.QCheckBox(label)
            box.setToolTip(tip)
            box.setChecked(prefix.setting(key) == on)
            grid.addWidget(box, i // 2, i % 2)
            boxes[key] = box
        # esync and fsync do nothing with NTSync on, so their boxes only show with it off
        def sync_boxes():
            for key in ("PROTON_NO_ESYNC", "PROTON_NO_FSYNC"):
                boxes[key].setVisible(not boxes["PROTON_USE_NTSYNC"].isChecked())

        boxes["PROTON_USE_NTSYNC"].toggled.connect(sync_boxes)
        sync_boxes()
        line = QtWidgets.QHBoxLayout()
        layout.addLayout(line)

        def field(label, widget, tip, stretch):
            widget.setToolTip(tip)
            lab = QtWidgets.QLabel(label)
            lab.setToolTip(tip)
            line.addWidget(lab)
            line.addWidget(widget, stretch)

        versions = proton_versions()
        current = prefix.setting("PROTONPATH")
        if current and current not in versions:
            versions.append(current)
        proton = QtWidgets.QComboBox()
        proton.addItems(versions)
        if current:
            proton.setCurrentText(current)
        field("Proton version", proton, "The Proton the programs in this prefix run with, from compatibilitytools.d", 2)
        layout.addLayout(grid)
        tip = "Any Proton or Wine environment variable, such as WINEDLLOVERRIDES=dinput8=n,b"
        lab = QtWidgets.QLabel("Custom variables, KEY=value one per line")
        lab.setToolTip(tip)
        layout.addWidget(lab)
        custom = QtWidgets.QPlainTextEdit()
        custom.setToolTip(tip)
        custom.setPlainText("\n".join(f"{k}={v}" for k, v in read_conf(prefix.config) if k not in MANAGED))
        layout.addWidget(custom)

        def guarded(fn):
            def run():
                try:
                    fn()
                except Cancelled:
                    pass
                except Abort as e:
                    self.error(str(e))
            return run

        def remove():
            guarded(lambda: cmd_remove(self, prefix.name))()
            # Nothing left to save the settings of
            if not prefix.exists():
                dlg.done(0)

        remove_button.clicked.connect(remove)

        # The saves on the left and Shortcuts on the right, on a row of their own above the usual buttons
        row = QtWidgets.QHBoxLayout()
        row.addWidget(QtWidgets.QLabel("Saves:"))
        for label, tip, fn in [
            ("Backup to zip", "Save the prefix's Windows user folder, where programs keep their saves, to a zip file",
             lambda: cmd_backup(self, prefix.name)),
            ("Restore from zip", "Put a backup back into the prefix. Files in it replace the ones here, others stay",
             lambda: cmd_restore(self, prefix.name)),
            ("Import from prefix", "Copy the saves of a prefix made elsewhere (Heroic, Steam, Wine) into this one",
             lambda: cmd_import_saves(self, prefix.name)),
        ]:
            button = QtWidgets.QPushButton(label)
            button.setAutoDefault(False)
            button.setToolTip(tip)
            button.clicked.connect(guarded(fn))
            row.addWidget(button)
        row.addStretch(1)
        button = QtWidgets.QPushButton("Shortcuts")
        button.setAutoDefault(False)
        button.setToolTip("Which shortcuts of the prefix are in the start menu, their names and programs, and Add to "
                          "put another program in")
        button.clicked.connect(guarded(lambda: cmd_shortcuts(self, prefix.name)))
        row.addWidget(button)
        layout.addLayout(row)
        # A gap above the window's own buttons, so Cancel and Save read as being for the whole window
        layout.addSpacing(16)

        def stop():
            with self.busy():
                guarded(lambda: cmd_stop(self, prefix.name))()
            made["Stop"].setEnabled(prefix.running())

        def reset():
            # Shown here only, saved with Save
            defaults = load_conf(SYSTEM_CONF, USER_CONF)
            for key, on, _, _, _ in KNOWN:
                boxes[key].setChecked(defaults.get(key) == on)
            version = defaults.get("PROTONPATH")
            if version:
                if proton.findText(version) < 0:
                    proton.addItem(version)
                proton.setCurrentText(version)
            custom.setPlainText("\n".join(f"{k}={v}" for k, v in defaults.items() if k not in MANAGED))

        def save():
            # A new name is checked before the window closes, so a problem leaves everything open
            new = title.value
            if new != prefix.name:
                if Prefix(new).dir.exists():
                    self.error(f"already exists: {new}")
                    return
                if prefix.running():
                    self.error(f"{prefix.name} is running. Stop it first, or keep its name.")
                    return
            dlg.done(1)

        made = self.buttons(dlg, layout, [
            ("Cancel", None, 0),
            ("Reset to defaults", "Set the options, Proton version and custom variables to the defaults. "
             "Nothing changes until Save", reset),
            ("Stop", "Close everything that runs in this prefix", stop),
            ("Save", None, save),
        ], left=3)
        # Only something that runs can be stopped
        made["Stop"].setEnabled(prefix.running())
        made["Save"].setDefault(True)
        if not dlg.exec():
            return None
        selected = {key for key, box in boxes.items() if box.isChecked()}
        apply_options(prefix, selected, custom.toPlainText())
        if proton.currentText():
            apply_proton(prefix, proton.currentText())
        if title.value != prefix.name:
            prefix = cmd_rename(self, prefix.name, title.value) or prefix
        return prefix

    def manager(self):
        """One window with the prefixes. Add makes a new one. A double-click (or Enter) opens a
        prefix's settings, where everything else is; its right-click menu has Settings, Rename,
        Stop and Remove."""
        QtCore, QtGui, QtWidgets = qt()
        dlg, layout = self.dialog(APP, 680)
        dlg.resize(680, 480)
        dlg.setWindowFlags(dlg.windowFlags() | QtCore.Qt.WindowMinMaxButtonsHint)
        layout.addWidget(QtWidgets.QLabel("Double-click a prefix for its settings, right-click it for more."))
        table = QtWidgets.QTableWidget(0, 2)
        table.setHorizontalHeaderLabels(["Prefix", "Status"])
        table.verticalHeader().hide()
        table.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectRows)
        table.setSelectionMode(QtWidgets.QAbstractItemView.SingleSelection)
        table.setEditTriggers(QtWidgets.QAbstractItemView.NoEditTriggers)
        table.horizontalHeader().setSectionResizeMode(0, QtWidgets.QHeaderView.Stretch)
        table.horizontalHeader().setSectionResizeMode(1, QtWidgets.QHeaderView.ResizeToContents)
        layout.addWidget(table)

        def fill():
            chosen = selected(quiet=True)
            names = prefix_names()
            running = running_names()
            table.setRowCount(len(names))
            for r, name in enumerate(names):
                table.setItem(r, 0, QtWidgets.QTableWidgetItem(name))
                table.setItem(r, 1, QtWidgets.QTableWidgetItem("running" if name in running else ""))
                if name == chosen:
                    table.selectRow(r)

        def update_status():
            """Every few seconds: only the Status column, so the chosen row stays. A prefix added or
            removed elsewhere fills the whole list again."""
            names = [table.item(r, 0).text() for r in range(table.rowCount()) if table.item(r, 0)]
            if names != prefix_names():
                fill()
                return
            running = running_names()
            for r, name in enumerate(names):
                status = "running" if name in running else ""
                if table.item(r, 1).text() != status:
                    table.item(r, 1).setText(status)

        timer = QtCore.QTimer(dlg)
        timer.timeout.connect(update_status)
        timer.start(5000)

        def selected(quiet=False):
            r = table.currentRow()
            if r < 0 or not table.item(r, 0):
                if not quiet:
                    self.info("Choose a prefix first.")
                return None
            return table.item(r, 0).text()

        def act(fn, needs_name=True):
            def run():
                name = selected() if needs_name else None
                if needs_name and not name:
                    return
                try:
                    fn(name) if needs_name else fn()
                except Cancelled:
                    pass
                except Abort as e:
                    self.error(str(e))
                fill()
            return run

        def stop(name):
            QtWidgets.QApplication.setOverrideCursor(QtCore.Qt.WaitCursor)
            try:
                cmd_stop(self, name)
            finally:
                QtWidgets.QApplication.restoreOverrideCursor()

        settings = act(lambda n: cmd_settings(self, n))
        # Rename edits the name in the list. Enter renames the folder, Escape leaves it as it was.
        editing = {"old": None}

        def rename():
            name = selected()
            if not name:
                return
            editing["old"] = name
            table.editItem(table.item(table.currentRow(), 0))

        def renamed(item):
            old = editing["old"]
            if old is None or item.column() != 0:
                return
            editing["old"] = None
            new = item.text().strip()
            if new and new != old:
                try:
                    cmd_rename(self, old, new)
                except Cancelled:
                    pass
                except Abort as e:
                    self.error(str(e))
            fill()
            # The renamed prefix stays chosen, under its new name
            for r in range(table.rowCount()):
                if table.item(r, 0).text() == clean_name(new):
                    table.selectRow(r)

        table.itemChanged.connect(renamed)
        table.itemDelegate().closeEditor.connect(lambda *_: QtCore.QTimer.singleShot(0, lambda: editing.update(old=None)))
        stop_it = act(stop)
        remove_it = act(lambda n: cmd_remove(self, n))
        table.itemDoubleClicked.connect(lambda _: settings())

        add = act(lambda: cmd_add(self), needs_name=False)


        def context_menu(pos):
            item = table.itemAt(pos)
            if not item:
                # Empty space: only Add makes sense
                menu = QtWidgets.QMenu(table)
                menu.addAction("Add", add)
                menu.exec(table.viewport().mapToGlobal(pos))
                return
            table.selectRow(item.row())
            menu = QtWidgets.QMenu(table)
            menu.addAction("Settings", settings)
            menu.addAction("Rename", rename)
            menu.addAction("Stop", stop_it)
            menu.addSeparator()
            menu.addAction("Remove", remove_it)
            menu.exec(table.viewport().mapToGlobal(pos))

        table.setContextMenuPolicy(QtCore.Qt.CustomContextMenu)
        table.customContextMenuRequested.connect(context_menu)
        self.buttons(dlg, layout, [
            ("Close", None, 0),
            ("Add", "New prefix. Install a program or add one that is on the disk", add),
        ])
        # Enter on the chosen prefix opens its settings, like a double-click
        # Only key presses on the list itself: while a name is edited, Enter goes to the text field
        class EnterOpens(QtCore.QObject):
            def eventFilter(self, obj, event):
                # An Enter that the name's text field passed on is not for the list
                if (event.type() == QtCore.QEvent.KeyPress and event.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter)
                        and QtWidgets.QApplication.focusWidget() is table):
                    settings()
                    return True
                return False

        enter_opens = EnterOpens(table)
        table.installEventFilter(enter_opens)
        QtGui.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_F2), table, rename, context=QtCore.Qt.WidgetShortcut)
        upgrade_all()
        fill()
        if table.rowCount():
            table.selectRow(0)
        dlg.exec()


# ---------------------------------------------------------------------------------------------
# Commands


def pick(ui, name, prompt="Choose a prefix", names=None):
    if not name:
        name = ui.pick_prefix(prefix_names() if names is None else names, prompt)
    return Prefix(name).require()


def ask_prefix(ui, question):
    if not prefix_names():
        raise Abort("no prefixes yet, double-click an exe to make the first one")
    return Prefix(ui.pick_prefix(prefix_names(), question)).require()


def real_file(path):
    if not path or not os.path.isfile(path):
        raise Abort(f"not a file: {path}")
    return os.path.realpath(path)


def cmd_add(ui, mode=None, file=None):
    """Add a program: an installer is run in a new prefix, one that is on the disk is added as it is.
    A prefix that exists gets the program as another of its shortcuts."""
    file = real_file(file or ui.ask_file("Choose the installer or the program", HOME))
    answer = {"mode": mode, "name": "", "version": None, "category": None, "log": False}
    asked = not mode
    if asked:
        guess, question = kind_question(file)
        answer = ui.ask_add(question, os.path.basename(os.path.dirname(file)), prefix_names(), guess)
    mode, log = answer["mode"], answer["log"]
    # Without the dialog above (--install, --installed) the name is asked on its own
    name = answer["name"] or ui.ask_text("Name of the prefix", os.path.basename(os.path.dirname(file)))
    name = clean_name(name)
    if not name:
        raise Abort("empty prefix name")
    prefix = Prefix(name)
    # A prefix that exists gets the program added, also one that has no start menu entries now.
    # One whose installer ran but whose program was never picked carries on below instead.
    if prefix.exists() and (prefix.exe or not (prefix.dir / ".installed").exists() or mode == "installed"):
        if mode == "install":
            install_in_prefix(ui, prefix, file, log)
        else:
            add_to_prefix(ui, prefix, file)
            if log:
                cmd_run(ui, prefix.name, ["--log", "--exe", file])
        return

    # Without the dialog above the version is asked on its own
    version = answer["version"] if asked else ui.ask_proton(default("PROTONPATH"))
    prefix.wine.mkdir(parents=True, exist_ok=True)
    prefix.config.touch()
    write_launch_script(prefix)
    if version:
        apply_proton(prefix, version)
    if answer["category"]:
        apply_category(prefix, answer["category"])

    title, links = "", []
    if mode == "installed":
        # A program that is already on the disk is run from where it is, named after its file. The
        # shortcut list shows it, to name it and choose its category; Cancel leaves no prefix behind.
        exe = file
        title = program_name(exe)
        if ui.gui:
            try:
                picks = ui.pick_shortcuts([(title, exe)], {exe}, {exe: title}, category=prefix.category)
                if not picks:
                    raise Cancelled()
            except Cancelled:
                shutil.rmtree(prefix.dir, ignore_errors=True)
                raise
            title, exe, _, category = picks[0]
            exe = real_file(exe)
            apply_category(prefix, category)
    else:
        # A prefix that was installed but never got its exe picked skips the installer
        if not (prefix.dir / ".installed").exists():
            run_in_prefix(ui, prefix, file, log)
            (prefix.dir / ".installed").touch()
        # The shortcuts the installer made tell which files are the program and its helpers
        rows = shortcut_programs(prefix.wine)
        picks = ui.pick_shortcuts(rows, None, dict((e, n) for n, e in rows), category=prefix.category)
        exe = ""
        if picks:
            title, exe, _, category = picks[0]
            apply_category(prefix, category)
            links = [(n, e, c) for n, e, _, c in picks[1:]]
        if not exe:
            exe = ui.ask_file("Choose the program", prefix.wine / "drive_c")
        exe = real_file(exe)

    extract_icon(exe, prefix.dir / "icon.png")
    prefix.set_keys({"LAUNCHER_EXE": exe})
    apply_title(prefix, title)
    set_links(prefix, links)
    write_desktop(prefix)
    ui.info(f"Added {prefix.title or prefix.name} to the start menu.")
    if mode == "installed" and log:
        cmd_run(ui, prefix.name, ["--log"])


def install_in_prefix(ui, prefix, installer, log=False):
    """Run an installer in a prefix that exists, then offer the new shortcuts."""
    before = {e for _, e in shortcut_programs(prefix.wine)}
    run_in_prefix(ui, prefix, installer, log)
    new = [e for _, e in shortcut_programs(prefix.wine) if e not in before]
    if not ui.gui:
        ui.info(f'Installed in the prefix of {prefix.name}. Run: {APP} shortcuts "{prefix.name}"')
        return
    cmd_shortcuts(ui, prefix.name, new)


def add_to_prefix(ui, prefix, exe):
    """A program that is on the disk becomes another start menu entry of a prefix."""
    links = prefix.links()
    if exe == prefix.exe or exe in (e for _, e, _ in links):
        raise Abort(f"already in the start menu: {os.path.basename(exe)}")
    if ui.gui:
        # The prefix's shortcut list, with this program added and ticked, to name it and choose its
        # category there
        cmd_shortcuts(ui, prefix.name, added=[exe])
        return
    label = one_line(ui.ask_text("Name in the start menu", program_name(exe))).replace("|", "")
    if not label:
        raise Abort("empty name")
    if not prefix.exe:
        # A prefix with no start menu entries: this becomes its main one
        apply_exe(prefix, exe)
        apply_title(prefix, label)
        write_desktop(prefix)
        ui.info(f"Added {label} to the start menu.")
        return
    set_links(prefix, links + [(label, exe, prefix.category)])
    write_desktop(prefix)
    ui.info(f"Added {label} to the start menu.")


def cmd_install_in(ui, file=None):
    file = real_file(file or ui.ask_file("Choose the installer", HOME))
    install_in_prefix(ui, ask_prefix(ui, f"Install {os.path.basename(file)} in which prefix?"), file)


def cmd_add_to(ui, file=None):
    file = real_file(file or ui.ask_file("Choose the program", HOME))
    add_to_prefix(ui, ask_prefix(ui, f"Add {os.path.basename(file)} to which prefix?"), file)


def cmd_add_in(ui, name=None, file=None):
    """Put another program in this prefix, by running its installer or adding it as it is."""
    prefix = pick(ui, name)
    file = real_file(file or ui.ask_file("Choose an installer, or a program that is already on the disk", HOME))
    if ui.ask_kind(*reversed(kind_question(file))) == "install":
        install_in_prefix(ui, prefix, file)
    else:
        add_to_prefix(ui, prefix, file)


def cmd_run(ui, name=None, args=()):
    """Start a prefix's program, the same way its start menu entry does: with the launch script.
    --log writes umu's output and a Proton log and shows them when it ends. --exe starts another
    program of the same prefix."""
    prefix = pick(ui, name)
    args = list(args)
    log = args[:1] == ["--log"]
    if log:
        args = args[1:]
    if args[:1] == ["--exe"]:
        if len(args) < 2 or not args[1]:
            raise Abort("--exe needs a program")
        args = args[1:]
    elif not prefix.exe:
        raise Abort(f"{prefix.name} has no program in the start menu. Choose one in its settings, Shortcuts.")
    script = str(write_launch_script(prefix))
    if log:
        run_logged(ui, prefix, args)
    else:
        # Become the program, so this one does not stay in memory
        os.execv(script, [script, *args])


def cmd_settings(ui, name=None):
    prefix = pick(ui, name)
    if not ui.gui:
        raise Abort(f"settings needs a graphical session. Edit {prefix.config} instead.")
    saved = ui.settings(prefix)
    if saved:
        write_desktop(saved)
        ui.info(f"Saved the settings for {saved.name}.")


def cmd_shortcuts(ui, name=None, extra=(), added=()):
    """Choose again which shortcuts of a prefix are in the start menu, their names and categories.
    extra is exes to tick besides the current entries, added is programs on the disk to list and tick."""
    prefix = pick(ui, name)
    if not ui.gui:
        raise Abort("shortcuts needs a graphical session")
    main = prefix.exe
    links = prefix.links()
    # An entry that is in the start menu is listed with the name and category it has there. Others
    # start with the main entry's category.
    named = {main: (prefix.title or prefix.name, prefix.category)} if main else {}
    for lname, lexe, lcategory in links:
        named.setdefault(lexe, (lname, lcategory))
    rows, seen, own_names = [], set(), {}
    for lname, lexe in shortcut_programs(prefix.wine):
        own_names[lexe] = lname
        shown, category = named.get(lexe, (lname, prefix.category))
        rows.append((shown, lexe, lexe, category))
        seen.add(lexe)
    # Entries the prefix has even if no shortcut is found for them
    if main and main not in seen:
        rows.insert(0, (*named[main][:1], main, main, named[main][1]))
        seen.add(main)
    for _, lexe, _ in links:
        if lexe not in seen:
            rows.append((named[lexe][0], lexe, lexe, named[lexe][1]))
            seen.add(lexe)
    for exe in added:
        if exe not in seen:
            rows.append((program_name(exe), exe, exe, prefix.category))
            seen.add(exe)
    ticked = {main, *(e for _, e, _ in links), *extra, *added} - {""}

    # Add puts a program in and opens the list again, as it was and with the new ones ticked
    while True:
        result = ui.pick_shortcuts(rows, ticked, own_names, add=True)
        if not (isinstance(result, tuple) and result[0] == "add"):
            picks = result
            break
        _, rows, ticked = result
        try:
            file = real_file(ui.ask_file("Choose an installer, or a program that is already on the disk", HOME))
            kind = ui.ask_kind(*reversed(kind_question(file)))
        except Cancelled:
            continue
        known = {r[1] for r in rows} | {r[2] for r in rows}
        if kind == "install":
            before = {e for _, e in shortcut_programs(prefix.wine)}
            run_in_prefix(ui, prefix, file)
            for lname, lexe in shortcut_programs(prefix.wine):
                if lexe not in before and lexe not in known:
                    rows.append((lname, lexe, lexe, prefix.category))
                    own_names[lexe] = lname
                    ticked.add(lexe)
        else:
            if file not in known:
                rows.append((program_name(file), file, file, prefix.category))
            ticked.add(file)

    if not picks:
        # None ticked: the prefix stays, without start menu entries
        if not prefix.exe:
            return
        if not ui.ask_yesno(f"Remove all start menu entries of {prefix.name}? The prefix and what is installed in it "
                            "stay, and the entries can be ticked again here."):
            raise Cancelled()
        prefix.set_keys({"LAUNCHER_EXE": None, "LAUNCHER_TITLE": None})
        set_links(prefix, [])
        write_desktop(prefix)
        return
    # The main entry stays the one it was if it is still ticked (perhaps pointed to another program),
    # otherwise the first ticked one takes over
    keep_row = next((p for p in picks if p[2] == main), picks[0])
    keep = keep_row[1]
    if keep != main:
        apply_exe(prefix, keep)
    apply_title(prefix, keep_row[0])
    apply_category(prefix, keep_row[3])
    links, seen = [], {keep}
    for name, exe, _, category in picks:
        if exe not in seen:
            links.append((name, exe, category))
            seen.add(exe)
    set_links(prefix, links)
    write_desktop(prefix)


def cmd_remove(ui, name=None):
    prefix = pick(ui, name)
    if not ui.ask_yesno(f"Remove {prefix.name}? Its prefix, with the saves inside it, is deleted."):
        raise Cancelled()
    shutil.rmtree(prefix.dir)
    remove_desktop(prefix.name)
    refresh_menu()


def cmd_rename(ui, name=None, new=None):
    """Give a prefix folder a new name. The start menu entries keep the name they show."""
    prefix = pick(ui, name)
    if prefix.running():
        raise Abort(f"{prefix.name} is running. Stop it first.")
    new = clean_name(new or ui.ask_text(f"New name for the prefix {prefix.name}", prefix.name))
    if not new:
        raise Abort("empty prefix name")
    if new == prefix.name:
        return None
    target = Prefix(new)
    if target.dir.exists():
        raise Abort(f"already exists: {new}")
    shown = prefix.title or prefix.name
    prefix.dir.rename(target.dir)
    # The exe, the other shortcuts and custom variables can point into the old folder
    old, now = str(prefix.dir) + "/", str(target.dir) + "/"
    for path in (target.config, target.links_file):
        if path.is_file():
            path.write_text(path.read_text(encoding="utf-8").replace(old, now), encoding="utf-8")
    remove_desktop(prefix.name)
    apply_title(target, shown)
    write_desktop(target)
    print(f"{APP}: renamed {prefix.name} to {new}")
    return target


def cmd_rename_shortcut(ui, name=None, exe=None):
    """Give one start menu entry of a prefix a new name: the main one, or the one that runs exe."""
    prefix = pick(ui, name)
    if not exe or exe == prefix.exe:
        new = one_line(ui.ask_text("Name in the start menu", prefix.title or prefix.name)).replace("|", "")
        if not new:
            raise Abort("empty name")
        apply_title(prefix, new)
    else:
        links = prefix.links()
        if exe not in (e for _, e, _ in links):
            raise Abort(f"not a shortcut of {prefix.name}: {exe}")
        current = next(n for n, e, _ in links if e == exe)
        new = one_line(ui.ask_text("Name in the start menu", current)).replace("|", "")
        if not new:
            raise Abort("empty name")
        # Only the name changes, the icons stay as they are
        write_lines(prefix.links_file, [f"{new if e == exe else n}|{c}|{e}" for n, e, c in links])
    write_desktop(prefix)


def cmd_running():
    running = running_names()
    return [n for n in prefix_names() if n in running]


def cmd_stop(ui, name=None):
    if not name:
        running = cmd_running()
        if not running:
            raise Abort("nothing is running")
        name = ui.pick_prefix(running, "Choose a prefix to stop")
    prefix = Prefix(name).require()
    pids = prefix.pids()
    if not pids:
        raise Abort(f"{prefix.name} is not running")
    # Ask nicely, then kill what is left after five seconds
    signal_all(pids, signal.SIGTERM)
    for _ in range(5):
        time.sleep(1)
        pids = prefix.pids()
        if not pids:
            break
    signal_all(pids, signal.SIGKILL)
    print(f"{APP}: stopped {prefix.name}")


def signal_all(pids, sig):
    for pid in pids:
        try:
            os.kill(pid, sig)
        except OSError:
            pass


def log_text(prefix):
    """The logs of the last run with --log: umu's output and the Proton log."""
    text = ""
    umu = prefix.dir / "umu.log"
    if umu.is_file() and umu.stat().st_size:
        text += "===== umu =====\n" + umu.read_text(encoding="utf-8", errors="replace").rstrip("\n") + "\n\n"
    protons = sorted(prefix.dir.glob("steam-*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
    if protons:
        text += "===== Proton =====\n" + protons[0].read_text(encoding="utf-8", errors="replace").rstrip("\n") + "\n"
    return text


def user_folder(prefix):
    """The Windows user's folder in the prefix, where programs keep their saves (Documents, Saved Games,
    AppData)."""
    return prefix.wine / "drive_c/users/steamuser"


def cmd_backup(ui, name=None, file=None):
    """Save the Windows user's folder of a prefix, with the programs' saves, to a zip file. Links to
    places outside the prefix are left out."""
    prefix = pick(ui, name)
    src = user_folder(prefix)
    if not src.is_dir():
        raise Abort(f"{prefix.name} has no saves yet. Start it once first.")
    file = file or ui.ask_save(f"Back up the saves of {prefix.name}", HOME / f"{prefix.name}-saves-{date.today()}.zip")
    part = file + ".part"
    try:
        with ui.busy(), zipfile.ZipFile(part, "w", zipfile.ZIP_DEFLATED) as z:
            for root, dirs, files in os.walk(src):
                dirs[:] = sorted(d for d in dirs if not os.path.islink(os.path.join(root, d)))
                for f in sorted(files):
                    path = os.path.join(root, f)
                    if os.path.islink(path) or not os.path.isfile(path):
                        continue
                    z.write(path, os.path.relpath(path, src))
        os.replace(part, file)
    except OSError as e:
        Path(part).unlink(missing_ok=True)
        raise Abort(f"could not write {file}: {e.strerror}") from None
    # In the window the file dialog was enough, the terminal says where it went
    if not ui.gui:
        ui.info(f"Backed up the saves of {prefix.name} to {file}.")


def cmd_restore(ui, name=None, file=None):
    """Put a backup from cmd_backup back into a prefix. Files in the backup replace the ones in the
    prefix; files that are not in the backup stay."""
    prefix = pick(ui, name)
    if prefix.running():
        raise Abort(f"{prefix.name} is running. Stop it first.")
    file = file or ui.ask_file(f"Restore the saves of {prefix.name}", HOME, ZIP_FILTER)
    try:
        z = zipfile.ZipFile(file)
    except (OSError, zipfile.BadZipFile):
        raise Abort(f"not a save backup: {file}") from None
    with z:
        names = z.namelist()
        # Only paths inside the user's folder
        if any(n.startswith("/") or ".." in Path(n).parts for n in names):
            raise Abort(f"not a save backup: {file}")
        if not ui.ask_yesno(f"Restore the saves of {prefix.name}? Files in the backup replace the ones in the "
                            "prefix, others stay."):
            raise Cancelled()
        dest = user_folder(prefix)
        dest.mkdir(parents=True, exist_ok=True)
        with ui.busy():
            z.extractall(dest)
    if not ui.gui:
        ui.info(f"Restored the saves of {prefix.name} from {file}.")


def other_user_folder(folder):
    """The Windows user's folder of a prefix made elsewhere (Heroic, Steam, Lutris, plain Wine).
    folder is the prefix (with drive_c) or the folder holding it as pfx/. Proton calls the user
    steamuser, Wine uses the login name."""
    folder = Path(folder)
    for prefix in (folder, folder / "pfx"):
        users = prefix / "drive_c/users"
        if not users.is_dir():
            continue
        found = [u for u in users.iterdir() if u.is_dir() and not u.is_symlink() and u.name != "Public"]
        for want in ("steamuser", os.environ.get("USER", "")):
            for u in found:
                if u.name == want:
                    return u
        if len(found) == 1:
            return found[0]
        if found:
            raise Abort(f"{users} has more than one user ({', '.join(sorted(u.name for u in found))}), so it is "
                        "not clear whose saves to take.")
    raise Abort(f"no Wine prefix in {folder}. Choose the folder with drive_c in it.")


def cmd_import_saves(ui, name=None, folder=None):
    """Copy the Windows user's folder of a prefix made elsewhere into this one. Files there replace
    the ones in the prefix; others stay. Links, such as a Documents that Wine links to the home
    folder, are left out: what they point to is on the disk already."""
    prefix = pick(ui, name)
    if prefix.running():
        raise Abort(f"{prefix.name} is running. Stop it first.")
    folder = folder or ui.ask_folder(f"Import saves into {prefix.name}: choose the other prefix's folder", HOME)
    src = other_user_folder(folder)
    dest = user_folder(prefix)
    if src.resolve() == dest.resolve():
        raise Abort("that is this prefix itself")
    if not ui.ask_yesno(f"Import the saves from {src} into {prefix.name}? Files there replace the ones in the "
                        "prefix, others stay."):
        raise Cancelled()
    skipped = []
    try:
        with ui.busy():
            for root, dirs, files in os.walk(src):
                rel = os.path.relpath(root, src)
                for d in list(dirs):
                    if os.path.islink(os.path.join(root, d)):
                        skipped.append(os.path.normpath(os.path.join(rel, d)))
                        dirs.remove(d)
                target = dest / rel
                target.mkdir(parents=True, exist_ok=True)
                for f in files:
                    path = os.path.join(root, f)
                    if os.path.islink(path) or not os.path.isfile(path):
                        continue
                    shutil.copy2(path, target / f)
    except OSError as e:
        raise Abort(f"could not copy {e.filename}: {e.strerror}") from None
    if skipped:
        ui.info(f"Imported the saves into {prefix.name}. Left out, as links to elsewhere: {', '.join(skipped)}.")
    elif not ui.gui:
        ui.info(f"Imported the saves from {src} into {prefix.name}.")


def cmd_log(ui, name=None):
    prefix = pick(ui, name)
    text = log_text(prefix)
    if not text:
        raise Abort(f"{prefix.name} has no log yet. Right-click its start menu entry, Run with log.")
    ui.show_log(prefix.name, text)


def cmd_list():
    running = running_names()
    for name in prefix_names():
        print(f"{name} (running)" if name in running else name)


def cmd_gui(ui):
    if not ui.gui:
        raise Abort("the window needs a graphical session")
    ui.manager()


USAGE = f"""Usage: {APP} <command>

  gui                       open a window with the prefixes
  add [file.exe]            add a program: an installer is run in a new prefix, a program that
                            is already installed is added as it is. It asks which.
  add --install [file]      treat the file as an installer
  add --installed [file]    treat the file as an installed program, without an installer
  install-in [file.exe]     run an installer in a prefix that exists, then choose which of the
                            new shortcuts go in the start menu
  add-to [file.exe]         add a program on the disk as another start menu entry of a prefix
  add-in <prefix> [file]    put another program in this prefix: run its installer or add it
  run [prefix] [args]       start the prefix's main program
  run <prefix> --log        the same with logs (umu and Proton), shown when it ends
  settings [prefix]         all settings of a prefix in one window
  shortcuts [prefix]        choose which of the prefix's shortcuts are in the start menu
  rename-shortcut <prefix> [exe]
                            give one start menu entry a new name: the main one, or exe's
  remove [prefix]           delete a prefix and its start menu entries
  rename [prefix] [new]     give a prefix folder a new name, the start menu names stay
  list                      list the prefixes, marking the ones that are running
  running                   list the prefixes that are running
  stop [prefix]             close everything that runs in a prefix
  log [prefix]              show the logs of the last run with --log
  backup [prefix] [file]    save the prefix's Windows user folder, with the saves, to a zip file
  restore [prefix] [file]   put a backup back into the prefix
  import-saves [prefix] [folder]
                            copy the saves of a prefix made elsewhere (Heroic, Steam, Wine) here

Without a prefix name, the commands that take one ask which.

Defaults for new prefixes: {SYSTEM_CONF} and {USER_CONF} (KEY=value lines, the latter winning).
A prefix has all its settings in its own config; changing the defaults leaves existing ones as they are.
"""


def main(argv):
    cmd, args = (argv[0], argv[1:]) if argv else ("", [])
    ui = QtUI() if gui_available() else TermUI()

    def arg(i):
        return args[i] if len(args) > i else None

    commands = {
        "gui": lambda: cmd_gui(ui),
        "add": lambda: (cmd_add(ui, args[0][2:], arg(1)) if arg(0) in ("--install", "--installed")
                        else cmd_add(ui, None, arg(0))),
        "install-in": lambda: cmd_install_in(ui, arg(0)),
        "add-to": lambda: cmd_add_to(ui, arg(0)),
        "add-in": lambda: cmd_add_in(ui, arg(0), arg(1)),
        "run": lambda: cmd_run(ui, arg(0), args[1:]),
        "settings": lambda: cmd_settings(ui, arg(0)),
        "shortcuts": lambda: cmd_shortcuts(ui, arg(0)),
        "remove": lambda: cmd_remove(ui, arg(0)),
        "rename": lambda: cmd_rename(ui, arg(0), arg(1)),
        "rename-shortcut": lambda: cmd_rename_shortcut(ui, arg(0), arg(1)),
        "list": cmd_list,
        "running": lambda: [print(n) for n in cmd_running()],
        "stop": lambda: cmd_stop(ui, arg(0)),
        "log": lambda: cmd_log(ui, arg(0)),
        "backup": lambda: cmd_backup(ui, arg(0), arg(1)),
        "restore": lambda: cmd_restore(ui, arg(0), arg(1)),
        "import-saves": lambda: cmd_import_saves(ui, arg(0), arg(1)),
    }
    if cmd not in commands:
        print(USAGE, end="")
        return 0 if cmd in ("", "help", "-h", "--help") else 1
    # Prefixes from before every setting was in their own config get the defaults written in, and the
    # launch script that reads only that
    for name in prefix_names():
        try:
            write_launch_script(Prefix(name))
        except (OSError, Abort):
            pass
    try:
        commands[cmd]()
    except Cancelled:
        return 1
    except Abort as e:
        ui.error(str(e))
        return 1
    return 0


if __name__ == "__main__":
    code = main(sys.argv[1:])
    if _qt is not None:
        # Python tearing down Qt's objects at exit can crash, after everything is done and saved.
        # Leave without it.
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(code)
    sys.exit(code)
