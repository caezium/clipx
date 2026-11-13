#!/usr/bin/env python3
"""Build, sign, notarize and publish Clipx without changing macOS security policy."""
import argparse
import base64
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / "Configs/Distribution.json").read_text())
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def run(command, **kwargs):
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def output(command):
    return subprocess.check_output(list(map(str, command)), text=True).strip()


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def read_info(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)


def check_helper(helper=None, support=None):
    helper = helper or ROOT / "Helpers/ffmpeg"
    support = support or ROOT / "Helpers/ffmpeg-support"
    run(["bash", ROOT / "Scripts/validate-ffmpeg.sh", helper], env={**os.environ, "ARCHS": "arm64 x86_64"})
    manifest = json.loads((support / "build-manifest.json").read_text())
    if digest(helper) != manifest["sha256"]:
        raise ValueError("FFmpeg does not match its source/build manifest; run Scripts/build-ffmpeg.py")
    for name in ["COPYING.FFmpeg", "COPYING.x264", "NOTICE.txt"]:
        if not (support / name).is_file():
            raise ValueError(f"Missing FFmpeg notice: {name}")
    return manifest


def sparkle_tools(path):
    directory = Path(path).resolve() if path else ROOT / "build/release/Packages/artifacts/sparkle/Sparkle/bin"
    for name in ["generate_keys", "generate_appcast", "sign_update"]:
        if not (directory / name).is_file():
            raise ValueError(f"Missing Sparkle tool {name}; set --sparkle-bin to the resolved Sparkle artifact's bin directory")
    public = output([directory / "generate_keys", "--account", CONFIG["sparkle_account"], "-p"])
    if public != CONFIG["sparkle_public_key"]:
        raise ValueError("Sparkle Keychain key does not match Clipx's configured public key")
    return directory


def sparkle_run(tools, program, *arguments):
    # generate_keys owns the Keychain item. Export through that tool into a private,
    # short-lived directory so other Sparkle tools don't request a new Keychain ACL.
    # The persistent key stays in Keychain; no credential appears in argv or logs.
    with tempfile.TemporaryDirectory(prefix="clipx-sparkle-key-") as temporary:
        key = Path(temporary) / "key"
        run([tools / "generate_keys", "--account", CONFIG["sparkle_account"], "-x", key],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=20)
        key.chmod(0o600)
        return run([tools / program, "--ed-key-file", key, *arguments])


def app_preflight(app):
    info = read_info(app)
    if info["CFBundleIdentifier"] != "com.clipx.Clipx":
        raise ValueError("Refusing to release an isolated verification app")
    if info.get("SUPublicEDKey") != CONFIG["sparkle_public_key"] or info.get("SUFeedURL") != CONFIG["feed_url"]:
        raise ValueError("App's update feed/key do not match Configs/Distribution.json")
    for architecture in ["arm64", "x86_64"]:
        run(["lipo", "-verify_arch", architecture, app / "Contents/MacOS/Clipx"])
    return info


def identity(value):
    identities = output(["security", "find-identity", "-v", "-p", "codesigning"])
    candidates = re.findall(r'([A-F0-9]{40}) "(Developer ID Application: [^"]+)"', identities)
    matches = [entry for entry in candidates if not value or value in entry]
    if len(matches) != 1:
        raise ValueError("Install a Developer ID Application certificate with its private key, then select it with DEVELOPER_ID or --identity")
    return matches[0][0]


def sign_app(app, signing_identity):
    app_preflight(app)
    check_helper(app / "Contents/Helpers/ffmpeg", app / "Contents/Resources/FFmpeg")
    base = ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", signing_identity]
    framework = app / "Contents/Frameworks/Sparkle.framework"
    version = (framework / "Versions/Current").resolve()
    # Sparkle's documented inside-out order; the main app's entitlements belong only to it.
    for relative in ["XPCServices/Installer.xpc", "XPCServices/Downloader.xpc", "Autoupdate", "Updater.app"]:
        target = version / relative
        if not target.exists():
            raise ValueError(f"Missing nested Sparkle code: {target}")
        flags = ["--preserve-metadata=entitlements"] if relative.endswith("Downloader.xpc") else []
        run(base + flags + [target])
    run(base + [framework])
    run(base + [app / "Contents/Helpers/ffmpeg"])
    run(base + ["--entitlements", ROOT / "Configs/Clipx-Direct.entitlements", app])
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
    assert_developer_id(app)


def assert_developer_id(app):
    requirement = 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    run(["codesign", "--verify", "--deep", "--strict", "-R", requirement, app])


def fetch_feed(destination):
    request = urllib.request.Request(CONFIG["feed_url"], headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(4 * 1024 * 1024 + 1)
    if len(data) > 4 * 1024 * 1024 or ET.fromstring(data).tag != "rss":
        raise ValueError("Invalid public appcast")
    destination.write_bytes(data)


def build(args):
    check_helper()
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    packages = (args.packages_dir or ROOT / "build/release/Packages").resolve()
    run(["xcodegen", "generate"], cwd=ROOT)
    command = ["xcodebuild", "-project", ROOT / "Clipx.xcodeproj", "-scheme", "Clipx-Direct", "-configuration", "Release",
               "-derivedDataPath", directory / "DerivedData", "-clonedSourcePackagesDirPath", packages,
               "-skipPackageUpdates", "-destination", "generic/platform=macOS", "CODE_SIGNING_ALLOWED=NO",
               "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", f"MARKETING_VERSION={args.version}", f"CURRENT_PROJECT_VERSION={args.build}", "build"]
    print(f"Building universal Clipx; log: {directory / 'build.log'}", flush=True)
    with (directory / "build.log").open("w") as log:
        run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    app = directory / "DerivedData/Build/Products/Release/Clipx.app"
    info = app_preflight(app)
    check_helper(app / "Contents/Helpers/ffmpeg", app / "Contents/Resources/FFmpeg")
    print(json.dumps({"app": str(app), "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"], "signed": False}, indent=2))


def package(args):
    original, destination = args.app.resolve(), args.directory.resolve()
    if destination.exists() and any(destination.iterdir()):
        raise ValueError("Package output must be empty; use a fresh directory for each attempt")
    info = app_preflight(original)
    manifest = check_helper(original / "Contents/Helpers/ffmpeg", original / "Contents/Resources/FFmpeg")
    sources = (args.sources or ROOT / "build/ffmpeg" / manifest["source_archive"]).resolve()
    if digest(sources) != manifest["source_archive_sha256"]:
        raise ValueError("FFmpeg corresponding sources do not match the bundled helper")
    tools = sparkle_tools(args.sparkle_bin)
    selected_identity = identity(args.identity)
    if not args.notary_profile:
        raise ValueError("Set --notary-profile or NOTARY_PROFILE to a notarytool Keychain profile")
    run(["xcrun", "notarytool", "history", "--keychain-profile", args.notary_profile, "--output-format", "json"], stdout=subprocess.DEVNULL)
    destination.mkdir(parents=True, exist_ok=True)
    updates = destination / "updates"
    updates.mkdir()
    feed = updates / "appcast.xml"
    fetch_feed(feed)
    sparkle_run(tools, "sign_update", "--verify", feed)
    base_feed_sha256 = digest(feed)
    for item in ET.parse(feed).findall("./channel/item"):
        old = item.findtext(f"{{{SPARKLE}}}version")
        if not old and item.find("enclosure") is not None:
            old = item.find("enclosure").get(f"{{{SPARKLE}}}version")
        if old and int(old) >= int(info["CFBundleVersion"]):
            raise ValueError("CFBundleVersion must increase beyond every published build")
    app = destination / "staging/Clipx.app"
    app.parent.mkdir()
    run(["ditto", original, app])
    sign_app(app, selected_identity)
    submission = destination / "notarization.zip"
    run(["ditto", "-c", "-k", "--keepParent", app, submission])
    result = subprocess.run(["xcrun", "notarytool", "submit", str(submission), "--keychain-profile", args.notary_profile, "--wait", "--output-format", "json"], capture_output=True, text=True)
    (destination / "notarization.json").write_text(result.stdout)
    (destination / "notarization.stderr.log").write_text(result.stderr)
    receipt = json.loads(result.stdout)
    if receipt.get("status") != "Accepted" or result.returncode:
        if receipt.get("id"):
            run(["xcrun", "notarytool", "log", receipt["id"], "--keychain-profile", args.notary_profile, destination / "notarization-log.json"])
        raise ValueError("Apple did not accept this app; see the notarization logs")
    run(["xcrun", "stapler", "staple", app])
    run(["xcrun", "stapler", "validate", app])
    run(["spctl", "--assess", "--type", "execute", "--verbose=2", app])
    version, build_number = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    tag = f"v{version}-{build_number}"
    archive = updates / f"Clipx-{version}-{build_number}.zip"
    run(["ditto", "-c", "-k", "--keepParent", app, archive])
    notes = args.notes.read_text()
    archive.with_suffix(".html").write_text(f"<!doctype html><meta charset='utf-8'><h1>Clipx {html.escape(version)}</h1><pre>{html.escape(notes)}</pre>\n")
    sparkle_run(tools, "generate_appcast", "--download-url-prefix",
         f"https://github.com/{CONFIG['repository']}/releases/download/{tag}/", "--link", f"https://github.com/{CONFIG['repository']}",
         "--maximum-deltas", "0", "--maximum-versions", "0", updates)
    sparkle_run(tools, "sign_update", feed)
    shutil.copy2(sources, updates / sources.name)
    assets = sorted(path for path in updates.iterdir() if path.is_file())
    (updates / "SHA256SUMS").write_text("".join(f"{digest(path)}  {path.name}\n" for path in assets))
    (destination / "release-notes.md").write_text(notes)
    (destination / "release.json").write_text(json.dumps({"tag": tag, "version": version, "build": build_number,
         "archive": archive.name, "sources": sources.name, "notarization_id": receipt["id"], "base_feed_sha256": base_feed_sha256,
         "assets": {path.name: digest(path) for path in [*assets, updates / "SHA256SUMS"]}}, indent=2) + "\n")
    verify_package(destination, tools)
    submission.unlink()
    print(f"Signed, notarized, stapled and verified package: {destination}")


def verify_package(directory, tools):
    release = json.loads((directory / "release.json").read_text())
    updates = directory / "updates"
    required = {release["archive"], release["sources"], "appcast.xml", "SHA256SUMS"}
    if not required.issubset(release["assets"]):
        raise ValueError("Release manifest is missing an application, corresponding sources, feed or checksums")
    for name, expected in release["assets"].items():
        if Path(name).name != name or digest(updates / name) != expected:
            raise ValueError(f"Release asset changed: {name}")
    feed = updates / "appcast.xml"
    sparkle_run(tools, "sign_update", "--verify", feed)
    matching = [item for item in ET.parse(feed).findall("./channel/item") if item.findtext(f"{{{SPARKLE}}}version") == release["build"]]
    if len(matching) != 1:
        raise ValueError("Appcast must contain exactly one entry for this build")
    enclosure = matching[0].find("enclosure")
    archive = updates / release["archive"]
    expected_url = f"https://github.com/{CONFIG['repository']}/releases/download/{release['tag']}/{archive.name}"
    if enclosure is None or enclosure.get("url") != expected_url or int(enclosure.get("length", "0")) != archive.stat().st_size:
        raise ValueError("Appcast URL or length does not match release archive")
    sparkle_run(tools, "sign_update", "--verify", archive, enclosure.get(f"{{{SPARKLE}}}edSignature", ""))
    with tempfile.TemporaryDirectory(prefix="clipx-release-check-") as temporary:
        run(["ditto", "-x", "-k", archive, temporary])
        app = Path(temporary) / "Clipx.app"
        info = app_preflight(app)
        if info["CFBundleVersion"] != release["build"] or info["CFBundleShortVersionString"] != release["version"]:
            raise ValueError("Archive version does not match release metadata")
        with (app / "Contents/Resources/FFmpeg/build-manifest.json").open() as stream:
            helper_manifest = json.load(stream)
        if helper_manifest["source_archive"] != release["sources"] or helper_manifest["source_archive_sha256"] != digest(updates / release["sources"]):
            raise ValueError("Release sources do not match the archived app's FFmpeg manifest")
        assert_developer_id(app)
        run(["xcrun", "stapler", "validate", app])
        run(["spctl", "--assess", "--type", "execute", app])
        # Code signing changes the helper's bytes; its source hash is checked before signing.
        run(["bash", ROOT / "Scripts/validate-ffmpeg.sh", app / "Contents/Helpers/ffmpeg"], env={**os.environ, "ARCHS": "arm64 x86_64"})
    return release


def publish(args):
    directory = args.directory.resolve()
    release = verify_package(directory, sparkle_tools(args.sparkle_bin))
    repo = CONFIG["repository"]
    state = json.loads(output(["gh", "repo", "view", repo, "--json", "isPrivate"]))
    if state["isPrivate"]:
        raise ValueError("Update repository must be public")
    current = json.loads(output(["gh", "api", f"repos/{repo}/contents/appcast.xml", "-f", f"ref={CONFIG['branch']}", "--method", "GET"]))
    current_digest = hashlib.sha256(base64.b64decode(current["content"])).hexdigest()
    if current_digest != release["base_feed_sha256"]:
        raise ValueError("Public feed changed since packaging; rebuild the package against the current feed before publishing")
    assets = [directory / "updates" / name for name in release["assets"]]
    run(["gh", "release", "create", release["tag"], *assets, "--repo", repo, "--draft", "--title", f"Clipx {release['version']}", "--notes-file", directory / "release-notes.md"])
    run(["gh", "release", "edit", release["tag"], "--repo", repo, "--draft=false", "--latest"])
    # Verify anonymous downloads before advertising an update. Never overwrite an existing tag.
    for name in [release["archive"], release["sources"]]:
        url = f"https://github.com/{repo}/releases/download/{release['tag']}/{name}"
        with tempfile.TemporaryDirectory(prefix="clipx-download-check-") as temporary:
            path = Path(temporary) / name
            run(["curl", "-fL", "--retry", "3", "--proto", "=https", "--proto-redir", "=https", "-o", path, url])
            if digest(path) != release["assets"][name]:
                raise ValueError(f"Public download mismatch: {name}; appcast was not changed")
    request = {"message": f"Publish Clipx {release['version']} build {release['build']}", "branch": CONFIG["branch"],
               "sha": current["sha"], "content": base64.b64encode((directory / "updates/appcast.xml").read_bytes()).decode()}
    run(["gh", "api", "--method", "PUT", f"repos/{repo}/contents/appcast.xml", "--input", "-"], input=json.dumps(request), text=True, stdout=subprocess.DEVNULL)
    print(f"Published https://github.com/{repo}/releases/tag/{release['tag']}\nFeed: {CONFIG['feed_url']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check-helper")
    builder = commands.add_parser("build", help="Build a universal Release app without signing or launching it")
    builder.add_argument("--directory", type=Path, default=ROOT / "build/release/app")
    builder.add_argument("--packages-dir", type=Path)
    builder.add_argument("--version", default="0.1.0")
    builder.add_argument("--build", default="1", type=lambda value: str(int(value)))
    signer = commands.add_parser("sign")
    packager = commands.add_parser("package", help="Sign, notarize, staple, archive and sign the appcast; does not publish")
    for command in [signer, packager]:
        command.add_argument("--app", type=Path, required=True)
        command.add_argument("--identity", default=os.environ.get("DEVELOPER_ID"))
    packager.add_argument("--notary-profile", default=os.environ.get("NOTARY_PROFILE"))
    packager.add_argument("--sources", type=Path)
    packager.add_argument("--notes", type=Path, required=True)
    for command in [packager, commands.add_parser("verify"), commands.add_parser("publish")]:
        command.add_argument("--directory", type=Path, required=True)
        command.add_argument("--sparkle-bin", default=os.environ.get("SPARKLE_BIN"))
    args = parser.parse_args()
    try:
        if args.command == "check-helper":
            check_helper()
        elif args.command == "build":
            if not re.fullmatch(r"\d+(\.\d+){1,2}", args.version) or int(args.build) < 1:
                raise ValueError("Use a numeric version (e.g. 0.1.0) and a positive, increasing build number")
            build(args)
        elif args.command == "sign":
            sign_app(args.app.resolve(), identity(args.identity))
        elif args.command == "package":
            package(args)
        elif args.command == "verify":
            verify_package(args.directory.resolve(), sparkle_tools(args.sparkle_bin))
        elif args.command == "publish":
            publish(args)
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        parser.exit(1, f"Release stopped: {error}\n")


if __name__ == "__main__":
    main()
