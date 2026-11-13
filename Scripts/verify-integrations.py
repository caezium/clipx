#!/usr/bin/env python3
"""Opt-in production Stint round trip and Apple FCPXML DTD verification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time
import urllib.request

PROJECT = Path(__file__).resolve().parents[1]
DTD_URL = "https://developer.apple.com/documentation/professional-video-applications/document-type-definition.md"


def run(command, log, **kwargs):
    with log.open("w") as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True,
                       timeout=900, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stint-root", type=Path, help="Local Stint checkout with npm dependencies installed")
    parser.add_argument("--fcpxml", action="store_true", help="Download Apple's published 1.10 DTD and validate exports")
    args = parser.parse_args()
    if not args.stint_root and not args.fcpxml:
        parser.error("Select --stint-root and/or --fcpxml")
    build = Path(os.environ.get("CLIPX_BUILD_ROOT", "/tmp/clipx-verification-build")).resolve()
    packages = Path(os.environ.get("CLIPX_PACKAGES_DIR", str(build / "Packages"))).resolve()
    (build / "evidence").mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="integrations-", dir=build / "evidence"))
    print(f"Evidence: {evidence}", flush=True)
    environment = {"CLIPX_ISOLATED_TESTS": "1", "CLIPX_INTEGRATION_EVIDENCE": str(evidence)}
    selected = []
    provenance = {}
    if args.fcpxml:
        with urllib.request.urlopen(DTD_URL, timeout=30) as response:
            markdown = response.read().decode()
        blocks = re.findall(r"```[^\n]*\n(.*?)```", markdown, re.S)
        dtd = next(block for block in blocks if "<!ELEMENT fcpxml" in block)
        if '<!ATTLIST fcpxml version CDATA #FIXED "1.10">' not in dtd:
            raise RuntimeError("Apple's published DTD is no longer version 1.10")
        path = evidence / "FCPXMLv1_10.dtd"
        path.write_text(dtd)
        environment["CLIPX_FCPXML_DTD_PATH"] = str(path)
        provenance["dtd"] = {"url": DTD_URL, "sha256": hashlib.sha256(dtd.encode()).hexdigest()}
        selected.append("testGeneratedFCPXMLAgainstAppleDTD")
    if args.stint_root:
        stint = args.stint_root.resolve()
        if not (stint / "node_modules/tsx").is_dir() or not (stint / "server/src/index.ts").is_file():
            raise RuntimeError("Stint requires its source and installed npm dependencies")
        run(["npm", "run", "build", "-w", "shared"], evidence / "stint-build.log", cwd=stint)
        provenance["stint_commit"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=stint, text=True).strip()
        provenance["stint_dirty"] = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=stint, text=True).strip())
        selected.append("testStintRenderUploadShareAndCommentRoundTrip")
    run(["xcodegen", "generate"], evidence / "xcodegen.log", cwd=PROJECT)
    common = ["xcodebuild", "-project", "Clipx.xcodeproj", "-scheme", "Clipx-Direct",
              "-configuration", "Debug", "-derivedDataPath", str(build / "Direct"),
              "-clonedSourcePackagesDirPath", str(packages), "-skipPackageUpdates", "-destination", f"platform=macOS,arch={os.uname().machine}",
              "CLIPX_BUNDLE_IDENTIFIER=com.clipx.Clipx.Verification", "CODE_SIGNING_ALLOWED=NO"]
    run([*common, "build-for-testing"], evidence / "build.log", cwd=PROJECT)
    manifests = list((build / "Direct/Build/Products").glob("Clipx-Direct_*.xctestrun"))
    if len(manifests) != 1:
        raise RuntimeError(f"Expected one Direct test manifest, found {len(manifests)}")
    manifest = plistlib.loads(manifests[0].read_bytes())
    server = None
    server_log = None
    try:
        if args.stint_root:
            server_env = {**os.environ, "STINT_DATA_DIR": str(evidence / "stint-data"),
                          "HOST": "127.0.0.1", "PORT": "0", "STINT_PUBLIC_ORIGIN": ""}
            server_log = (evidence / "stint-server.log").open("w")
            server = subprocess.Popen(["node", "--import", "tsx", "server/src/index.ts"], cwd=stint,
                                      env=server_env, stdout=server_log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                match = re.search(r"listening on (http://127\.0\.0\.1:\d+)", (evidence / "stint-server.log").read_text())
                if match:
                    environment["CLIPX_STINT_TEST_URL"] = match[1]
                    break
                if server.poll() is not None:
                    raise RuntimeError("Disposable Stint server exited; see stint-server.log")
                time.sleep(0.1)
            else:
                raise RuntimeError("Disposable Stint server did not become ready within 30 seconds")

        def configure(value):
            count = 0
            if isinstance(value, dict):
                if "TestBundlePath" in value:
                    value.setdefault("EnvironmentVariables", {}).update(environment)
                    count += 1
                for child in value.values():
                    count += configure(child)
            elif isinstance(value, list):
                for child in value:
                    count += configure(child)
            return count

        if configure(manifest) != 1:
            raise RuntimeError("Expected one isolated test target")
        # Keep beside the original so __TESTROOT__ still resolves the built app.
        configured = manifests[0].with_name("Clipx-External.xctestrun")
        configured.write_bytes(plistlib.dumps(manifest))
        result = evidence / "integrations.xcresult"
        run(["xcodebuild", "test-without-building", "-xctestrun", str(configured),
             "-destination", f"platform=macOS,arch={os.uname().machine}", "-resultBundlePath", str(result),
             *[f"-only-testing:ClipxCoreTests/ExternalIntegrationTests/{name}" for name in selected]],
            evidence / "test.log", cwd=PROJECT)
        summary = json.loads(subprocess.check_output([
            "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)]))
        (evidence / "test-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        if summary.get("passedTests") != len(selected) or summary.get("failedTests") != 0 or summary.get("skippedTests") != 0:
            raise RuntimeError("Selected integration tests did not all pass without skips")
        report = {"status": "PASS", "tests": selected, "provenance": provenance, "evidence": str(evidence)}
        (evidence / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        if server is not None and server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        if server_log is not None:
            server_log.close()


if __name__ == "__main__":
    main()
