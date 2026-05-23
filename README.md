# Clipx

The fastest way to mark, find, and export clips from your own footage — without launching a video editor.

A Mac-native clip workbench that sits between source footage and the NLE/social platform. Owns the daily creator loop: **scrub → mark in/out → tag → export at platform-correct resolution → post**.

## Features (beta v0.1)

- **Library** — watch one or more folders for video files, auto-extract metadata (codec, resolution, fps, duration, color space), generate thumbnails with hover-scrub sprites
- **Player** — frame-accurate AVPlayer-backed scrubbing, in/out marking with hotkeys, multiple non-destructive clip ranges per source
- **Tagging** — color labels, free-text tags with autocomplete, structured fields (mood, shot type, camera movement, setting), star ratings
- **Search** — SQLite FTS5 instant search, multi-faceted filter sidebar, Cmd+K command palette
- **Export presets** — Reels (9:16), TikTok, YouTube Shorts, IG feed (4:5), YouTube 1080p, YouTube 4K
- **Bridges** — FCPXML 1.13 export to Final Cut Pro, `.md` sidecar writer to Obsidian vault with YAML frontmatter
- **Project grouping** — group clips into named output projects
- **Two-track distribution** — Direct build (ffmpeg sidecar, full presets, global hotkey, Sparkle updates) and Mac App Store build (sandboxed, AVAssetExportSession backend, no loudness normalization)

## Build prerequisites

- macOS 14+ (Sonoma or later)
- Xcode 26+ with Swift 6.x
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- [ffmpeg](https://ffmpeg.org/) for the Direct build — `brew install ffmpeg` (dev) or download static binary for distribution

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
  -configuration Debug -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build

# MAS (development, no signing)
xcodebuild -project Clipx.xcodeproj -scheme Clipx-MAS \
  -configuration Debug -derivedDataPath build/DerivedData \
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
│   └── ClipxCoreTests/
└── Scripts/
    ├── setup.sh                      # Dev setup
    ├── bundle-ffmpeg.sh              # Download + bundle static ffmpeg
    └── sign.sh                       # Code-sign helper
```

## Architecture

Hybrid **AVFoundation + ffmpeg** stack:

- **AVFoundation** handles all playback, scrubbing, thumbnail generation, and basic export (MAS build only)
- **ffmpeg sidecar** handles loudness normalization (-10 / -14 LUFS), precise bitrate targeting, advanced codec features, color metadata stamping (Direct build only)
- **Runtime chip detection** picks `h264_videotoolbox` on M1 base and `libx264` on M-series Pro/Max (where VideoToolbox is 20-40× slower)

Build-variant differences are gated with `#if DIRECT_BUILD` / `#if MAS_BUILD`. The MAS build excludes `ClipxHotkey/`, `ClipxSparkle/`, and `FFmpegBackend.swift` from its sources entirely.

## Distribution

### Direct (recommended for power users)

1. Enroll in Apple Developer Program ($99/yr)
2. Generate a Developer ID Application certificate
3. Set `CODE_SIGN_IDENTITY` and configure notarization credentials
4. Run `./Scripts/sign.sh release`
5. Bundle into a DMG
6. Notarize via `xcrun notarytool submit`
7. Staple the ticket: `xcrun stapler staple`
8. Sparkle handles updates from `https://updates.clipx.app/appcast.xml`

### Mac App Store

1. Generate a Mac App Distribution certificate
2. Set up an App Store Connect listing
3. Archive the `Clipx-MAS` scheme
4. Upload via Xcode Organizer or `xcrun altool`

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `I` | Mark In |
| `O` | Mark Out |
| `S` | Save range as clip |
| `Space` | Play / pause |
| `←` `→` | Step one frame back / forward |
| `1`-`5` | Rate selected clip(s) ★ |
| `⌘K` | Command palette |
| `⌘F` | Search |
| `⌘O` | Add folder |
| `⌘⇧R` | Export selected as Reels |
| `⌘⇧C` | (Direct only) Quick-add frontmost video to library |

## Status

**Beta v0.1 — both build targets compile, release binary runs, 36 unit tests pass.**

Working:
- Both `Clipx-Direct` and `Clipx-MAS` build clean (Debug + Release)
- Release `.app` is 17 MB, launches and runs without crashing
- Database, indexer, folder watcher, thumbnail engine, marker store, tag store, search engine, FCPXML/Obsidian bridges all unit-tested
- All UI screens functional: library grid + list, inspector pane, sidebar, settings tabs, command palette, shortcut overlay, export progress, onboarding wizard, New Project / New Collection sheets

What still needs your hands to ship as a real product:

- **Apple Developer enrollment** + Developer ID Application cert + notarization credentials
- **Real Sparkle appcast feed** — `SUFeedURL` is a placeholder; needs a real hosted XML and Ed25519 keypair
- **Static ffmpeg binary** — `Scripts/bundle-ffmpeg.sh` exists with the URL stubbed; audit + sign whatever binary you ship
- **Bundled sample clips** for onboarding's "ready" state
- **Crash reporter** — choose KSCrash / PLCrashReporter / Sentry and wire it up
- **Frame-step VFR accuracy** — current implementation uses average fps; for VFR sources a proper keyframe index (via AVAssetReader) would be more accurate
- **FCPXML richness** — current output is single sequence, no markers, no audio sub-roles. Valid FCPXML 1.13, drops into FCP, but won't roundtrip rich metadata
- **Premiere XML, Resolve EDL, Notion CSV bridges** — deferred to v0.2

## License

TBD.
