# Distribution verification — November 13, 2026

Public distribution was approved. The user chose to keep the Mac locked and leave its security settings unchanged. Verification was limited to command-line builds, generated media, signatures and anonymous HTTP downloads; the user's installed Clipx and real library were not used.

| Check | Result and boundary |
| --- | --- |
| Portable FFmpeg | FFmpeg 9.0.2 plus pinned x264 compiled into a 50.3 MiB universal helper. Both Mach-O slices target macOS 14 and link only system libraries. Exact source archives, build instructions, metadata and license notices are retained. |
| Real exports | Six software-encoded presets and one VideoToolbox export passed on Apple Silicon. The fixture calls production `FFmpegBackend.buildArguments`, trims source seconds 1–3, rotates 90°, retimes to 2×, crops/scales, normalizes audio and encodes H.264/AAC. Independent ffprobe checks confirm dimensions, frame counts, Rec.709 metadata and one-second audio/video duration. Homebrew is excluded from the encoder's environment. |
| Intel execution | Two cases explicitly skipped: this host rejects even `arch -x86_64 /usr/bin/true` because Rosetta is unavailable. Intel compilation and dependency checks passed; execution did not. Rosetta was not installed. |
| Clipx Release app | Universal Direct Release build passed with signing disabled. Bundled FFmpeg matches its source manifest; the built app has the configured public feed/key and version/build values. |
| Public update hosting | Public repository `caezium/clipx-releases` created; signed empty feed downloaded anonymously over HTTPS and verified against Clipx's update key. No app release exists. |
| Sparkle archive generation | A local ZIP of the unsigned Release app was processed by Sparkle's actual `generate_appcast`. Version, minimum OS, byte length, feed signature and archive signature passed. This local fixture was never published and does not prove Apple signing or update installation. |
| Failure checks | Modifying the signed feed caused verification to fail. Ad-hoc signing and packaging without Developer ID credentials were rejected before any submission/publication. |
| Native test startup | The unchanged one-test probe timed out after 20 seconds while the screen was locked. Unlocking remains an untested hypothesis for that stall. The separate native UI test's automation authorization failure remains open. |
| Apple signing/notarization | Blocked: no valid Developer ID Application certificate/private key is installed. Scripts implement nested signing, notary submission, stapling, Gatekeeper validation and publication, but those stages have not completed against Apple's service. |

The headless media/feed run is `PASS_WITH_SKIPS`: 10 checks passed, 2 Intel runtime cases skipped, zero failures in that final run. The separate app preflight and local Sparkle archive checks also passed. This is not a claim that the complete native regression suite or release installation workflow passed.

The first portable link attempt failed on missing system iconv symbols; explicitly linking system libiconv resolved it. Objective-C cross-compile flags target the selected slice. The first app preflight used an unsupported multi-architecture `lipo` argument order; checking each architecture separately resolved that verification error, and the build entry point then completed successfully.

Reproduce with [the distribution guide](../../DISTRIBUTION.md). Build products and full logs remain under `build/ffmpeg`, `build/release/app` and `build/release/evidence`. These directories are ignored by Git. This folder preserves result JSON, source manifests, dependency/minimum-OS reports, export arguments, independent media probes, the fetched public feed and concise logs.

Remaining work: supply Apple signing/notarization credentials; test a signed app launch and real update installation; finish native click/full-suite verification in an authorized unlocked session; run Intel exports on Intel hardware or an existing Rosetta installation. The previously noted physical-phone, Final Cut Pro import and signed MAS checks remain separate gaps.
