---
name: verify-clipx
description: Verify Clipx's native macOS UI, library, media exports, and Remote browser using isolated fixtures after code or UI changes.
---

# Verify Clipx

Canonical location: `.agents/skills/verify-clipx/`. The executable entry point is `Scripts/verify.sh`; source ownership and current proof are recorded in `REPAIR_NOTES.md`.

## Launch

Run from the repository root on macOS 14+ with Xcode, XcodeGen, and FFmpeg installed. `Scripts/setup.sh` installs the development helper link and generates the project. Build products default to `/tmp/clipx-verification-build`. Override `CLIPX_BUILD_ROOT` and `CLIPX_PACKAGES_DIR` to reuse a verified build/cache. Run native variants sequentially on one machine.

```sh
./Scripts/verify.sh doctor
./Scripts/verify.sh core
./Scripts/verify.sh mas
./Scripts/verify.sh native
```

These commands use `com.clipx.Clipx.Verification`, never the user's `com.clipx.Clipx` instance. Test schemes set `CLIPX_ISOLATED_TESTS=1`; AppPreferences chooses a unique temporary data directory, separate preference suite, and cache root. AppDelegate skips ordinary test-host startup; the native renderer explicitly bootstraps the isolated library. Global hotkeys and Sparkle are disabled in isolated sessions. No live Stint uploads occur.

For opt-in FCPXML schema validation and a real round trip against a disposable local Stint server, use `Scripts/verify-integrations.py` as described in [Exports and bridges](features/exports.md). Its Stint uploads contain generated footage and use a fresh temporary store on loopback.

For distribution changes, follow the [distribution guide](../../../docs/DISTRIBUTION.md) and run `Scripts/verify-release.py` with the resolved Sparkle tools. It compiles production export arguments into a command-line fixture, exercises the portable helper and verifies the public appcast signature without a GUI session. Preserve architecture skips; a built Intel slice is not proof of Intel execution. Apple signing/notarization and native click verification are separate requirements.

## Doctor

`Scripts/verify.sh doctor` checks Xcode/XcodeGen, the Direct helper, and the selected build paths. Require a passing exit code and confirm the bundle identifier in the test invocation is `com.clipx.Clipx.Verification`. Native render evidence contains requested/actual window dimensions and capture method beside every PNG. Never drive `/Applications/Clipx.app` or a process not launched by this run.

## Drive and evidence

Read [features/README.md](features/README.md), then the matching feature. Tests must complete with `TEST SUCCEEDED`; compile success alone is insufficient. Logs are under `$CLIPX_BUILD_ROOT/evidence` and `.xcresult` bundles under each variant's `Logs/Test`. Native screenshots and geometry notes live under `/tmp/clipx-native-ui-evidence`.

`native` renders real SwiftUI/AppKit windows and actual AVFoundation fixture media. It attempts to capture only its owned NSWindow; bitmap fallback is explicitly labeled because system materials and AVPlayerLayer may not composite. Inspect the resulting images and the narrow-window dimensions. This is not a substitute claim for the separate native click workflow.

```sh
./Scripts/verify.sh ui
```

The optional `ui` mode drives import → mark → capture → inspector edit and reads the saved SQLite row. It signs the disposable Debug build ad-hoc with hardened runtime disabled so the XCTest runner can load its unsigned-team test bundle. It requires working macOS UI automation: inspect `automationmodetool` without arguments for its status. On Xcode 27.2, the runner loaded but timed out enabling Automation Mode; the machine required user authentication. Do not change machine security settings implicitly, and do not report that click workflow as passed. Its artifacts, when available, live under `/tmp/clipx-ui-evidence` with the latest run path in `/tmp/clipx-ui-evidence-latest`.

The November 13 single-test probe also stalled while `CGSSessionScreenIsLocked` was `Yes`. Unlocking has not been tested as a fix because the user chose to keep the Mac locked. Do not retry GUI-hosted tests repeatedly in that state or change automation/authentication settings. Continue headless checks and retain the native limitation.

## Remote browser setup

The browser fixture compiles production WebContent and intercepts all requests with synthetic data. It never contacts a real library. Requires Node 20+, FFmpeg with libx264, and a matching Playwright browser:

```sh
npm install --prefix /tmp/clipx-browser-tools --no-save --no-package-lock playwright-core@1.63.0
PLAYWRIGHT_BROWSERS_PATH=/tmp/clipx-browser-cache node /tmp/clipx-browser-tools/node_modules/playwright-core/cli.js install chromium --only-shell
PLAYWRIGHT_BROWSERS_PATH=/tmp/clipx-browser-cache CLIPX_PLAYWRIGHT_MODULE=/tmp/clipx-browser-tools/node_modules/playwright-core ./Scripts/verify.sh browser
python3 Tests/ClipxCoreTests/ServerHTTPRegression.py
```

An existing compatible module/browser can be supplied through `CLIPX_PLAYWRIGHT_MODULE` and `CLIPX_BROWSER_EXECUTABLE`. The browser runner prints JSON with `status: PASS`, checks, and artifact directory. The HTTP runner binds only an ephemeral loopback port and verifies the actual server's parsing, streamed bytes, and shutdown.

## Cleanup

Xcode tears down its test app; the renderer closes each window it creates. Browser and HTTP scripts stop only their own processes. Preserve logs, screenshots, and `.xcresult` evidence. If interrupted, identify the PID by the exact temporary build path before terminating it; never kill Clipx by process name. Scratch build/media directories may be removed after evidence is retained. No real library or external review project should need cleanup.

Maintain this map with `maintain-verification-skill` when entry points or helpers change.
