# Remote browser

Paired browsers browse and play footage, mark source-time clips, and recover from proxy failures without stale requests changing the active screen.

## Sub-features

- Source/clip/search continuation and saved-clip playback.
- Phone modal close/retry, focus and responsive layouts.
- Request ownership, sprite disposal and original-time marks at saved speed.
- Strict parsing, auth, streamed byte ranges and owned shutdown.

## How to get to it (user POV)

- Enable Remote in Settings, open its local address, and pair using the displayed PIN.
- Browse Sources or Clips, load more results, search, and play a source/clip.
- Mark In/Out, save, close the player, or retry failed preparation.

## Driving it with Chromium and loopback fixtures

Preconditions: follow the Playwright setup in the parent skill; never connect the fixture to a live Clipx instance.

- Run `Scripts/verify.sh browser`. Require JSON `status: PASS`; inspect the phone and desktop PNGs in its printed artifact directory. Ten workflows cover pagination, stale requests, source-time marks, close/retry and 320–1280px layouts.
- Run `python3 Tests/ClipxCoreTests/ServerHTTPRegression.py` to verify actual parser/listener/stream shutdown over an ephemeral loopback port.
- Run `Scripts/verify.sh core` for isolated route, proxy rotation/retry, delayed cancellation cleanup, and security regressions.

## Gotchas

Browser requests are mocked at the production HTTP boundary; the loopback suite separately exercises the real listener. No claim of a physical phone/Wi-Fi test or signed MAS network entitlement enforcement is implied. Chromium may need the normal execution sandbox escalation for macOS process services.
