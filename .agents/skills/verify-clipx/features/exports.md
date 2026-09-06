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

## Gotchas

Do not send live Stint requests as a substitute for the fixture tests. HDR fixture creation requires optional libx265 and may skip if unavailable. Final Cut import/full Apple DTD validation and signed App Store behavior remain separate manual checks. Release signing, feed keys and a portable FFmpeg build are external inputs.
