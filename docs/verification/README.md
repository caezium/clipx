# Repair verification evidence

These artifacts use synthetic footage and disposable libraries. The original snapshot is `c700be3`; [REPAIR_NOTES.md](../../REPAIR_NOTES.md) describes the changes and remaining limits. [results.json](results.json) records the passing suite counts, exact commands, and original log hashes. Build products and full `.xcresult` bundles remain in `/tmp/clipx-repair-build`.

## Native screens

The test renders 29 actual SwiftUI/AppKit states. [native-layout.txt](native-layout.txt) preserves the requested/actual dimensions and capture method for every state. The owned-window capture failed on this machine, so the PNGs are AppKit bitmap fallbacks. They omit some system materials, toolbar/window chrome, and AVPlayerLayer; white sidebar panels and black video areas in the combined-window images are capture artifacts. The standalone sidebar image shows that view's actual content.

- [Sidebar](native-sidebar.png) and [onboarding ready step](native-onboarding-ready.png).
- [Player with inspector at 900 points](native-player-900.png) and [capture at 900 points](native-capture-900.png).
- [Project at 900 points](native-project-900.png) and [multiple selection](native-multiple-selection.png).
- [Keyboard shortcut help](native-shortcuts.png) and [Remote settings](native-remote-settings.png).

These images support the layout review within those capture limits. The separate native click test is checked in but did not run successfully: its runner stalled before app code, with macOS developer mode disabled. No security settings were changed.

## Remote browser

Chromium drives the production embedded browser UI with all HTTP requests fulfilled by synthetic fixtures. The ten passing workflows cover saved-clip playback, continuation, search/detail/save ownership, reachable phone close on error, polling cancellation, source-time marks at permanent speed, sprite retry/disposal, and 320–1280px layout. The red thumbnails in the desktop capture are the generated color fixture.

- [Phone clips](remote-phone-clips.png).
- [Phone preparation failure with reachable Close and Retry](remote-phone-error.png).
- [Desktop source library](remote-desktop.png).

The separate checked-in loopback fixture exercises the real listener/parser and confirms byte-for-byte full/suffix/large-range streaming and owned connection/handler shutdown. Browser screenshots do not establish a physical phone or Wi-Fi test.

Use [Scripts/verify.sh](../../Scripts/verify.sh) and the [project verification skill](../../.agents/skills/verify-clipx/SKILL.md) to regenerate the evidence. No live Stint requests, Final Cut import, signed MAS runtime, or release publication are included in these results.
