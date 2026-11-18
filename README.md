# Clipx

The fastest way to mark, find, and export clips from your own footage — without launching a video editor.

A Mac-native clip workbench that sits between source footage and the NLE/social platform. Owns the daily creator loop: **scrub → mark in/out → tag → export at platform-correct resolution → post**.

## Features (beta v0.1)

- **Library** — watch one or more folders for video files, auto-extract metadata (codec, resolution, fps, duration, color space), generate thumbnails with hover-scrub sprites
- **Player** — frame-accurate AVPlayer-backed scrubbing, in/out marking with hotkeys, multiple non-destructive clip ranges per source
- **Tagging** — color labels, free-text tags with autocomplete, structured fields (mood, shot type, camera movement, setting), star ratings
- **Search** — SQLite FTS5 instant search, multi-faceted filter sidebar, Cmd+K command palette
- **Export presets** — Reels (9:16), TikTok, YouTube Shorts, IG feed (4:5), YouTube 1080p, YouTube 4K
- **Bridges** — FCPXML 1.10 export to Final Cut Pro, `.md` sidecar writer to Obsidian vault with YAML frontmatter
- **Project grouping** — group clips into named output projects
- **Two-track distribution** — Direct build (ffmpeg sidecar, full presets, global hotkey, Sparkle updates) and Mac App Store build (sandboxed, AVAssetExportSession backend, no loudness normalization)

## Build prerequisites

- macOS 14+ (Sonoma or later)
- Xcode 26+ with Swift 6.x
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- [ffmpeg](https://ffmpeg.org/) for the Direct build — `brew install ffmpeg` for development; distribution requires a verified portable binary with only system-library dependencies. The Direct target bundles the helper during every build.

## Getting started

```bash
# 1. Clone and enter the repo
cd clipx

# 2. Generate the Xcode project from project.yml
xcodegen generate

# 3. (Direct build only) Symlink the dev ffmpeg binary so unsigned dev builds work
./Scripts/setup.sh

# 4. Open in Xcode
open Clipx.xcodeproj

# 5. Pick a scheme:
#    - Clipx-Direct  → direct distribution (full features, ffmpeg sidecar)
#    - Clipx-MAS     → Mac App Store (sandboxed, reduced exports)
# 6. Run (⌘R)
```

Or build from the command line:

```bash
# Direct (development, no signing)
xcodebuild -project Clipx.xcodeproj -scheme Clipx-Direct \
  -configuration Debug -derivedDataPath /tmp/clipx-build/Direct \
  CODE_SIGNING_ALLOWED=NO build

# MAS (development, no signing)
xcodebuild -project Clipx.xcodeproj -scheme Clipx-MAS \
  -configuration Debug -derivedDataPath /tmp/clipx-build/MAS \
  CODE_SIGNING_ALLOWED=NO build
```

## Project layout

```
clipx/
├── project.yml                       # XcodeGen config (the source of truth)
├── Configs/
│   ├── Info.plist                    # Direct build
│   ├── Info-MAS.plist                # MAS build
│   ├── Clipx-Direct.entitlements     # Hardened runtime, no sandbox
│   └── Clipx-MAS.entitlements        # App sandbox + minimum required perms
├── Sources/
│   ├── ClipxApp/                     # App entry, root views, state, settings
│   ├── ClipxCore/                    # Database, models, indexer, watcher, bookmarks
│   ├── ClipxPlayer/                  # Player, scrubbing, marking, timeline strip
│   ├── ClipxLibrary/                 # Grid/list views, filter sidebar, thumbnails
│   ├── ClipxTagging/                 # Tags, search, command palette
│   ├── ClipxExport/                  # Export pipeline, ffmpeg + AVFoundation backends, presets
│   ├── ClipxBridges/                 # Obsidian sidecar, FCPXML, drag-drop
│   ├── ClipxHotkey/                  # Global hotkey (Direct only)
│   ├── ClipxSparkle/                 # Auto-updates (Direct only)
│   └── ClipxOnboarding/              # First-run wizard
├── Resources/
│   └── Assets.xcassets/
├── Helpers/
│   └── ffmpeg                        # Static binary for Direct build (gitignored)
├── Tests/
│   ├── ClipxCoreTests/               # Stores, real media, native rendering, HTTP/browser fixtures
│   └── ClipxUITests/                 # Isolated native click workflow
└── Scripts/
    ├── setup.sh                      # Dev setup
    ├── build-ffmpeg.py               # Build universal FFmpeg and matching sources
    ├── bundle-ffmpeg.sh              # Install a checksum-verified external helper
    ├── copy-ffmpeg.sh                # Direct target's helper build phase
    ├── validate-ffmpeg.sh            # Release portability/architecture check
    ├── verify.sh                     # Isolated regression entry point
    ├── release.py                    # Build, sign, notarize, verify and publish
    └── verify-release.py             # Headless media and update-signature checks
```

## Architecture

Hybrid **AVFoundation + ffmpeg** stack:

- **AVFoundation** handles all playback, scrubbing, thumbnail generation, and basic export (MAS build only)
- **ffmpeg sidecar** handles loudness normalization (-10 / -14 LUFS), precise bitrate targeting, advanced codec features, and final encoding after native HDR/wide-gamut conversion to Rec.709 (Direct build only)
- **Runtime chip detection** chooses the software or VideoToolbox encoder; export, drag, and Stint use one validated render request for source-time marks, rotation, and speed.

Build-variant differences are gated with `#if DIRECT_BUILD` / `#if MAS_BUILD`. The MAS build excludes `ClipxHotkey/`, `ClipxSparkle/`, and `FFmpegBackend.swift` from its sources entirely.

## Distribution

### Direct (recommended for power users)

Public download hosting and the signed Sparkle feed are configured at [clipx-releases](https://github.com/caezium/clipx-releases). Developer ID signing and independent verification of the returned build are complete. No application release is published yet; notarization still requires Apple credentials.

All six export presets and the hardware export passed with the signed app's bundled helper. A [local release rehearsal](docs/verification/2026-11-18-release-prep/README.md) also verified real Sparkle archive/feed signatures, component-source checksums, and rejection of altered artifacts. Rehearsal output is explicitly unpublishable.

```sh
python3 Scripts/build-ffmpeg.py
python3 Scripts/release.py build --version 0.1.0 --build 1
```

The [distribution guide](docs/DISTRIBUTION.md) covers verification, credentials, matching FFmpeg sources, and the separate package/publish commands.

### Mac App Store

1. Generate a Mac App Distribution certificate
2. Set up an App Store Connect listing
3. Archive the `Clipx-MAS` scheme
4. Upload via Xcode Organizer

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `I` | Mark In |
| `O` | Mark Out |
| `S` | Save range as clip |
| `Space` | Play / pause |
| `←` `→` | Step one frame back / forward |
| `⌘K` | Command palette |
| `⌘F` | Search |
| `⌘O` | Add folder |
| `⌘⇧R` | Export selected as Reels |
| `⌘⇧C` | (Direct only) Quick-add frontmost video to library |

Plain marking and transport keys apply while the player has focus. Rate clips from the inspector or Clip menu.

## Verification

The reviewed baseline is committed as `c700be3`. [CODE_REVIEW.md](CODE_REVIEW.md) records the original findings; [REPAIR_NOTES.md](REPAIR_NOTES.md) maps the repairs and verification limits.

```bash
./Scripts/verify.sh doctor
./Scripts/verify.sh core     # Direct backend and complete regression suite
./Scripts/verify.sh mas      # App Store backend and complete regression suite
./Scripts/verify.sh native   # Real SwiftUI screens with isolated media/data
./Scripts/verify.sh browser  # Remote browser flows; requires Playwright
```

Builds live under `/tmp/clipx-verification-build` by default; `CLIPX_BUILD_ROOT` and `CLIPX_PACKAGES_DIR` can reuse existing caches. Test schemes use a separate app identity and isolated preferences, data, and caches. Native render captures are written to `/tmp/clipx-native-ui-evidence`; logs and `.xcresult` bundles stay with the build products. See the [project verification skill](.agents/skills/verify-clipx/SKILL.md) for browser setup, evidence, cleanup, and the optional native click workflow.

## Release inputs

Release builds require a universal FFmpeg helper with only system-library dependencies, matching source metadata and license notices. `Scripts/build-ffmpeg.py` supplies the complete package, and `Scripts/setup.sh` preserves an installed release helper. Apple Developer ID/notarization credentials remain external inputs; the feed and update key are configured.

Full Apple FCPXML DTD validation and a real isolated Stint round trip passed in the [integration follow-up](docs/verification/2026-11-13/README.md). Native click testing, actual Final Cut Pro import, signed App Store sandbox behavior and a physical phone session remain unverified. Frame stepping on variable-frame-rate footage still uses nominal frame timing.

## License

TBD.
