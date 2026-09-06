# Clipx verification map

Use isolated test app bundles and fixture media only. Run `Scripts/verify.sh doctor` before the selected recipe. The unit schemes isolate preferences, database, and caches; the browser fixture mocks every HTTP request and the server fixture listens only on loopback.

- [Library and editing](library.md): indexing, search/filter views, saved metadata, Undo.
- [Native UI and playback](native.md): screen layout, player state, capture, settings, optional click workflow.
- [Exports and bridges](exports.md): source-time renders, cancellation, sidecars, FCPXML, resumable review transfers.
- [Remote](remote.md): browser paging, playback, auth/parser/ranges, proxy lifecycle.

Record the entry point and actual proof. A view render does not prove a click, a fake review client does not prove a live service, and an unsigned App Store build does not prove sandboxed distribution. Preserve explicit skips and external prerequisites.
