# Direct distribution

Clipx uses [public GitHub Releases](https://github.com/caezium/clipx-releases/releases) for downloads and a [public HTTPS Sparkle feed](https://raw.githubusercontent.com/caezium/clipx-releases/main/appcast.xml). The feed is live and signed, but intentionally contains no application release. No separate server or domain subscription is required. Repository visibility for the application source is independent of download hosting.

## Current state

The universal Release app and portable FFmpeg build successfully for arm64 and x86_64, targeting macOS 14. All six presets and a VideoToolbox export passed on Apple Silicon using production argument generation, with Homebrew excluded from the encoder's environment. Intel execution remains unverified because this Mac has no Rosetta. Native click testing remains pending while the Mac is locked; no automation or security settings were changed.

Developer ID signing is complete. The MacBook signed with team `YGSM2722TZ`, and the Studio independently verified Apple's trust chain, nested signatures, and unchanged original payload. Both software and VideoToolbox exports passed with the returned signed helper. The private signing key stays on the MacBook; the Studio has the build and Sparkle key. Apple notarization still requires credentials. See [the returned-build evidence](verification/2026-11-15-signed-build/README.md) and [earlier build evidence](verification/2026-11-13-release/README.md) for exact checks and gaps.

## Build the portable helper

Requires Xcode, Python 3, make, pkg-config and nasm. Homebrew can supply build tools; its dynamic codec libraries are not linked into the result.

```sh
python3 Scripts/build-ffmpeg.py
python3 Scripts/release.py check-helper
```

The builder verifies pinned FFmpeg 9.0.2 and x264 source checksums, compiles each architecture separately, and installs the universal executable at `Helpers/ffmpeg`. It replaces a development symlink without modifying its Homebrew target. Release builds reject non-system dependencies, a missing architecture, mismatched source metadata, or missing license notices.

`build/ffmpeg/*-sources.tar.gz` contains the exact upstream source archives, build script, compiler/configuration manifest and rebuild instructions. Each release must distribute that matching archive alongside the application. FFmpeg/libx264 license notices and source locations are copied into the app. The helper uses GPL-2.0-or-later components; no nonfree components are enabled. The application also includes GRDB and Sparkle license notices.

## Build and check Clipx

```sh
python3 Scripts/release.py build --version 0.1.0 --build 1

export SPARKLE_BIN="$PWD/build/release/Packages/artifacts/sparkle/Sparkle/bin"
python3 Scripts/verify-release.py \
  --app "$PWD/build/release/app/DerivedData/Build/Products/Release/Clipx.app"
```

`build` supports `--packages-dir` for an existing Swift package cache; point `SPARKLE_BIN` at that cache's Sparkle tools when using it. Build numbers must be positive and increase for every published release. Evidence defaults to `build/release/evidence`; `PASS_WITH_SKIPS` explicitly means an architecture could not execute on this host. These checks do not replace native UI, signed-app launch, or update installation testing.

## Apple credentials and update keys

Install a **Developer ID Application** certificate and its private key using your Apple Developer account. A certificate without its private key cannot sign the app. `security find-identity -v -p codesigning` should list the identity. Set `DEVELOPER_ID` to its full name or SHA-1 identifier if more than one is available.

Create a notarization Keychain profile interactively, so credentials never enter repository files or shell history:

```sh
xcrun notarytool store-credentials Clipx
export NOTARY_PROFILE=Clipx
```

Clipx's Ed25519 key is already stored in the login Keychain under account `com.clipx.Clipx`. Only its public key is in `Configs/Distribution.json` and `project.yml`. The release script exports through Sparkle's `generate_keys` into a private temporary directory for each signing operation, then removes that temporary file. It does not broaden Keychain access or change system security settings.

Back up the update private key in your secure credential store before relying on this Mac as the sole release signer. Sparkle's `generate_keys --account com.clipx.Clipx -x /secure/path/key` exports it; `-f /secure/path/key` imports it on another signing Mac. Use `umask 077`, keep the destination outside the repository, and never upload the private key as a release asset. The release script checks that the loaded key matches the app's public key before signing.

## Package, review, then publish

### Signing on the MacBook

The prepared draft transfer and exact MacBook-agent commands are in [MacBook signing handoff](MACBOOK_SIGNING.md).

Transfer the unsigned application in a `ditto -c -k --keepParent` ZIP and verify its SHA-256 before extracting it. `Scripts/release.py`, `Scripts/validate-ffmpeg.sh`, `Configs/Distribution.json`, and `Configs/Clipx-Direct.entitlements` are sufficient for the signing command; a full Xcode build and the Sparkle private key are not needed on the signing machine.

```sh
python3 Scripts/release.py sign --app /path/to/Clipx.app \
  --identity 2B8D05A2470C0AC720996E5425E48B8FC4828953
ditto -c -k --keepParent /path/to/Clipx.app Clipx-signed.zip
```

Return that signed archive to the Studio and extract it into a separate directory. Keep the original unsigned build for comparison. On the Studio:

```sh
python3 Scripts/release.py verify-signed \
  --app /path/to/returned/Clipx.app \
  --unsigned-reference "$PWD/build/release/app/DerivedData/Build/Products/Release/Clipx.app"

python3 Scripts/release.py package --signed \
  --app /path/to/returned/Clipx.app \
  --unsigned-reference "$PWD/build/release/app/DerivedData/Build/Products/Release/Clipx.app" \
  --directory "$PWD/build/release/0.1.0-1" \
  --notes /path/to/release-notes.md
```

The returned app and every nested signing target must have a valid Developer ID signature from team `YGSM2722TZ`. The script also compares the app's code, resources, permissions and symlinks with the original build, excluding code signatures and their virtual allocation size. It normalizes temporary copies, leaving both originals untouched. The Studio can then notarize, staple and sign Sparkle updates without importing the MacBook's private key. A notarization Keychain profile is still required on the Studio.

### Signing and packaging on one machine

```sh
python3 Scripts/release.py package \
  --app "$PWD/build/release/app/DerivedData/Build/Products/Release/Clipx.app" \
  --directory "$PWD/build/release/0.1.0-1" \
  --notes /path/to/release-notes.md

python3 Scripts/release.py verify --directory "$PWD/build/release/0.1.0-1"

# After reviewing the notarization receipt, release notes, and app behavior:
python3 Scripts/release.py publish --directory "$PWD/build/release/0.1.0-1"
```

Packaging copies the unsigned build into staging, signs Sparkle's nested code and FFmpeg before signing Clipx, submits to Apple, staples and validates the accepted ticket, and assesses Gatekeeper. Only then does it create the final ZIP, Ed25519 signatures, appcast, source archive copy and checksums. Packaging does not publish. A failed attempt retains its logs; retry into a fresh directory using the unchanged unsigned build.

Publication rechecks the extracted application and every asset, creates a GitHub release, anonymously downloads and hashes the app and source archives, then updates the feed using GitHub's commit-SHA concurrency check. Existing release tags are never overwritten. If a published release's download check fails, the old feed remains in place; inspect the release before retrying. The feed can take several minutes to propagate through GitHub's cache.

The Mac App Store target has separate signing, sandbox testing, and submission requirements; this pipeline packages the Direct target.

## References

- [Apple: notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: sign nested code inside out](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
- [Sparkle: signing its nested helpers](https://sparkle-project.org/documentation/sandboxing/#code-signing)
- [Sparkle: publishing updates](https://sparkle-project.org/documentation/publishing/)
- [FFmpeg: redistribution requirements](https://ffmpeg.org/legal.html)
