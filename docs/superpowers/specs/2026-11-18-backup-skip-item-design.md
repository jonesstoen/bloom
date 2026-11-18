# Backup: skip an item (short design)

Approved by the owner 2026-11-18.

## Why
Some items can never be backed up (IMG_6458: Photos itself can't load the iCloud original,
PHPhotosErrorDomain -1). Today it stays under Problems forever and the header never says
"Everything Is Backed Up". The owner wants to tell Bloom to stop trying.

## Goals
- On a problem row: "Skip" (context menu + swipe action), next to Try Again.
- Skipped items are not read, hashed, checked or uploaded, in foreground or background runs.
- Overview gets a "Skipped" count row leading to a list with "Include Again" per item (undo).
- Header leaves skipped items out of "x of y" and out of problems, like Deleted on Server.

## Non-goals / anti-goals
- No skip for queued/pending items, no bulk "Skip All".
- Skipping must never lose or change other entries, and must not upload anything.

## Approach
Considered: (A) a new `BackupState.skipped` case, (B) a separate set of skipped asset IDs in the
index file. Picked B: the scanner rewrites entry state on every change, so a state would be lost;
a separate set survives rescans and edits, and Include Again just removes the ID (the next scan
treats the item normally, its existing entry/checksums untouched). The set is per account, stored in
`index.json` (decoded leniently; absent in older files).

## Decided
- Skip lasts until Include Again, also when the photo is edited.
- Counts get `skipped`; `total = backedUp + pending + deletedOnServer + failed + skipped`.
- All UI text through `tr()` with Norwegian (Hopp over, Hoppet over, Ta med igjen).

## Left to the builder
Exact wiring in scanner/uploader/survey, list layout (reuse the problem-row look), tests.
