#!/usr/bin/env python3
"""ezprotonge - Downloads and installs the latest Proton-GE release to Steam's compatibilitytools.d.
Always appears in Steam as GE-Proton-Latest.
"""

import hashlib
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request
import urllib.error

GITHUB_API = "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
DISPLAY_NAME = "GE-Proton-Latest"

# -- Logging ------------------------------------------------------------------


def info(msg): print(f"\033[32m[INFO]\033[0m  {msg}")
def warn(msg): print(f"\033[33m[WARN]\033[0m  {msg}")


def error(msg):
    print(f"\033[31m[ERROR]\033[0m {msg}", file=sys.stderr)
    sys.exit(1)

# -- GitHub release -----------------------------------------------------------


def fetch_latest_release():
    info("Fetching latest Proton-GE release info from GitHub...")
    req = urllib.request.Request(
        GITHUB_API, headers={
            "User-Agent": "ezprotonge"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.URLError as e:
        error(f"Failed to reach GitHub API: {e}")

# -- Version check ------------------------------------------------------------


def is_up_to_date(install_dir, tag):
    vdf = os.path.join(install_dir, DISPLAY_NAME, "compatibilitytool.vdf")
    try:
        with open(vdf) as f:
            return f'"{tag}"' in f.read()
    except FileNotFoundError:
        return False

# -- Download with progress ---------------------------------------------------


def download(url, dest, silent=False):
    req = urllib.request.Request(url, headers={"User-Agent": "ezprotonge"})
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
            f"Checksum mismatch! Download may be corrupted.\n  Expected: {expected}\n  Actual:   {actual}")
    info("Checksum OK.")

# -- Extract with directory rename --------------------------------------------


def extract(tar_path, install_dir):
    info("Extracting...")
    with tarfile.open(tar_path, "r:gz") as tf:
        for member in tf.getmembers():
            # Rewrite top-level directory to DISPLAY_NAME
            parts = member.name.split("/", 1)
            member.name = DISPLAY_NAME + \
                ("/" + parts[1] if len(parts) > 1 else "")
            tf.extract(member, install_dir, filter="tar")

# -- Patch compatibilitytool.vdf ----------------------------------------------


def patch_vdf(install_dir):
    vdf_path = os.path.join(install_dir, DISPLAY_NAME, "compatibilitytool.vdf")
    if not os.path.exists(vdf_path):
        error(
            f"compatibilitytool.vdf not found at {vdf_path} — cannot patch display name.")

    with open(vdf_path) as f:
        contents = f.read()

    patched = re.sub(
        r'"display_name"\s*"[^"]*"',
        f'"display_name"\t\t"{DISPLAY_NAME}"',
        contents
    )

    with open(vdf_path, "w") as f:
        f.write(patched)

# -- Main ---------------------------------------------------------------------


def main():
    home = os.environ.get("HOME") or error(
        "HOME environment variable not set.")
    install_dir = os.path.join(home, ".steam", "root", "compatibilitytools.d")

    release = fetch_latest_release()
    tag = release.get("tag_name") or error(
        "Could not determine latest release tag.")
    info(f"Latest release: {tag}")

    if is_up_to_date(install_dir, tag):
        info(f"{DISPLAY_NAME} is already up to date ({tag}). Nothing to do.")
        return

    assets = release.get("assets", [])
    tar_asset = next((a for a in assets if a["name"].endswith(
        ".tar.gz") and not a["name"].endswith(".sha512sum")), None)
    sha_asset = next(
        (a for a in assets if a["name"].endswith(".sha512sum")),
        None)

    if not tar_asset:
        error("Could not find .tar.gz asset in release.")
    if not sha_asset:
        error("Could not find .sha512sum asset in release.")

    with tempfile.TemporaryDirectory() as tmp:
        tar_path = os.path.join(tmp, tar_asset["name"])
        sha_path = os.path.join(tmp, sha_asset["name"])

        info(f"Downloading {tag}...")
        tar_data = download(tar_asset["browser_download_url"], tar_path)

        info("Downloading checksum file...")
        download(sha_asset["browser_download_url"], sha_path, silent=True)
        with open(sha_path) as f:
            sha_content = f.read()

        verify_checksum(tar_data, sha_content)

        os.makedirs(install_dir, exist_ok=True)

        dest = os.path.join(install_dir, DISPLAY_NAME)
        if os.path.isdir(dest):
            info(f"Removing old {DISPLAY_NAME} install...")
            shutil.rmtree(dest)

        extract(tar_path, install_dir)

    info("Patching compatibilitytool.vdf...")
    patch_vdf(install_dir)

    info(f"Done! Installed as '{DISPLAY_NAME} ({tag})' -> {dest}")
    info(
        f"Restart Steam and select '{DISPLAY_NAME}' in a game's compatibility settings.")


if __name__ == "__main__":
    main()
