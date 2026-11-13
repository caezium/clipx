# Verification follow-up — November 12–13, 2026

Two previously open checks now pass: full Apple FCPXML 1.10 DTD validation and a real Clipx → Stint → Clipx round trip against a disposable local server. This does not establish release readiness. Machine security settings were left unchanged, as requested.

## New evidence

| Check | Result and boundary |
| --- | --- |
| FCPXML DTD | Two production documents passed `xmllint` against Apple's complete 1.10 DTD. Covers a silent one-frame selection, escaped names, mixed frame rates, repeated source references and audio. Actual Final Cut import remains untested. |
| Stint round trip | Production renderer and HTTP client created a project, uploaded a two-second clip, downloaded it through guest access, and pulled threaded comments back while preserving personal notes. Local upload receipts and completion were checked. |
| Remote browser | All 10 existing workflows passed in Chromium, including 320–1280px layouts. Requests use synthetic fixtures; this is not a physical phone/Wi-Fi test. |
| Actual HTTP server | Parser rejection, subsequent auth, byte-for-byte full/suffix/large-range streaming, and connection/handler shutdown passed on loopback. |

The Stint download probes as two seconds of H.264 at 1920×1080, 30 fps, with AAC audio. The server used unchanged Stint commit `a13087c887de6f3cba4b9fbb067504183fc9f934`, an ephemeral loopback port, and a fresh temporary data directory. It was stopped after verification. Neither app's real library was used.

See [results.json](results.json) for provenance, commands/log paths and source hashes, [the two-test XCTest summary](integrations-summary.json), [the test log](integrations-test.log), [downloaded-media metadata](stint-media-probe.json), and [returned notes](stint-returned-notes.txt). Both selected tests passed with zero failures and zero skips. [Apple's published DTD](https://developer.apple.com/documentation/professional-video-applications/document-type-definition.md) was downloaded directly; its SHA-256 is retained in [integration provenance](integrations-results.json).

## Remaining limits

- **Native clicks:** the ad-hoc runner initially could not load its test bundle under hardened runtime. `verify.sh ui` now disables that setting only for the disposable Debug test build. The runner then [timed out enabling Automation Mode](native-click-error.txt), before running a test. `automationmodetool` reports that UI automation is disabled and requires user authentication. The user declined a temporary authentication-policy change.
- **Full regression suites:** the Direct and MAS test targets compiled, but subsequent runs stalled before test cases began. A [Direct host sample](core-host.sample) shows XCTest waiting for its test configuration / IDE session. Separate execution, explicit target selection and a focused retry did not clear the stall. Owned test processes were stopped. The historical 186/180 passing counts have **not** been freshly reproduced, and no new complete native layout suite passed.
- **Distribution:** [preflight](preflight.json) found zero valid signing identities, a Homebrew-linked FFmpeg helper, and a placeholder Sparkle public key. The helper validator correctly rejected that binary. Signing, notarization, update-service validation and signed MAS enforcement remain open.
- **External/manual checks:** Final Cut import, physical phone/Wi-Fi use, and an externally deployed Stint instance remain untested. The local real-server check does not establish those environments.

This run used Xcode 27.2, Swift 6.4.2, macOS 27.2.1 and FFmpeg 9.0.2. The earlier repair evidence used a different toolchain; these results supplement it rather than replacing its historical counts.

## Reproduce

```sh
CLIPX_BUILD_ROOT=/tmp/clipx-verification-20261112 \
  python3 Scripts/verify-integrations.py --fcpxml --stint-root /absolute/path/to/Stint

PLAYWRIGHT_BROWSERS_PATH=/tmp/clipx-browser-cache \
CLIPX_PLAYWRIGHT_MODULE=/absolute/path/to/Stint/node_modules/playwright-core \
  ./Scripts/verify.sh browser

python3 Tests/ClipxCoreTests/ServerHTTPRegression.py
```

The integration runner builds the verification app, injects opt-in settings into a temporary `.xctestrun`, requires every selected check to pass without skips, and cleans up its server. The two new checks skip during ordinary suites. Native variants must run sequentially. Test logs and `.xcresult` bundles remain under `/tmp/clipx-verification-20261112`; temporary files may later be cleaned by macOS. Selected evidence is retained here. The app's release configuration was not changed.
