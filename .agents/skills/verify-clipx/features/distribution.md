# Distribution verification

Source entry points are `Scripts/release.py`, `Scripts/verify-release.py`, `Tests/Release/ExportArguments.swift`, and `Configs/Distribution.json`. The [distribution guide](../../../../docs/DISTRIBUTION.md) contains exact commands and credential setup.

Run `Scripts/verify.sh doctor` before a fresh drive. Use generated media and retained build artifacts; never launch the installed app or use the real library. Resolve the pinned Sparkle tools and set `SPARKLE_BIN` to their `bin` directory. Keep reusable tools under `build/release/Packages`; temporary caches can disappear between sessions.

- `verify-release.py --app ... --unsigned-reference ...` validates the signed app against its original build, then executes its bundled FFmpeg with production export arguments. Verify the encoder path in `results.json`, real media probes, and explicit architecture skips. A signed helper has a different raw hash from its unsigned source manifest; compare the signature-free payload instead of weakening the provenance check.
- `release.py rehearse --app ... --unsigned-reference ... --notes ... --directory ...` uses the existing Sparkle key to generate and validate a local update ZIP, feed, corresponding sources, and checksums. Read `rehearsal.json`; `status: PASS` must coexist with `publishable: false`. No Apple submission or GitHub mutation occurs.
- `python3 -m unittest discover -s Tests/Release -p 'test_*.py' -v` checks payload changes, signing rejection, inconsistent update metadata, increasing build numbers, and refusal to verify or publish rehearsal output. Metadata unit fixtures stub cryptography; the real rehearsal and signed-feed checks provide cryptographic evidence.

Final `package` and `publish` retain Developer ID, notarization, stapling and Gatekeeper requirements. Never call a rehearsal a distributable package or an installed-update test. No security settings, Keychain access controls, lock state, or Rosetta installation should be changed by this workflow. Preserve failed-run logs and remove only temporary fixtures owned by the run.
