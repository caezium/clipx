# Exports and bridges

Menu, drag and review renders use the same source-time selection, speed and rotation, while retries and cancellations preserve existing files and notes.

## Sub-features

- Correct boundary frames, audio/video duration and HDR-to-Rec.709 conversion.
- Private staging, exclusive publication, cancellation and terminal history.
- Stable sidecar identity, bounded generated notes and frame-valid FCPXML.
- Durable Stint upload receipts and stale-refresh protection.

## How to get to it (user POV)

- Export from a clip context menu, inspector, project header or selection toolbar.
- Drag a clip to another application, write an Obsidian sidecar, or send for review.
- Open export progress to cancel pending work; retry a failed review transfer.

## Driving it with XCTest

Preconditions: Direct helper is executable; MAS uses AVFoundation. No real review-server credentials are needed.

- Run `Scripts/verify.sh core` and `Scripts/verify.sh mas`. Media regressions generate actual media and inspect rendered output; lifecycle tests exercise collisions, cancellation and history.
- Sidecar/FCPXML tests inspect written documents; Stint tests inject a controlled client and verify persisted receipts, retries, stale comments and partial progress.
- Run `bash Scripts/validate-ffmpeg.sh Helpers/ffmpeg` before a Release build. A Homebrew dependency must fail this distribution check.

## Opt-in external integration checks

```sh
python3 Scripts/verify-integrations.py --fcpxml --stint-root /absolute/path/to/Stint
```

Either option can run alone. `--fcpxml` downloads the complete 1.10 DTD from Apple's developer documentation and validates production exports with `xmllint`, including silent audio, escaped names, one-frame selections and mixed frame rates. The downloaded schema and its URL/hash remain with the evidence; a DTD pass does not establish Final Cut import.

`--stint-root` requires the local Stint source, its installed npm dependencies, Node 22.16+, and FFmpeg/ffprobe. The runner rebuilds Stint's shared package and launches its production server on an ephemeral loopback port with a new `STINT_DATA_DIR`. The native test renders and uploads generated footage through the real bridge, downloads it using guest access, posts threaded comments, then verifies their return to Clipx alongside existing notes and durable upload receipts. It never uses the checkout's normal data store or the user's Clipx preferences.

Run sequentially with other native tests. The runner builds the isolated Direct target, configures only its temporary `.xctestrun`, and requires every selected test to pass with zero skips. Logs, source/downloaded media, exported XML, comments, server data and `.xcresult` are retained under `$CLIPX_BUILD_ROOT/evidence/integrations-*`; the server is stopped on completion or failure. The two opt-in tests skip during ordinary suites.

## Gotchas

Keep ordinary Stint fixture tests alongside the opt-in round trip; the local server check does not validate a deployed service or a physical remote device. HDR fixture creation requires optional libx265 and may skip if unavailable. Final Cut import and signed App Store behavior remain separate manual checks. Release signing, feed keys and a portable FFmpeg build are external inputs.
