# Returned Developer ID build — November 15, 2026

The MacBook returned `Clipx-0.1.0-1-signed.zip` with SHA-256 `77f996082332b9416dc9e8d9cb9e7e2f303202bc982dfae7579054216c2764b4`. The Studio downloaded the archive and receipt from the unpublished signing draft, checked both hashes, and independently ran `release.py verify-signed` against its retained original build.

Verification passed for Apple's trust chain, Developer ID Application team `YGSM2722TZ`, and every nested signing target. The app has hardened runtime and a secure timestamp. The signature-free code, resources, permissions, and symlinks match the original universal Release app. The MacBook retained the private signing key; the Studio did not import it or change security settings.

The signed FFmpeg helper completed two real 1080p exports on Apple Silicon, using software H.264 and VideoToolbox hardware H.264 with production export arguments. Independent ffprobe checks confirmed 1920×1080 video, 30 frames, H.264/AAC, Rec.709 metadata, and one-second audio/video duration. Homebrew paths were excluded from the encoder's environment. The earlier six-preset run is recorded in the [November 13 release checks](../2026-11-13-release/README.md).

Apple notarization remains pending: the Studio has no `Clipx` notarization credential profile. No signed app launch, native click workflow, Intel runtime check, or update installation was performed. The signing transfer remains a draft and the public update feed remains unchanged.

The original build is from application commit `22c3a9a4f96b89f2cf0b5558c586a1bbb295b9cb`; signing tools are from `b912e7ea37b359cde29f5529b972a6bd18466043`. The full returned app and archive are retained under `build/release/macbook-return-0.1.0-1/`. This folder preserves the MacBook receipt, independent Studio verification, signature details, export arguments, and media probes.
