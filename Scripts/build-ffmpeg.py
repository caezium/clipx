#!/usr/bin/env python3
"""Build a universal, system-library-only FFmpeg and retain its matching sources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FFMPEG_VERSION = "9.0.2"
X264_REVISION = "b35605ace3ddf7c1a5d67a2eb553f034aef41d55"
SOURCES = {
    "ffmpeg.tar.xz": (
        f"https://ffmpeg.org/releases/ffmpeg-{FFMPEG_VERSION}.tar.xz",
        "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e",
    ),
    "x264.tar.bz2": (
        f"https://code.videolan.org/videolan/x264/-/archive/{X264_REVISION}/x264-{X264_REVISION}.tar.bz2",
        "6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224",
    ),
}


def sha256(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(stream.read()).hexdigest()


def run(command, *, cwd=None, env=None, log=None):
    if log:
        with log.open("a") as output:
            output.write("\n" + repr(command) + "\n")
            output.flush()
            subprocess.run(command, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, check=True)
    else:
        subprocess.run(command, cwd=cwd, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", action="append", choices=["arm64", "x86_64"])
    parser.add_argument("--work-dir", type=Path, default=ROOT / "build/ffmpeg")
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 4, 8))
    args = parser.parse_args()
    architectures = args.arch or ["arm64", "x86_64"]
    work = args.work_dir.resolve()
    for tool in ["clang", "make", "pkg-config", "nasm", "curl", "lipo", "xcrun"]:
        if not shutil.which(tool):
            parser.error(f"Missing build tool: {tool}")
    downloads, logs = work / "sources", work / "logs"
    downloads.mkdir(parents=True, exist_ok=True)
    logs.mkdir(exist_ok=True)
    for name, (url, checksum) in SOURCES.items():
        path = downloads / name
        if not path.exists():
            partial = path.with_suffix(".partial")
            run(["curl", "-fL", "--retry", "3", "--proto", "=https", "--proto-redir", "=https", "--max-time", "600", "-o", str(partial), url])
            if sha256(partial) != checksum:
                raise RuntimeError(f"Source checksum mismatch: {name}")
            partial.replace(path)
        if sha256(path) != checksum:
            raise RuntimeError(f"Cached source checksum mismatch: {path}")

    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    environment = os.environ.copy()
    # Do not accidentally link against Homebrew's codec libraries or flags.
    for key in ["CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LIBRARY_PATH", "CPATH", "PKG_CONFIG_PATH"]:
        environment.pop(key, None)
    environment["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
    manifests, binaries = [], []
    for architecture in architectures:
        directory = work / architecture
        directory.mkdir(exist_ok=True)
        prefix = directory / "prefix"
        source_dirs = {}
        for name in SOURCES:
            destination = directory / name.split(".")[0]
            if not destination.exists():
                with tempfile.TemporaryDirectory(dir=directory) as temporary:
                    # Both archives are pinned above, and contain a single source directory.
                    with tarfile.open(downloads / name) as archive:
                        if hasattr(tarfile, "data_filter"):
                            archive.extractall(temporary, filter="data")
                        else:
                            archive.extractall(temporary)
                    entries = list(Path(temporary).iterdir())
                    if len(entries) != 1 or not entries[0].is_dir():
                        raise RuntimeError(f"Unexpected archive layout: {name}")
                    entries[0].rename(destination)
            source_dirs[name] = destination
        flags = f"-arch {architecture} -isysroot {sdk} -mmacosx-version-min=14.0"
        environment["PKG_CONFIG_LIBDIR"] = str(prefix / "lib/pkgconfig")
        environment["CC"] = "clang"
        x264 = ["./configure", f"--prefix={prefix}", "--enable-static", "--enable-pic", "--disable-cli",
                f"--host={'aarch64' if architecture == 'arm64' else 'x86_64'}-apple-darwin",
                f"--extra-cflags={flags}", f"--extra-ldflags={flags}"]
        ffmpeg = ["./configure", f"--prefix={prefix}", "--target-os=darwin", f"--arch={architecture}",
                  "--enable-cross-compile", "--cc=clang", f"--sysroot={sdk}",
                  "--disable-autodetect", "--disable-shared", "--enable-static", "--disable-debug",
                  "--disable-doc", "--disable-ffplay", "--disable-ffprobe", "--enable-gpl", "--enable-libx264",
                  "--enable-videotoolbox", "--enable-audiotoolbox", "--enable-zlib", "--enable-bzlib", "--enable-iconv",
                  f"--extra-cflags={flags} -I{prefix / 'include'}", f"--extra-objcflags={flags}",
                  f"--extra-ldflags={flags} -L{prefix / 'lib'}", "--extra-libs=-liconv", "--pkg-config-flags=--static"]
        log = logs / f"{architecture}.log"
        for name, configure in [("x264.tar.bz2", x264), ("ffmpeg.tar.xz", ffmpeg)]:
            print(f"Building {name.split('.')[0]} for {architecture}; log: {log}", flush=True)
            run(configure, cwd=source_dirs[name], env=environment, log=log)
            run(["make", f"-j{args.jobs}"], cwd=source_dirs[name], env=environment, log=log)
            run(["make", "install"], cwd=source_dirs[name], env=environment, log=log)
        binaries.append(prefix / "bin/ffmpeg")
        manifests.append({"architecture": architecture, "x264_configure": x264, "ffmpeg_configure": ffmpeg})

    helper = work / "ffmpeg"
    run(["lipo", "-create", *map(str, binaries), "-output", str(helper)])
    helper.chmod(0o755)
    run(["bash", str(ROOT / "Scripts/validate-ffmpeg.sh"), str(helper)], env={**environment, "ARCHS": " ".join(architectures)})
    source_archive = work / f"FFmpeg-{FFMPEG_VERSION}-x264-{X264_REVISION[:7]}-sources.tar.gz"
    manifest = {"ffmpeg_version": FFMPEG_VERSION, "x264_revision": X264_REVISION,
                "architectures": architectures, "minimum_macos": "14.0", "sha256": sha256(helper),
                "sources": {name: {"url": url, "sha256": checksum} for name, (url, checksum) in SOURCES.items()},
                "builds": manifests, "source_archive": source_archive.name,
                "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0]}
    (work / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with tarfile.open(source_archive, "w:gz") as archive:
        for path in downloads.iterdir():
            if path.name in SOURCES:
                archive.add(path, arcname=f"sources/{path.name}")
        for name in ["build-ffmpeg.py", "validate-ffmpeg.sh"]:
            archive.add(ROOT / "Scripts" / name, arcname=f"Scripts/{name}")
        archive.add(work / "build-manifest.json", arcname="build-manifest.json")
        instructions = work / "BUILD.txt"
        instructions.write_text("Requires macOS, Xcode, Python 3, make, pkg-config and nasm.\nRun: python3 Scripts/build-ffmpeg.py --work-dir .\nThe sources directory contains the exact unmodified upstream archives.\nNo GPL-incompatible or nonfree codecs are enabled. FFmpeg and libx264 are GPL-2.0-or-later.\n")
        archive.add(instructions, arcname="BUILD.txt")
    manifest["source_archive_sha256"] = sha256(source_archive)
    support = ROOT / "Helpers/ffmpeg-support"
    support.mkdir(parents=True, exist_ok=True)
    first = work / architectures[0]
    shutil.copy2(first / "ffmpeg/COPYING.GPLv2", support / "COPYING.FFmpeg")
    shutil.copy2(first / "x264/COPYING", support / "COPYING.x264")
    (support / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (support / "NOTICE.txt").write_text(
        f"FFmpeg {FFMPEG_VERSION} (https://ffmpeg.org), with libx264 {X264_REVISION} (https://www.videolan.org/developers/x264.html).\n"
        "These unmodified components are distributed under GPL-2.0-or-later, without warranty; see the included licenses.\n"
        f"Corresponding sources and build scripts: {source_archive.name}, supplied alongside the Clipx download.\n"
        "Source downloads: https://github.com/caezium/clipx-releases/releases\n")
    # Replacing a development symlink must not overwrite its Homebrew target.
    installed = ROOT / "Helpers/ffmpeg.new"
    shutil.copy2(helper, installed)
    installed.replace(ROOT / "Helpers/ffmpeg")
    print(json.dumps({"helper": str(ROOT / "Helpers/ffmpeg"), "sha256": manifest["sha256"], "sources": str(source_archive)}, indent=2))


if __name__ == "__main__":
    main()
