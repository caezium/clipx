# Native UI and playback

The player keeps transport state, source-time marks and clip edits consistent while the interface remains usable at narrow widths.

## Sub-features

- Rapid source switching and EOF replay preserve player/observer ownership.
- Narrow player, capture, inspector, project and Light Table layouts stay usable.
- Details, Notes, and Export share one task panel; pending notes survive tab changes and resizing keeps the same player.
- Onboarding, settings, palette, shortcuts and errors expose clear actions.

## How to get to it (user POV)

- Open footage or a saved clip from the library or command palette.
- Mark In/Out, choose Save Clip, and name/tag the capture.
- Open the clip panel with the toolbar toggle or ⌥⌘I, then choose Details, Notes, or Export. Export also opens directly from the toolbar. The source sidebar can be toggled while cutting and its library visibility is restored on return.
- Switch view modes, open Settings, or use Command-K.

## Driving it with XCTest and native rendering

Preconditions: isolated test schemes; a working AVFoundation environment.

- Run `Scripts/verify.sh core` for real player lifecycle, missing-source, clamped-seek and capture/store regressions.
- Run `Scripts/verify.sh native`. Inspect the PNG and geometry/capture-method text for every state under `/tmp/clipx-native-ui-evidence`, particularly the 900-point player/inspector and project.
- With a locked screen, run `Scripts/verify.sh offscreen` or `offscreen-mas` sequentially. The CLI runs 20 existing native regression tests and renders 33 windows without showing them. The renderer inserts text into the actual NSTextView, changes tabs before the debounce expires, checks SQLite and the restored editor, then crosses the layout breakpoint and checks AVPlayer identity. Require both the zero-failure result and `CLIPX_WORKSPACE_INTERACTION=PASS`.
- Run `Scripts/verify.sh ui` only when native automation can launch. Its import/mark/save/edit flow retains screenshots and verifies the final clip name/range directly through SQLite.

## Gotchas

On Xcode 27.2 the ad-hoc UI runner required hardened runtime to be disabled for the temporary Debug test build; `verify.sh ui` supplies that override. It then timed out enabling Automation Mode, before any test ran. `automationmodetool` reports whether UI automation requires authentication; `DevToolsSecurity -status` is a separate developer-policy check, not proof of the cause. Machine security changes require explicit authorization. Offscreen mode uses a separate CLI and changes no machine policy. Native bitmap capture cannot composite every system surface or video layer; the text files identify the capture method. Do not mistake missing material/black video capture artifacts for product colors, or claim system click coverage from in-process rendering and editor checks.
