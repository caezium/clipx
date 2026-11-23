#!/usr/bin/env python3
"""Run existing native XCTest cases without launching an application window.

Requires a Debug build-for-testing with the isolated bundle identifier. Relinks
the actual app and test objects with a small CLI entry point; it does not replace
views, stores, or playback with mocks. This proves in-process behavior and bitmap
layout only, never UI automation, composited video, or a normal app launch.
"""

import argparse
import os
from pathlib import Path
import platform
import plistlib
import shlex
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", required=True, type=Path)
    parser.add_argument("--variant", choices=["Direct", "MAS"], default="Direct")
    parser.add_argument("--test-class", action="append", dest="classes")
    args = parser.parse_args()
    derived = args.derived_data.resolve()
    products = derived / "Build/Products/Debug"
    with (products / "Clipx.app/Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != "com.clipx.Clipx.Verification":
        parser.error("Build with CLIPX_BUNDLE_IDENTIFIER=com.clipx.Clipx.Verification first")

    architecture = platform.machine()
    test_target = "ClipxCoreTests" + ("-MAS" if args.variant == "MAS" else "")
    test_module = test_target.replace("-", "_")
    intermediates = derived / "Build/Intermediates.noindex/Clipx.build/Debug"
    object_files = []
    for target, product in [("Clipx-" + args.variant, "Clipx"), (test_target, test_target)]:
        file_list = intermediates / f"{target}.build/Objects-normal/{architecture}/{product}.LinkFileList"
        if not file_list.is_file():
            parser.error(f"Missing {file_list}; run build-for-testing first")
        for entry in shlex.split(file_list.read_text()):
            # The CLI owns main. All other production implementation is linked.
            # Newer Xcode also lists Clipx.debug.dylib in the test file list.
            # Its implementation is already included above; loading it again
            # would duplicate every production type and singleton.
            if Path(entry).suffix == ".o" and Path(entry).name != "ClipxApp.o" and entry not in object_files:
                object_files.append(entry)

    output = derived / "OffscreenVerification"
    output.mkdir(parents=True, exist_ok=True)
    driver = output / "main.swift"
    driver.write_text('''import AppKit
import XCTest

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: .darkAqua)
let suite = XCTestSuite(name: "Clipx offscreen verification")
for name in CommandLine.arguments.dropFirst() {
    guard let testClass = NSClassFromString(name) as? XCTestCase.Type else {
        fatalError("Missing compiled test class: \\(name)")
    }
    suite.addTest(XCTestSuite(forTestCaseClass: testClass))
}
suite.run()
guard let run = suite.testRun, run.executionCount > 0 else {
    fatalError("No tests executed")
}
print("CLIPX_OFFSCREEN_RESULT tests=\\(run.executionCount) failures=\\(run.totalFailureCount) skips=\\(run.skipCount)")
exit(run.hasSucceeded ? 0 : 1)
''')
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    platform_dev = developer / "Platforms/MacOSX.platform/Developer"
    frameworks = platform_dev / "Library/Frameworks"
    libraries = platform_dev / "usr/lib"
    executable = output / "clipx-offscreen-tests"
    command = ["xcrun", "swiftc", str(driver), "-o", str(executable),
               "-target", f"{architecture}-apple-macos14.0",
               "-I", str(libraries), "-F", str(frameworks), "-F", str(products),
               "-L", str(libraries), "-lXCTestSwiftSupport", "-framework", "XCTest"]
    for path in (frameworks, libraries, products):
        command += ["-Xlinker", "-rpath", "-Xlinker", str(path)]
    command += object_files
    subprocess.run(command, check=True)
    classes = args.classes or ["NativeMutationRegressionTests", "NativePlayerLifecycleTests",
                               "NativeSearchRegressionTests", "NativeUIRenderTests"]
    environment = os.environ.copy()
    environment.pop("CLIPX_DATA_DIRECTORY", None)
    environment["CLIPX_ISOLATED_TESTS"] = "1"
    environment["CLIPX_OFFSCREEN_RENDER"] = "1"
    try:
        result = subprocess.run([str(executable)] + [f"{test_module}.{name}" for name in classes],
                                env=environment, timeout=180)
    except subprocess.TimeoutExpired:
        print("Offscreen tests exceeded 180 seconds; the owned runner was stopped.", file=sys.stderr)
        return 1
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
