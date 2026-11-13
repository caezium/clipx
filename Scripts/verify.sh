#!/usr/bin/env bash
# Repeatable verification with temporary build products and an isolated app ID.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-core}"
build_root="${CLIPX_BUILD_ROOT:-/tmp/clipx-verification-build}"
packages="${CLIPX_PACKAGES_DIR:-$build_root/Packages}"
mkdir -p "$build_root/evidence"
case "$mode" in
    doctor)
        xcodebuild -version
        xcodegen --version
        test -x Helpers/ffmpeg
        printf 'Build root: %s\nPackage cache: %s\n' "$build_root" "$packages"
        if [ -f /tmp/clipx-native-ui-evidence/manifest.json ]; then
            cat /tmp/clipx-native-ui-evidence/manifest.json
        fi
        exit 0 ;;
    core) scheme=Clipx-Direct; variant=Direct; only=(test) ;;
    mas) scheme=Clipx-MAS; variant=MAS; only=(test) ;;
    native) scheme=Clipx-Direct; variant=Direct; only=(-only-testing:ClipxCoreTests/NativeUIRenderTests test) ;;
    ui) scheme=Clipx-UI; variant=Direct; only=(test) ;;
    browser)
        node Tests/ClipxCoreTests/ServerBrowserRegression.mjs
        exit 0 ;;
    *) echo 'Usage: Scripts/verify.sh doctor|core|mas|native|ui|browser' >&2; exit 2 ;;
esac
xcodegen generate
signing=(CODE_SIGNING_ALLOWED=NO)
if [ "$mode" = ui ]; then
    # The ad-hoc XCTest runner must load a test bundle without a Team ID.
    # This override is confined to the disposable Debug verification build.
    signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=YES ENABLE_HARDENED_RUNTIME=NO)
fi
log="$build_root/evidence/$mode.log"
if xcodebuild -project Clipx.xcodeproj -scheme "$scheme" -configuration Debug \
    -derivedDataPath "$build_root/$variant" -clonedSourcePackagesDirPath "$packages" -skipPackageUpdates \
    -destination "platform=macOS,arch=$(uname -m)" \
    CLIPX_BUNDLE_IDENTIFIER=com.clipx.Clipx.Verification "${signing[@]}" \
    "${only[@]}" > "$log" 2>&1; then
    printf 'Passed %s verification. Log: %s\n' "$mode" "$log"
else
    tail -60 "$log" >&2
    printf 'Failed %s verification. Full log: %s\n' "$mode" "$log" >&2
    exit 1
fi
