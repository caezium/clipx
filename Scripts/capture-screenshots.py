#!/usr/bin/env python3
"""Capture the production workspace and library with isolated, licensed demo footage.

Requires an isolated Direct Debug build, its package cache, and existing Screen
Recording permission. Never changes permissions, unlocks the Mac, or opens the
user's library. --download fetches checksum-pinned public footage into --media-dir.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shlex
import subprocess
import tempfile


def digest(path):
    with path.open("rb") as handle:
        result = hashlib.sha256()
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
        return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--packages-dir", type=Path, required=True)
    parser.add_argument("--media-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--review", action="store_true",
                        help="Also capture Notes, Export, and narrow workspace layouts")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    products = args.derived_data.resolve() / "Build/Products/Debug"
    with (products / "Clipx.app/Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != "com.clipx.Clipx.Verification":
        parser.error("Build the isolated Direct Debug app first; see docs/screenshots/README.md")
    shots = json.loads((root / "Scripts/Screenshots/footage.json").read_text())
    args.media_dir.mkdir(parents=True, exist_ok=True)
    for shot in shots:
        path = args.media_dir.resolve() / shot["file"]
        if not path.exists() and args.download:
            partial = path.with_suffix(".mp4.part")
            subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                            "--connect-timeout", "15", "--max-time", "600",
                            "--retry", "2", "--continue-at", "-",
                            "--user-agent", "Mozilla/5.0", "--referer", shot["sourceURL"],
                            shot["downloadURL"], "--output", str(partial)], check=True)
            if digest(partial) != shot["sha256"]:
                parser.error(f"Downloaded footage checksum mismatch: {partial}")
            partial.rename(path)
        if not path.is_file() or digest(path) != shot["sha256"]:
            parser.error(f"Missing or incomplete footage: {path}. Use --download for missing files.")
        shot["file"] = str(path)

    architecture = platform.machine()
    file_list = (args.derived_data.resolve() / "Build/Intermediates.noindex/Clipx.build/Debug" /
                 f"Clipx-Direct.build/Objects-normal/{architecture}/Clipx.LinkFileList")
    # Reuse every compiled production object except its @main entry point.
    objects = [p for p in shlex.split(file_list.read_text())
               if Path(p).suffix == ".o" and Path(p).name != "ClipxApp.o"]
    sqlite_module = args.packages_dir.resolve() / "checkouts/GRDB.swift/Sources/CSQLite"
    with tempfile.TemporaryDirectory(prefix="clipx-screenshot-runner-") as temporary:
        temporary = Path(temporary)
        executable = temporary / "clipx-screenshots"
        manifest = temporary / "footage.json"
        manifest.write_text(json.dumps(shots))
        command = ["xcrun", "swiftc", str(root / "Scripts/Screenshots/main.swift"),
                   "-o", str(executable), "-target", f"{architecture}-apple-macos14.0",
                   "-I", str(products), "-F", str(products), "-I", str(sqlite_module),
                   "-Xlinker", "-rpath", "-Xlinker", str(products)] + objects
        subprocess.run(command, check=True)
        environment = os.environ.copy()
        environment.pop("CLIPX_DATA_DIRECTORY", None)
        environment["CLIPX_ISOLATED_TESTS"] = "1"
        capture = [str(executable), str(manifest), str(args.output.resolve())]
        if args.review:
            capture.append("--review")
        subprocess.run(capture,
                       env=environment, check=True, timeout=120)


if __name__ == "__main__":
    main()
