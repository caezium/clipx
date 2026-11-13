#!/usr/bin/env python3
"""Verify the portable helper with production export arguments and a real signed feed."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

import release

ROOT = release.ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / "build/release/evidence")
    parser.add_argument("--sparkle-bin", default=os.environ.get("SPARKLE_BIN"))
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    evidence = args.directory.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    checks = []
    report = {"checks": checks, "native_ui": "not run; no GUI session required by these checks"}
    helper = ROOT / "Helpers/ffmpeg"
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        parser.error("ffprobe is required to independently inspect the encoded media")
    # Only the inspector comes from the development toolchain. The encoder gets no Homebrew paths.
    clean_env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ["HOME"], "TMPDIR": str(evidence)}

    def command(arguments, name, *, env=None, timeout=120):
        with (evidence / f"{name}.log").open("w") as log:
            subprocess.run(list(map(str, arguments)), stdout=log, stderr=subprocess.STDOUT,
                           env=env, timeout=timeout, check=True)

    try:
        manifest = release.check_helper()
        sources = ROOT / "build/ffmpeg" / manifest["source_archive"]
        assert release.digest(sources) == manifest["source_archive_sha256"], "Corresponding sources hash mismatch"
        checks.append({"name": "universal helper, system libraries, matching sources and licenses", "status": "PASS"})
        (evidence / "ffmpeg-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        command(["otool", "-L", helper], "ffmpeg-dependencies")
        command(["xcrun", "vtool", "-show-build", helper], "ffmpeg-minimum-os")
        minimums = re.findall(r"minos\s+(\S+)", (evidence / "ffmpeg-minimum-os.log").read_text())
        assert minimums == ["14.0", "14.0"], minimums
        generator = evidence / "export-arguments"
        files = [ROOT / "Sources/ClipxExport" / f"{name}.swift" for name in
                 ["FFmpegBackend", "ExportPreset", "ChipDetector", "VideoRotation", "FramingPolicy", "FFmpegProgress"]]
        command(["xcrun", "swiftc", "-D", "DIRECT_BUILD", *files, ROOT / "Tests/Release/ExportArguments.swift", "-o", generator], "compile-export-arguments")
        fixture = evidence / "source.mp4"
        command([helper, "-nostdin", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=4",
                 "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=4", "-c:v", "libx264",
                 "-c:a", "aac", "-pix_fmt", "yuv420p", fixture], "fixture", env=clean_env)
        presets = [("reels", 1080, 1920, 30), ("tiktok", 1080, 1920, 60),
                   ("youtube-shorts", 1080, 1920, 30), ("instagram-feed", 1080, 1350, 30),
                   ("youtube-1080p", 1920, 1080, 30), ("youtube-4k", 3840, 2160, 30)]
        cases = [("arm64", "libx264", *preset) for preset in presets]
        cases += [("arm64", "h264_videotoolbox", *presets[4]),
                  ("x86_64", "libx264", *presets[4]), ("x86_64", "h264_videotoolbox", *presets[4])]
        supported = {}
        for architecture in {case[0] for case in cases}:
            probe = subprocess.run(["/usr/bin/arch", f"-{architecture}", "/usr/bin/true"], capture_output=True, text=True)
            supported[architecture] = probe.returncode == 0
            if probe.returncode and "Bad CPU type" not in probe.stderr:
                raise RuntimeError(probe.stderr)
        for arch, codec, preset, width, height, rate in cases:
            name = f"{arch}-{codec}-{preset}"
            if not supported[arch]:
                checks.append({"name": name, "status": "SKIP", "reason": "Host cannot execute this architecture; Rosetta was not installed by this check"})
                continue
            destination = evidence / f"{name}.mp4"
            arguments = json.loads(subprocess.check_output([str(generator), str(fixture), str(destination), preset], text=True))
            # Test both runtime encoder choices on this machine; all filters/trim arguments are production code.
            arguments[arguments.index("-c:v") + 1] = codec
            (evidence / f"{name}-arguments.json").write_text(json.dumps(arguments, indent=2) + "\n")
            command(["/usr/bin/arch", f"-{arch}", helper, *arguments], name, env=clean_env)
            inspected = json.loads(subprocess.check_output([ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(destination)], text=True))
            video = next(stream for stream in inspected["streams"] if stream["codec_type"] == "video")
            audio = next(stream for stream in inspected["streams"] if stream["codec_type"] == "audio")
            assert (video["width"], video["height"]) == (width, height), name
            assert video["codec_name"] == "h264" and audio["codec_name"] == "aac", name
            assert video["pix_fmt"] == "yuv420p" and video["color_primaries"] == "bt709", name
            assert video["r_frame_rate"] == f"{rate}/1" and int(video["nb_frames"]) == rate, name
            assert abs(float(inspected["format"]["duration"]) - 1.0) < 0.1, name
            assert abs(float(audio["duration"]) - 1.0) < 0.1, name
            (evidence / f"{name}-probe.json").write_text(json.dumps(inspected, indent=2) + "\n")
            checks.append({"name": name, "status": "PASS", "frames": rate, "duration": inspected["format"]["duration"]})
            print(f"PASS {name}", flush=True)
        tools = release.sparkle_tools(args.sparkle_bin)
        feed = evidence / "public-appcast.xml"
        release.fetch_feed(feed)
        release.sparkle_run(tools, "sign_update", "--verify", feed)
        checks.append({"name": "anonymous public HTTPS appcast and Ed25519 signature", "status": "PASS"})
        # A signature check must fail when the signed data is modified.
        tampered = evidence / "tampered-appcast.xml"
        assert b"Clipx Updates" in feed.read_bytes(), "Tamper fixture must modify the signed contents"
        tampered.write_bytes(feed.read_bytes().replace(b"Clipx Updates", b"Altered Updates"))
        try:
            release.sparkle_run(tools, "sign_update", "--verify", tampered)
        except subprocess.CalledProcessError:
            checks.append({"name": "tampered appcast rejected", "status": "PASS"})
        else:
            raise AssertionError("Modified feed unexpectedly verified")
        if args.app:
            info = release.app_preflight(args.app)
            release.check_helper(args.app / "Contents/Helpers/ffmpeg", args.app / "Contents/Resources/FFmpeg")
            try:
                release.assert_developer_id(args.app)
            except subprocess.CalledProcessError:
                checks.append({"name": "unsigned build rejected by release signing gate", "status": "PASS"})
            else:
                checks.append({"name": "Developer ID signature", "status": "PASS"})
            report["app"] = {"path": str(args.app), "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"]}
        report["status"] = "PASS_WITH_SKIPS" if any(check["status"] == "SKIP" for check in checks) else "PASS"
    except Exception as error:
        report["status"] = "FAIL"
        report["error"] = str(error)
        raise
    finally:
        (evidence / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Evidence: {evidence / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
