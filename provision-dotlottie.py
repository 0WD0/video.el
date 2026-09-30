#!/usr/bin/env python3
"""Explicitly provision or inspect the pinned public dotLottie Linux SDK."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import tarfile
import tempfile
import urllib.request

VERSION = "0.1.58"
ARCHIVE_SHA256 = "ca35da27e1a1d196a45ac8c59e0e4e3dbf6ce4633503539e0e038b2ea1451f64"
URL = f"https://github.com/LottieFiles/dotlottie-rs/releases/download/v{VERSION}/dotlottie-player.linux.tar.gz"
MANIFEST = ".dotlottie-sdk.json"
MEMBERS = {
    "include/dotlottie_player.h": "x86_64/dotlottie-player/include/dotlottie_player.h",
    "lib/libdotlottie_rs.so": "x86_64/dotlottie-player/lib/libdotlottie_rs.so",
}


def host():
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise ValueError("dotLottie SDK requires Linux x86_64; this host is unsupported")
    return "linux-x86_64"


def default_root():
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    return cache / "video.el" / "dotlottie" / f"v{VERSION}" / host()


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def inspect(root):
    manifest_path = root / MANIFEST
    with manifest_path.open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if (not isinstance(manifest, dict) or manifest.get("version") != VERSION
            or manifest.get("archive_sha256") != ARCHIVE_SHA256
            or manifest.get("architecture") != host()
            or manifest.get("url") != URL):
        raise ValueError(f"{manifest_path}: expected official dotLottie v{VERSION} SDK metadata")
    hashes = manifest.get("files", {})
    if not isinstance(hashes, dict):
        raise ValueError(f"{manifest_path}: expected SDK file checksums")
    for name in MEMBERS:
        file = root / name
        if not file.is_file() or file.is_symlink() or digest(file) != hashes.get(name):
            raise ValueError(f"{file}: missing or changed SDK file; provision the matching header/library pair again")
    return {
        "root": str(root),
        "version": VERSION,
        "archive_sha256": ARCHIVE_SHA256,
        "architecture": host(),
        "header_sha256": hashes["include/dotlottie_player.h"],
        "library_sha256": hashes["lib/libdotlottie_rs.so"],
        "manifest_sha256": digest(manifest_path),
    }


def provision(root):
    # An existing prefix is either a verified pair or an actionable failure:
    # never overwrite a user's unrelated files or a concurrently installed SDK.
    if root.exists():
        inspect(root)
        return
    root.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".dotlottie-download-", dir=root.parent) as work:
        work = Path(work)
        archive = work / "release.tar.gz"
        request = urllib.request.Request(URL, headers={"User-Agent": "video.el-dotlottie-provisioner"})
        with urllib.request.urlopen(request, timeout=120) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
        if digest(archive) != ARCHIVE_SHA256:
            raise ValueError("dotLottie release checksum mismatch; no SDK was installed")
        prefix = work / "sdk"
        with tarfile.open(archive, mode="r:gz") as release:
            for destination, member_name in MEMBERS.items():
                member = release.getmember(member_name)
                if not member.isfile():
                    raise ValueError(f"{member_name}: expected a regular SDK file")
                # Never extract arbitrary archive paths, links, or metadata.
                target = prefix / destination
                target.parent.mkdir(parents=True, exist_ok=True)
                with release.extractfile(member) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o644)
        manifest = {
            "version": VERSION,
            "archive_sha256": ARCHIVE_SHA256,
            "architecture": host(),
            "url": URL,
            "files": {name: digest(prefix / name) for name in MEMBERS},
        }
        (prefix / MANIFEST).write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        inspect(prefix)
        try:
            prefix.rename(root)
        except FileExistsError:
            inspect(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("provision", "check", "metadata"))
    parser.add_argument("--root", help="SDK prefix (default: DOTLOTTIE_ROOT or the versioned XDG cache)")
    args = parser.parse_args()
    root = None
    try:
        host()
        root = Path(args.root or os.environ.get("DOTLOTTIE_ROOT") or default_root()).expanduser().resolve()
        if args.command == "provision":
            repository = Path(__file__).resolve().parents[2]
            if root.is_relative_to(repository):
                raise ValueError("SDK prefix must be outside the source workspace; set DOTLOTTIE_ROOT to an external prefix")
            provision(root)
        metadata = inspect(root)
        if args.command == "metadata":
            print(json.dumps(metadata, sort_keys=True))
        elif args.command == "provision":
            print(f"dotLottie v{VERSION} SDK ready: {root}")
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        print(f"dotLottie SDK: {error}\nRun from appkit-apps/video.el: make provision-dotlottie"
              + (f" DOTLOTTIE_ROOT={str(root)!r}" if root else "")
              + "\nIf the prefix already exists but is invalid, choose a new empty external prefix;"
                " provisioning never overwrites existing files.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
