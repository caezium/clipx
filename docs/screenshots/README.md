# README screenshots

The main README uses two complementary views: [workspace.png](workspace.png) shows footage, marked ranges, and clip details; [library.png](library.png) shows six saved clips organized into a project. Both were captured on November 23, 2026 at 1140 × 772 pixels, including the native window toolbar.

The capture runner hosts the compiled production `RootView` in an AppKit window and captures that exact process/window with ScreenCaptureKit. The workspace contains the actual AVPlayerLayer paused at 00:06.00, and thumbnails and filmstrips come from Clipx's own thumbnail engine. The PNGs are direct captures, with no compositing or retouching.

“Coastal study,” its clip names, marks, and tags are demo data in a fresh temporary library. Video metadata is read from the media files. The user's library and preferences are isolated, and the Mac stayed locked with its security settings unchanged. The capture does not activate Spaces or Stage Manager, so native toolbar controls have their inactive-window appearance.

[capture.json](capture.json) records the source-file hashes, screenshot hashes, dimensions, and player state. All six footage files passed full video decoding with FFmpeg before capture. These images demonstrate the current UI; system click testing remains separate from this capture workflow.

## Footage credits

The imagery is used under the [Pexels License](https://www.pexels.com/license/), which permits use in websites, apps, and product promotion. The original videos are downloaded locally and are not included in this repository. Their creators retain their rights; these demo screenshots do not imply endorsement.

| Demo source | Creator and original footage |
| --- | --- |
| Headland pass | [Xabi Oregi — Drone Footage of a Mountain Cliff Coast](https://www.pexels.com/video/drone-footage-of-a-mountain-cliff-coast-5619693/) |
| Coastal ridge | [Logan Voss — Aerial View of Malibu Cliffs and Ocean](https://www.pexels.com/video/aerial-view-of-malibu-cliffs-and-ocean-30670672/) |
| Green coastline | [NGUYỄN THÀNH NHƠN — Aerial View of Coastal Cliffs and Ocean Waves](https://www.pexels.com/video/aerial-view-of-coastal-cliffs-and-ocean-waves-32120722/) |
| Lighthouse pass | [Mario Spencer — Scenic Aerial View of Coastal Lighthouse and Beach](https://www.pexels.com/video/scenic-aerial-view-of-coastal-lighthouse-and-beach-39932380/) |
| Ocean at dusk | [Dmitriy Strukov — Drone Footage of a Ocean and Rocks](https://www.pexels.com/video/drone-footage-of-a-ocean-and-rocks-6234854/) |
| Shore break | [Mario Krimer — Dynamic Ocean Waves Crashing on Rocky Shore](https://www.pexels.com/video/dynamic-ocean-waves-crashing-on-rocky-shore-32792492/) |

## Recreate the shots

Use a fresh isolated Direct Debug build and its matching package cache. The existing [verification script](../../Scripts/verify.sh) prepares that build and checks its production views without system click automation:

```sh
CLIPX_BUILD_ROOT="$PWD/build/ui-workspace" \
CLIPX_PACKAGES_DIR="$PWD/build/ui-workspace/Packages" \
  ./Scripts/verify.sh offscreen

python3 Scripts/capture-screenshots.py \
  --derived-data build/ui-workspace/Direct \
  --packages-dir build/ui-workspace/Packages \
  --media-dir build/readme-screenshots/media \
  --output build/readme-screenshots/candidates \
  --download
```

The runner requires existing Screen Recording permission and stops if it is absent; it does not request permission or change settings. Downloads are optional, resume through `.part` files, and must match the hashes in [footage.json](../../Scripts/Screenshots/footage.json). The runner rejects incomplete or changed inputs before opening its window.

Inspect both candidate PNGs at full size before copying them here. Check that the video and full filmstrip are visible, all six library thumbnails loaded, the window is complete, and no personal data is present. Refresh `capture.json` with the capture date, built source revision, and final PNG hashes when publishing a new set. Keep diagnostic render states in `docs/verification/` rather than adding them to the README gallery.

Add `--review` to also capture the Notes and Export panels, plus Details and Export at a 900-point window width. These extra states support visual review; the main README remains a two-image gallery. The shared styling rules are recorded in [Native UI conventions](../UI.md).
