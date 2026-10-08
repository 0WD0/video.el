#!/usr/bin/env python3
"""Build or inspect a content-addressed SDK from the monorepo renderer sources."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import tomllib

REPOSITORY = Path(__file__).resolve().parents[2]
CRATE = REPOSITORY / "third_party/dotlottie-rs/dotlottie-rs"
THORVG = REPOSITORY / "third_party/thorvg"
MANIFEST = ".dotlottie-sdk.json"
FEATURES = (
    "c_api", "tvg-cpu", "tvg-lottie-expressions", "tvg-threads",
    "tvg-png", "tvg-jpg", "tvg-webp", "tvg-ttf", "tvg-otf",
)
MEMBERS = ("include/dotlottie_player.h", "lib/libdotlottie_rs.so")


def host():
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise ValueError("the native dotLottie SDK currently requires Linux x86_64")
    return "linux-x86_64"


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def source_identity():
    if (CRATE / "deps/thorvg").resolve() != THORVG.resolve():
        raise ValueError("dotlottie-rs must use the monorepo third_party/thorvg sources")
    files = [CRATE / name for name in (
        "Cargo.toml", "Cargo.lock", "build.rs", "cbindgen.toml",
    )]
    files.append(Path(__file__).resolve())
    directories = [CRATE / "src", CRATE / ".cargo", THORVG / "src", THORVG / "inc"]
    for directory in directories:
        if not directory.is_dir():
            raise ValueError(f"renderer source directory missing: {directory}")
        files.extend(path for path in directory.rglob("*") if path.is_file())
    checksums = {str(path.relative_to(REPOSITORY)): digest(path) for path in sorted(files)}
    source_hash = hashlib.sha256(json.dumps(checksums, sort_keys=True).encode()).hexdigest()
    package = tomllib.loads((CRATE / "Cargo.toml").read_text())["package"]
    identity = {
        "kind": "monorepo-source",
        "version": package["version"],
        "architecture": host(),
        "features": list(FEATURES),
        "source_sha256": source_hash,
    }
    return identity, files, directories


def default_root(cache_home=None):
    cache = Path(cache_home or os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    identity, _, _ = source_identity()
    return cache / "video.el/dotlottie/source" / identity["architecture"] / identity["source_sha256"]


def inspect(root):
    identity, sources, directories = source_identity()
    with (root / MANIFEST).open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if any(manifest.get(key) != value for key, value in identity.items()):
        raise ValueError(f"{root}: SDK does not match the current monorepo renderer sources")
    hashes = manifest.get("files", {})
    for name in MEMBERS:
        file = root / name
        if not file.is_file() or file.is_symlink() or digest(file) != hashes.get(name):
            raise ValueError(f"{file}: missing or changed SDK artifact")
    return {
        **identity,
        "root": str(root),
        "header_sha256": hashes[MEMBERS[0]],
        "library_sha256": hashes[MEMBERS[1]],
        "manifest_sha256": digest(root / MANIFEST),
        "source_files": [str(path) for path in sources],
        "source_directories": [str(path) for path in directories],
    }


def build(root):
    if root.is_relative_to(REPOSITORY):
        raise ValueError("SDK outputs must be outside the source workspace")
    if root.exists():
        inspect(root)
        return
    identity, _, _ = source_identity()
    root.parent.mkdir(parents=True, exist_ok=True)
    target = root.parent / "cargo-target"
    environment = dict(os.environ)
    # Keep both Rust and cc-built ThorVG symbols for real crash diagnosis.
    environment["CARGO_PROFILE_RELEASE_DEBUG"] = "2"
    environment["CARGO_PROFILE_RELEASE_STRIP"] = "none"
    subprocess.run([
        "cargo", "rustc", "--locked", "--release", "--lib",
        "--manifest-path", str(CRATE / "Cargo.toml"),
        "--target-dir", str(target), "--features", ",".join(FEATURES),
        "--crate-type", "cdylib",
    ], check=True, env=environment, cwd=CRATE)
    if source_identity()[0] != identity:
        raise ValueError("renderer sources changed during the build; no SDK was published")
    with tempfile.TemporaryDirectory(prefix=".dotlottie-build-", dir=root.parent) as work:
        prefix = Path(work) / "sdk"
        artifacts = {
            MEMBERS[0]: CRATE / "build/dotlottie_player.h",
            MEMBERS[1]: target / "release/libdotlottie_rs.so",
        }
        for name, source in artifacts.items():
            destination = prefix / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        manifest = {
            **identity,
            "rustc": subprocess.check_output(["rustc", "-vV"], text=True).strip(),
            "files": {name: digest(prefix / name) for name in MEMBERS},
        }
        (prefix / MANIFEST).write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        inspect(prefix)
        try:
            prefix.rename(root)
        except FileExistsError:
            inspect(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("root", "build", "check", "metadata"))
    parser.add_argument("--root", help="SDK prefix (default: source-keyed XDG cache or DOTLOTTIE_ROOT)")
    args = parser.parse_args()
    root = None
    try:
        root = Path(args.root or os.environ.get("DOTLOTTIE_ROOT") or default_root()).expanduser().resolve()
        if args.command == "root":
            print(root)
            return 0
        if args.command == "build":
            build(root)
        metadata = inspect(root)
        if args.command == "metadata":
            print(json.dumps(metadata, sort_keys=True))
        elif args.command == "build":
            print(f"dotLottie {metadata['version']} source SDK ready: {root}")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"dotLottie SDK: {error}\nRun from appkit-apps/video.el: make dotlottie-sdk"
              + (f" DOTLOTTIE_ROOT={str(root)!r}" if root else "")
              + "\nExisting SDKs are immutable; choose a new prefix if an explicit prefix is stale.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
