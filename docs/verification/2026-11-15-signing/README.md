# Signing handoff verification — November 15, 2026

The MacBook agent reported a valid Developer ID Application certificate and matching private key for Wenzhang Zhang, team `YGSM2722TZ`, fingerprint `2B8D05A2470C0AC720996E5425E48B8FC4828953`, expiring August 1, 2031. This is a report from the MacBook; the Studio has not yet verified a real signature made with that identity. No accessible notarization profile was reported.

Six headless tests passed. Real universal Mach-O fixtures establish that signing-only changes compare equal while changed executable bytes, resources and symlinks are detected. A positive identifier requirement passes; the configured Developer ID requirement compiles and rejects an ad-hoc signature with codesign exit 3. This fixes an earlier bug where a missing `=` caused codesign to interpret an inline requirement as a filename.

A disposable copy of the actual universal Clipx build passed nested ad-hoc signing and deep signature integrity checks. The Developer ID gate rejected it, and its code/resource payload still matched the original app. Signature normalization operates only on temporary copies. Fat-container layout and the `__LINKEDIT` virtual allocation reserved for signatures are excluded; mapped bytes and remaining load commands are compared.

These checks do not prove Developer ID signing, notarization, Gatekeeper acceptance or update installation. The app's private signing key remains on the MacBook, and the Sparkle key remains on the Studio. The original unsigned Release app is retained for verification when the signed archive returns. No native click tests or security-setting changes were performed.
