# Library and editing

Footage remains linked to saved clips across scans, folder moves, metadata edits, and Undo.

## Sub-features

- Recovery preserves original files and validates backups before replacement.
- Scanning restores availability, reconciles removals, and retries files still being copied.
- Search and filters agree across source/clip views and include tags.
- Metadata drafts persist on selection change; Undo restores complete clip identity.

## How to get to it (user POV)

- Add a folder through onboarding, File → Add Folder, Settings → Library, or a window drop.
- Use Calendar, Grid, List, or Light Table; search from the toolbar or Command-F.
- Select a clip for inspector edits; delete from a context menu and use the Undo toast.

## Driving it with XCTest

Preconditions: `Scripts/verify.sh doctor` passes.

- Run `Scripts/verify.sh core`. CoreRepairTests uses disposable databases/files to verify recovery, case-sensitive folder membership, alias paths, retries, and cancellation.
- NativeMutationRegressionTests verifies atomic capture, full delete/restore, drafts and generated-note merges; NativeSearchRegressionTests verifies tags, dates, scope and continuation.
- Run `Scripts/verify.sh native` and inspect Calendar/Grid/List/Light Table, empty results, scoped project and inspector captures.
- `Scripts/verify.sh ui` is the separate click workflow for folder picking and persisted inspector editing, subject to the machine automation prerequisite.

## Gotchas

The ordinary user's library is never a test fixture. UI rendering seeds fixtures directly and does not establish every folder-picker/drop entry. macOS path aliases and case-sensitive folders require preserving stored identity, not just the apparent filename.
