# MacBook signing handoff

The MacBook keeps the Developer ID private key. The Mac Studio keeps its unsigned build and Sparkle private key, then notarizes and finishes packaging after the signed app returns. This handoff uses an unpublished GitHub draft; it does not update the public appcast or publish an application release.

Required on the MacBook: the existing Developer ID identity `2B8D05A2470C0AC720996E5425E48B8FC4828953` for team `YGSM2722TZ`, Apple's command-line tools, Python 3, and GitHub CLI access to `caezium/clipx-releases`. No private key needs to be exported. If GitHub authentication or macOS key access is unavailable, report the blocker through the agent's normal secure approval flow; leave Keychain access controls and system security settings unchanged.

## Download and verify

```sh
CLIPX_SIGNING_DIR="$(mktemp -d /tmp/clipx-signing.XXXXXX)"
export CLIPX_SIGNING_DIR
gh release download clipx-signing-0.1.0-1-22c3a9a \
  --repo caezium/clipx-releases --dir "$CLIPX_SIGNING_DIR"

python3 - <<'PY'
import hashlib, json, os
from pathlib import Path
root = Path(os.environ['CLIPX_SIGNING_DIR'])
manifest = json.loads((root / 'handoff.json').read_text())
assert manifest['apple_team_id'] == 'YGSM2722TZ'
assert manifest['signing_identity_sha1'] == '2B8D05A2470C0AC720996E5425E48B8FC4828953'
for name, expected in manifest['assets'].items():
    assert Path(name).name == name
    actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
    assert actual == expected, f'Checksum mismatch: {name}'
print('Handoff checksums verified')
PY

ditto -x -k "$CLIPX_SIGNING_DIR/SigningTools.zip" "$CLIPX_SIGNING_DIR/tools"
ditto -x -k "$CLIPX_SIGNING_DIR/Clipx-0.1.0-1-unsigned.zip" "$CLIPX_SIGNING_DIR/original"
ditto "$CLIPX_SIGNING_DIR/original/Clipx.app" "$CLIPX_SIGNING_DIR/signing/Clipx.app"
```

## Sign and check

```sh
python3 "$CLIPX_SIGNING_DIR/tools/Scripts/release.py" sign \
  --app "$CLIPX_SIGNING_DIR/signing/Clipx.app" \
  --identity 2B8D05A2470C0AC720996E5425E48B8FC4828953

python3 "$CLIPX_SIGNING_DIR/tools/Scripts/release.py" verify-signed \
  --app "$CLIPX_SIGNING_DIR/signing/Clipx.app" \
  --unsigned-reference "$CLIPX_SIGNING_DIR/original/Clipx.app"
```

Both commands must succeed. The second checks the Apple trust chain and team for Clipx, FFmpeg and Sparkle's nested code, then compares their signature-free contents against the original build. It never changes either input app. If a normal key-use authorization dialog appears, report it to the user; do not bypass it or broaden access controls.

## Return to the Studio

```sh
ditto -c -k --keepParent "$CLIPX_SIGNING_DIR/signing/Clipx.app" \
  "$CLIPX_SIGNING_DIR/Clipx-0.1.0-1-signed.zip"

python3 - <<'PY'
import hashlib, json, os
from pathlib import Path
root = Path(os.environ['CLIPX_SIGNING_DIR'])
name = 'Clipx-0.1.0-1-signed.zip'
receipt = {'archive': name, 'sha256': hashlib.sha256((root / name).read_bytes()).hexdigest(),
           'apple_team_id': 'YGSM2722TZ',
           'selected_identity_sha1': '2B8D05A2470C0AC720996E5425E48B8FC4828953',
           'unsigned_archive_sha256': json.loads((root / 'handoff.json').read_text())['assets']['Clipx-0.1.0-1-unsigned.zip'],
           'verification': 'release.py verify-signed succeeded', 'notarized': False}
(root / 'signing-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
PY

gh release upload clipx-signing-0.1.0-1-22c3a9a --repo caezium/clipx-releases \
  "$CLIPX_SIGNING_DIR/Clipx-0.1.0-1-signed.zip" \
  "$CLIPX_SIGNING_DIR/signing-receipt.json"
```

Leave the release as a draft. Do not overwrite existing assets, notarize, alter the update feed, or publish this build. Return the signed archive's SHA-256 and whether both verification commands passed. The Studio will download the returned archive, independently verify it against its retained original, then handle notarization and final packaging.
