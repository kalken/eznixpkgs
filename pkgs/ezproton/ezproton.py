#!/usr/bin/env python3
"""ezproton - Downloads and installs the latest Proton-GE and/or CachyOS Proton
builds into Steam's compatibilitytools.d.
Always appears in Steam as GE-Proton-Latest / Proton-CachyOS-Latest.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import sys
import tarfile
import urllib.request
import urllib.error

USER_AGENT = "ezproton"


def ge_arch_match(name, is_arm):
    return ("aarch64" in name) if is_arm else ("aarch64" not in name)


def cachyos_arch_match(name, is_arm):
    return ("arm64" in name) if is_arm else ("x86_64" in name and "x86_64_v3" not in name)


VARIANTS = {
    "ge": {
        "api_url": "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest",
        "display_name": "GE-Proton-Latest",
        "cache_dir": "/tmp/ezproton/ge",
        "arch_match": ge_arch_match,
    },
    "cachyos": {
        "api_url": "https://api.github.com/repos/CachyOS/proton-cachyos/releases/latest",
        "display_name": "Proton-CachyOS-Latest",
        "cache_dir": "/tmp/ezproton/cachyos",
        "arch_match": cachyos_arch_match,
    },
}


# -- Logging ------------------------------------------------------------------

def info(msg):
    print(f"\033[32m[INFO]\033[0m  {msg}")


def warn(msg):
    print(f"\033[33m[WARN]\033[0m  {msg}")


def error(msg):
    print(f"\033[31m[ERROR]\033[0m {msg}", file=sys.stderr)
    sys.exit(1)


# -- GitHub release -----------------------------------------------------------

def fetch_latest_release(api_url, version=None):
    info("Fetching latest release info from GitHub...")
    req = urllib.request.Request(api_url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code == 404 and version:
            error(f"Release '{version}' not found. Use --list to see available versions.")
        error(f"Failed to reach GitHub API: {e}")
    except urllib.error.URLError as e:
        error(f"Failed to reach GitHub API: {e}")


# -- Version check ------------------------------------------------------------

VERSION_FILE = ".ezproton-version"


def is_up_to_date(install_dir, display_name, tag):
    # The tool's internal key is rewritten to display_name (see patch_vdf), so
    # the release tag is tracked in a marker file instead.
    try:
        with open(os.path.join(install_dir, display_name, VERSION_FILE)) as f:
            return f.read().strip() == tag
    except FileNotFoundError:
        return False


# -- Download with progress ---------------------------------------------------

def download(url, dest, silent=False):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req) as resp:
            total = int(resp.headers.get("Content-Length", 0))
            data = bytearray()
            chunk_size = 65536
            downloaded = 0
            while True:
                chunk = resp.read(chunk_size)
                if not chunk:
                    break
                data.extend(chunk)
                downloaded += len(chunk)
                if not silent and total:
                    pct = downloaded / total * 100
                    done = int(50 * downloaded / total)
                    bar = "#" * done + "-" * (50 - done)
                    print(f"\r  [{bar}] {pct:5.1f}%", end="", flush=True)
            if not silent and total:
                print()
    except urllib.error.URLError as e:
        error(f"Failed to download {url}: {e}")

    with open(dest, "wb") as f:
        f.write(data)
    return bytes(data)


# -- Checksum -----------------------------------------------------------------

def verify_checksum(data, sha_content):
    info("Verifying checksum...")
    match = re.search(r"[0-9a-fA-F]{128}", sha_content)
    if not match:
        error("Could not parse a SHA-512 hash from checksum file.")
    expected = match.group(0).lower()
    actual = hashlib.sha512(data).hexdigest()
    if expected != actual:
        error(
            f"Checksum mismatch! Download may be corrupted.\n"
            f"  Expected: {expected}\n"
            f"  Actual:   {actual}"
        )
    info("Checksum OK.")


# -- Extract with directory rename --------------------------------------------

def extract(tar_path, install_dir, display_name):
    info("Extracting...")
    with tarfile.open(tar_path, "r:*") as tf:
        for member in tf.getmembers():
            parts = member.name.split("/", 1)
            member.name = display_name + ("/" + parts[1] if len(parts) > 1 else "")
            tf.extract(member, install_dir, filter="tar")


# -- Patch compatibilitytool.vdf ----------------------------------------------

def patch_vdf(install_dir, display_name):
    vdf_path = os.path.join(install_dir, display_name, "compatibilitytool.vdf")
    if not os.path.exists(vdf_path):
        error(f"compatibilitytool.vdf not found at {vdf_path} — cannot patch display name.")

    with open(vdf_path) as f:
        contents = f.read()

    # Steam stores a game's selected tool by its internal key, which upstream
    # changes every release. Pin it so selections survive upgrades.
    patched, n = re.subn(
        r'("compat_tools"\s*\{\s*)"[^"]*"',
        lambda m: f'{m.group(1)}"{display_name}"',
        contents,
        count=1,
    )
    if n != 1:
        error(f"Could not find the internal tool key in {vdf_path}.")

    patched = re.sub(
        r'"display_name"\s*"[^"]*"',
        f'"display_name"\t\t"{display_name}"',
        patched
    )

    with open(vdf_path, "w") as f:
        f.write(patched)


# -- Install a single variant ---------------------------------------------------

def install_variant(variant, install_dir, version=None):
    cfg = VARIANTS[variant]
    # A pinned version installs under its own tag with upstream's tool key
    # untouched, next to (not over) the *-Latest install.
    display_name = version or cfg["display_name"]

    info(f"=== {display_name} ===")

    api_url = cfg["api_url"]
    if version:
        api_url = api_url.replace("/releases/latest", f"/releases/tags/{version}")
    release = fetch_latest_release(api_url, version)
    tag = release.get("tag_name") or error("Could not determine release tag.")
    info(f"{'Requested' if version else 'Latest'} release: {tag}")

    if is_up_to_date(install_dir, display_name, tag):
        info(f"{display_name} is already up to date ({tag}). Nothing to do.")
        return

    assets = release.get("assets", [])
    machine = platform.machine().lower()
    is_arm = machine in ("aarch64", "arm64")

    def arch_match(name):
        return cfg["arch_match"](name, is_arm)

    def is_tarball(name):
        return name.endswith(".tar.gz") or name.endswith(".tar.xz")

    tar_asset = next(
        (a for a in assets if is_tarball(a["name"]) and arch_match(a["name"])),
        None
    )
    sha_asset = next(
        (a for a in assets if a["name"].endswith(".sha512sum") and arch_match(a["name"])),
        None
    )

    if not tar_asset:
        error(f"Could not find a tarball asset in the {display_name} release.")
    if not sha_asset:
        error(f"Could not find a .sha512sum asset in the {display_name} release.")

    cache_dir = cfg["cache_dir"]
    os.makedirs(cache_dir, exist_ok=True)
    tar_path = os.path.join(cache_dir, tar_asset["name"])
    tar_part = tar_path + ".part"
    sha_path = os.path.join(cache_dir, sha_asset["name"])

    # Use cached tarball if it exists and is complete (same version = same filename)
    if os.path.exists(tar_path):
        info(f"Using cached tarball: {tar_path}")
        with open(tar_path, "rb") as f:
            tar_data = f.read()
    else:
        # Remove any stale tarballs or partial downloads from previous versions
        for old_file in os.listdir(cache_dir):
            os.remove(os.path.join(cache_dir, old_file))
            info(f"Removed stale cache: {old_file}")

        info(f"Downloading {tag}...")
        tar_data = download(tar_asset["browser_download_url"], tar_part)
        os.rename(tar_part, tar_path)

    info("Downloading checksum file...")
    download(sha_asset["browser_download_url"], sha_path, silent=True)
    with open(sha_path) as f:
        sha_content = f.read()

    verify_checksum(tar_data, sha_content)

    os.makedirs(install_dir, exist_ok=True)

    dest = os.path.join(install_dir, display_name)
    if os.path.isdir(dest):
        info(f"Removing old {display_name} install...")
        shutil.rmtree(dest)

    extract(tar_path, install_dir, display_name)

    if not version:
        info("Patching compatibilitytool.vdf...")
        patch_vdf(install_dir, display_name)

    with open(os.path.join(dest, VERSION_FILE), "w") as f:
        f.write(tag)

    info(f"Done! Installed as '{display_name} ({tag})' -> {dest}")


# -- List available releases --------------------------------------------------

def list_versions(variant):
    cfg = VARIANTS[variant]
    releases = fetch_latest_release(
        cfg["api_url"].replace("/releases/latest", "/releases?per_page=30")
    )
    print(f"{variant}:")
    for release in releases:
        print(f"  {release['tag_name']}")


# -- Main ---------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Downloads and installs the latest Proton-GE and/or CachyOS Proton "
                     "builds into Steam's compatibilitytools.d."
    )
    parser.add_argument(
        "--variant",
        choices=sorted(VARIANTS),
        action="append",
        help="Which Proton variant to install. May be given multiple times. "
             "Defaults to all variants (ge, cachyos)."
    )
    parser.add_argument(
        "--version",
        help="Install a specific release tag (e.g. GE-Proton10-5) instead of the latest. "
             "Requires exactly one --variant."
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List the most recent available release tags (newest first) and exit."
    )
    parser.add_argument(
        "--latest",
        action="store_true",
        help="Install the latest release of each selected variant."
    )
    args = parser.parse_args()
    if not (args.latest or args.version or args.list):
        parser.print_help()
        return
    variants = args.variant or list(VARIANTS)
    if args.version and len(variants) != 1:
        parser.error("--version requires exactly one --variant.")
    if sum([args.latest, bool(args.version), args.list]) > 1:
        parser.error("--latest, --version and --list are mutually exclusive.")

    if args.list:
        for variant in variants:
            list_versions(variant)
        return

    home = os.environ.get("HOME") or error("HOME environment variable not set.")
    steam_dir = os.path.join(home, ".steam")
    if not os.path.isdir(steam_dir):
        error(f"Steam directory not found at {steam_dir} — is Steam installed for this user?")
    install_dir = os.path.join(steam_dir, "root", "compatibilitytools.d")

    for variant in variants:
        install_variant(variant, install_dir, args.version)

    info("Restart Steam and select the desired build in a game's compatibility settings.")


if __name__ == "__main__":
    main()
