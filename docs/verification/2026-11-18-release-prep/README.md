# Credential-free release preparation — November 18, 2026

The user deferred Apple notarization credentials. This run kept the signed app, original build, Mac lock state, security settings, and public update feed unchanged. No Apple submission, app publication, or native app launch occurred.

The headless release checker previously executed the development FFmpeg even when an app was supplied, then compared the signed helper's raw hash to its unsigned manifest. It now verifies a signed app against `--unsigned-reference` and runs that app's actual bundled encoder. Its report records both the executable path and signed/unsigned hashes; ordinary unsigned-build checks remain supported.

## Results

| Check | Result |
| --- | --- |
| Signed app provenance | Apple trust, team `YGSM2722TZ`, nested signatures, and original code/resources verified before export. |
| Signed encoder exports | All six software presets plus a VideoToolbox 1080p export passed on Apple Silicon. Independent media probes checked dimensions, frame counts, color metadata, and one-second audio/video duration. Encoder subprocesses had no Homebrew paths. |
| Overall headless checks | 11 passed, 2 skipped. Intel software/hardware exports were skipped because this host cannot execute x86_64 and Rosetta was not installed. |
| Actual local packaging | The shared final-release code generated a signed update ZIP/feed, HTML release notes, corresponding FFmpeg sources and checksums. The extracted app still matched the original build and retained valid Developer ID signatures. |
| Cryptographic failure checks | Same-length changes to the candidate feed and ZIP were rejected by the actual Sparkle verifier. This exercises signature rejection rather than only a length mismatch. |
| Publication refusal | Actual CLI invocations of `verify` and `publish` both rejected the rehearsal before accessing credentials or publishing. The rehearsal is explicitly marked `publishable: false`, with no `release.json`. |
| Metadata and signing regressions | All 18 tests passed, covering payload changes, ad-hoc rejection, asset integrity, download URLs/lengths, required sources, increasing build numbers, and rehearsal refusal. Metadata unit fixtures stub cryptography; the real rehearsal supplies the cryptographic proof. |
| Public hosting | The anonymous public feed matched its pre-rehearsal SHA-256 and still contained no application update. |

The previous temporary Sparkle tool cache had disappeared. Sparkle 2.9.6 was restored under `build/release/Packages/artifacts/sparkle/Sparkle/` only after its archive matched the checksum in the upstream pinned `Package.swift`. The public update key still matched Clipx's configuration, and the existing Keychain item supported signing without any access-control change.

## Retained evidence and reproduction

The [distribution guide](../../DISTRIBUTION.md) contains the corrected signed-app verification and `release.py rehearse` commands. The [prepared release notes](../../releases/0.1.0-1.md) are ready for final packaging after notarization credentials are configured.

This folder retains the media report and probes, unit-test log, local rehearsal manifest/feed/checksums, tool provenance, and failure-check results. The raw media and full local archives remain under `build/release/evidence-2026-11-18-signed/` and `build/release/rehearsal-2026-11-18/`. Rehearsal archives are not public downloads and cannot be promoted directly: notarization/stapling must happen first, followed by regeneration of archive and feed signatures.

Apple notarization, ticket stapling, Gatekeeper acceptance, signed app launch, actual update installation, and native click/full-suite verification remain incomplete. Intel execution, Final Cut Pro import, a physical-phone session, and signed Mac App Store behavior retain their earlier limits. Temporary tamper fixtures were removed after recording their results; no long-running app or server was started.
