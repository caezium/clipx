# Clipx repairs and UI pass — 2026-09-06

For fresh checks, see the [integration follow-up](docs/verification/2026-11-13/README.md), [distribution follow-up](docs/verification/2026-11-13-release/README.md), and [returned signed build](docs/verification/2026-11-15-signed-build/README.md). Full Apple DTD validation, a real local Stint round trip, portable FFmpeg exports and a universal Release build now pass. Developer ID signing, independent payload verification, and signed-helper exports also pass. Public update hosting and an Ed25519 key are configured. Apple notarization credentials, native click authorization, and subsequent full-suite initialization remain open; the user chose to keep the Mac locked. The counts below describe the original repair session.

The reviewed baseline is preserved in `c700be3` (`Snapshot before reliability and UI improvements`). The repairs address all 35 primary findings in [CODE_REVIEW.md](CODE_REVIEW.md), plus the smaller behavior defects listed there. The existing SwiftUI/GRDB architecture and dark visual identity remain the basis of the app. The future features in `plans/ai-features.md` are still planned work.

## Storage, indexing, and builds

| Finding | Resulting behavior | Main regression evidence |
| --- | --- | --- |
| C01 | Database recovery runs only for corruption. Locks, permissions, and migration failures propagate without replacing a healthy library. Original files are archived before replacement. | `CoreRepairTests`: lock, migration, recovery |
| C02 | A backup is validated and checkpointed as a separate candidate. An unusable backup is preserved, and a fresh fallback can open. | `CoreRepairTests`: invalid main/backup, valid restore |
| C03 | Unchanged files regain online status; a completed scan also reconciles missing files. | `CoreRepairTests`: real indexer scan |
| C04 | A resolved folder move updates the folder and descendant source paths transactionally while preserving IDs. Collisions roll back. | `CoreRepairTests`: relink, collision, case-sensitive paths |
| C05 | The watcher handles directory/root changes and dropped-event flags through reconciliation. Owned generations stop obsolete scans and retries. | `CoreRepairTests`: event flags, deferred retry, cancellation |
| C06 | FTS health checks compare external content with the index and rebuild on desynchronization. | `NativeSearchRegressionTests`: actual damaged FTS index |
| C07 | Direct tests have `DIRECT_BUILD`; a separate MAS test target exercises the AVFoundation variant. | Both test schemes in `project.yml` |
| C08 | Every Direct build copies FFmpeg into the app. Release builds require matching architectures and system-library-only dependencies; the download script requires a verified SHA-256. | Bundled Debug helper; Release preflight correctly rejects Homebrew dependencies |
| C09 | The MAS target declares client/server network entitlements and local-network usage text. | Configuration inspection and MAS build; signed sandbox runtime remains unverified |

Startup database work runs off the main actor. Folder availability, successful imports, and scan outcomes now reflect actual results. The scanner retries files still being copied, retains the chosen spelling of macOS alias paths, and avoids changing terminal scan state after cancellation. Metadata/date parsing and legacy duration arithmetic reject invalid or overflowing values.

## Native editing and playback

| Finding | Resulting behavior | Main regression evidence |
| --- | --- | --- |
| N01 | Load generations reject obsolete player work, and time observers remain paired with their owning AVPlayer. | `NativePlayerLifecycleTests`: real rapid source switching |
| N02 | Settings validates ports; bootstrap safely recovers invalid stored values and reports listener failures. | `CoreRepairTests`: invalid persisted ports |
| N03 | Inspector names/notes flush on navigation, retain failed drafts, and merge concurrent generated review updates. | `NativeMutationRegressionTests`: retained drafts and review merges |
| N04 | Delete/Undo restores the original clip ID, metadata, groups, tags, review linkage, and export relationships. Capture metadata is committed atomically. | `NativeMutationRegressionTests`: full round trip and atomic save |
| N05 | Structured updates distinguish an unchanged field from an explicit clear. | `NativeMutationRegressionTests`: clearing attributes |
| N06 | Project exports receive explicit clip IDs and no longer depend on an asynchronously changed global selection. | Explicit-ID export entry points and native query tests |
| N07 | Calendar renders matching saved clips; List renders sources as well as clips. | Search regressions and native view renders |
| N08 | Query semantics distinguish import time, source recording time, and clip creation time and apply availability consistently. | `NativeSearchRegressionTests`: source/clip filters |
| N09 | EOF updates transport state; Play can restart from the beginning, with guarded seek/load completion. | `NativePlayerLifecycleTests`: EOF/replay and missing media |
| N10 | Tag, note, and metadata mutations publish library changes; text search includes tag names. | Native search/mutation regressions |

Project and collection scope no longer accidentally intersect. Calendar/Grid/List and Light Table support continuation; a 1,205-clip regression verifies results past the old limits. Async queries keep their original inputs and reject stale completion. Existing results remain visible during refresh. Expired Undo toasts release their closures, same-source palette selection seeks to the chosen clip, and inert preferences have been removed or made truthful.

## Exports, review bridges, and Remote

| Finding | Resulting behavior | Main regression evidence |
| --- | --- | --- |
| B01 | Malformed HTTP parsing reaches terminal rejection without pre-authentication arithmetic traps. | Request tests and real loopback HTTP fixture |
| B02 | Both render backends use source-time cuts and correct speed-adjusted output duration. | Actual audio/video renders at 0.5×, 1×, and 2× |
| B03 | FCPXML uses the supported 1.10 document structure, media representations, and actual audio metadata. | XML structure tests; full DTD/import remains manual |
| B04 | Sidecars use clip identity in their filename and verify metadata before merging, preserving renamed and user-authored notes. | `BridgeTests`: collisions and note preservation |
| B05 | Cancellation latches before work begins; cancelled workers drain before queue restart and cannot publish late progress. | Pipeline/media cancellation regressions |
| B06 | Generated review comments have explicit boundaries and preserve the complete user-written notes around them. | Review-note merge tests |
| B07 | The shared save boundary validates source-time ranges; legacy duration reads remain overflow-safe. | Marker, mutation, and core range tests |
| B08 | Checked byte ranges support suffixes and stream responses in 64 KiB chunks rather than allocating the entire range. | Security tests and byte-for-byte real HTTP fixture |
| B09 | Menu export, drag export, and Stint share one validated render request including rotation and speed. | Shared renderer and real media regressions |
| B10 | FCPXML recovers nearest frame endpoints and uses one sequence timebase for mixed frame rates. | `FCPXMLWriterTests`: one-frame and mixed-FPS cases |
| B11 | Export progress observes the live queue and exposes accessible progress/cancellation state. | Export queue tests and native render |
| B12 | Every ordinary completion writes terminal history, including cancellation/failure, and successful history records actual rendered duration. | `ExportPipelineTests`: terminal status and retry history |
| B13 | Stint stores project identity and individual upload receipts before advancing. Retries reuse partial work and all temporary renders are owned and cleaned. | Controlled-client transfer/retry and multipart tests |
| B14 | Phone player close stays reachable during preparation/errors, and failures offer an explicit retry. | Chromium phone error/close workflow |
| B15 | Clearing browser search restores its prior pane; obsolete search/details/save requests cannot replace current state. | Chromium request ownership workflows |
| B16 | Remembered export/vault folders use durable scoped bookmarks and access leases. | `DestinationAccessTests`; signed sandbox runtime remains unverified |

Fresh independent review caught and fixed three additional ownership problems: failed rendering could delete a preexisting destination, interrupted history could delete a successful retry, and an old Stint comment response could overwrite newly linked review notes. Rendering now publishes exclusively from private staging directories. Comment refresh checks generation and current linkage inside the write transaction and publishes partially committed progress even if a later request fails.

Proxy generation has bounded concurrency/queue depth, cancellation, terminal errors, explicit retry, and disk cache eviction. Its staging directories prevent late AVFoundation cancellation output from reappearing. Remote rotation matches native playback; playback speed changes presentation while marks remain in source milliseconds. Browser pagination, sprite retry/blob disposal, IPv6 Host parsing, nested review comments, and empty comment refresh are covered. Actual HLG/BT.2020 fixture rendering exercises native conversion to Rec.709 before Direct encoding.

## UI and UX pass

The pass covers onboarding, all four library views, search/filter and project states, player/capture, inspector, settings, command palette, shortcuts, export progress, and the Remote browser. It improves the existing product rather than introducing a new visual system.

- The player and capture controls adapt to the available width. At a 900-point window with sidebar and inspector, transport, marks, and Save remain inside the content area.
- Project and Light Table headers stack their actions at narrow widths. Primary inspector work—name, rating, purpose, tags, notes, export—comes first; secondary attributes use disclosure. Multiple selection explains what can be edited and offers the selected export count.
- Onboarding has a visible step indicator, a scrolling body, stable footer actions, and a readable final shortcut guide. Settings, empty/missing/error states, accessible labels, and keyboard focus/close behavior are clearer.
- Remote retains its dark layout, adds touch-sized actions and native dialog focus behavior, and stays usable from 320 to 1,280 CSS pixels. Loading, unavailable media, retry, close, and save failure states are explicit.

The native harness renders 29 real SwiftUI/AppKit states with isolated footage and records requested/actual dimensions. This machine could not composite owned-window screenshots, so the native PNGs are labeled AppKit bitmap fallbacks: system materials and AVPlayerLayer may appear white/black. These artifacts establish layout within that limit; they are not proof of a complete native click workflow.

## Verification and remaining limits

Run the checked-in [verification script](Scripts/verify.sh) and [project verification skill](.agents/skills/verify-clipx/SKILL.md). The test app has a separate bundle identity, temporary library/preferences/cache, and disabled global hotkeys/updates. The user's running app and real library were not used as fixtures.

| Verification | 2026-09-06 result |
| --- | --- |
| Direct Debug regression suite | 186 tests passed, zero failures, including actual media rendering and 29 native screen states. |
| MAS Debug regression suite | 180 tests passed, zero failures, after the final native cleanup. Signing was disabled. |
| Remote browser | All 10 Chromium workflows passed; phone and desktop screenshots retained. |
| Real HTTP server | Loopback parser rejection, subsequent auth, full/suffix/large-range streaming, connection shutdown, and handler cancellation passed. |
| Native click workflow | Checked in, but not passed: XCUITest stalled before app code and `DevToolsSecurity -status` reports disabled developer mode. No machine security settings were changed. |
| Release helper preflight | Passed its rejection check: the current development FFmpeg depends on Homebrew libraries and cannot be distributed as a standalone helper. |

The build toolchain was Xcode 26.6 (17F113), Swift compiler 6.3.3, XcodeGen 2.45.4, and FFmpeg 8.1.2 on Apple Silicon. GRDB 6.29.3 and Sparkle 2.9.6 are pinned in the build manifest. The project remains in Swift 5 language mode; this work does not claim a completed Swift 6 strict-concurrency migration.

At the original repair baseline, signing/notarization, a portable FFmpeg binary and Sparkle feed/key values were missing. The follow-ups above record the subsequent integration and distribution work. Signed MAS filesystem/network enforcement, a physical phone session and Final Cut Pro import remain unverified. Variable-frame-rate stepping still follows nominal frame timing. No application release has been published.

Full logs and `.xcresult` bundles are under `/tmp/clipx-repair-build`, and original media probes are under `/tmp/clipx-repair-media-probes`. Selected durable artifacts are in [docs/verification](docs/verification/README.md); temporary paths may be cleaned by macOS. The decision log is [.audit/repair.tsv](.audit/repair.tsv).
