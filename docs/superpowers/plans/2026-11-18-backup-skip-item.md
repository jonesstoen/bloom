# Backup Skip Item Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the owner skip a backup item that keeps failing; skipped items are never read/uploaded, are counted apart, and can be included again.

**Architecture:** `BackupIndex` keeps a per-account `skipped: Set<String>` next to the selection in `index.json`. One new index method resolves "the selection minus skipped"; scanner, uploader and model use it instead of `selection().assetIDs(in:)`. `BackupCounts` gets `skipped`, added to `total` but kept out of the header's "x of y".

**Tech Stack:** Swift 6, Swift concurrency (actors), SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-18-backup-skip-item-design.md`

## Global Constraints

- All user-facing text via `tr("…")` with a Norwegian entry in `Sources/ImmichUI/Resources/nb.lproj/Localizable.strings`:
  "Skip" = "Hopp over"; "Skipped" = "Hoppet over"; "Include Again" = "Ta med igjen";
  "Nothing Skipped" = "Ingenting hoppet over";
  "Bloom doesn't read or upload these photos. Include one again to back it up." =
  "Bloom leser ikke og laster ikke opp disse bildene. Ta med et bilde igjen for å sikkerhetskopiere det.".
- Skipping never deletes or rewrites a `BackupEntry`; Include Again only removes the ID from the set.
- Old `index.json` without `skipped` must decode (lenient, default empty).
- Commands need `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. All three checks before each commit.

## Review Focus

- Skipping while a scan runs: the scan already holds the ID; it may re-record the entry, but the item must still count as skipped, not failed (survey/counts filter by the set at read time).
- A skipped item that is later removed from the selected albums or deleted from Photos: not counted anywhere.
- Include Again of an item whose entry is still `.failed`: shows under Problems again (no automatic retry).
- Background engine shares the same `BackupIndex` instance (`BackupModel.ensureIndex` returns `engine.index`): no second actor on the file.
- Header with only skipped items left says "Everything Is Backed Up".

---

### Task 1: Index, counts and filtering (ImmichKit)

**Files:**
- Modify: `Sources/ImmichKit/Backup/BackupIndex.swift` (Stored + new API)
- Modify: `Sources/ImmichKit/Backup/BackupScanner.swift` (`BackupCounts`, `performScan` ~line 129, `counts()` ~line 280)
- Modify: `Sources/ImmichKit/Backup/BackupUploader.swift` (`queuedItems` ~line 370)
- Test: `Tests/ImmichKitTests/Backup/BackupIndexTests.swift`, `BackupScannerTests.swift`, `BackupUploaderTests.swift`

**Interfaces (produces):**
- `BackupIndex.skippedIDs() -> Set<String>`
- `BackupIndex.skip(_ ids: some Sequence<String>)` / `includeAgain(_ ids: some Sequence<String>)`: mark `hasChanges` only when the set changes; don't save.
- `BackupIndex.selectedAssetIDs(in source: some PhotoLibrarySource) async -> (ids: Set<String>, skipped: Set<String>)`: `ids` = selection minus skipped; `skipped` = selection ∩ skipped.
- `BackupCounts.skipped: Int` (init param default 0) and `mutating func addSkipped(_ n: Int)` (adds to `skipped` and `total`). Doc comment invariant becomes `total == backedUp + pending + deletedOnServer + failed + skipped`.

- [ ] Step 1: failing tests
  - Index: `testSkipRoundTripsThroughSave` (skip, save, reopen → `skippedIDs() == ["a"]`; includeAgain, save, reopen → empty); `testIndexWithoutSkippedDecodes` (write a JSON file with only entries+selection, load → entries present, skipped empty); `testSelectedAssetIDsLeavesOutSkipped`.
  - Scanner: `testScanDoesNotReadSkippedItems` (two selected assets, skip one → source never reads it, its entry unchanged, result `skipped == 1`, `total == 2`); `testCountsCountSkippedApart` (`counts()` gives `skipped == 1`, `failed == 0` for a skipped failed entry).
  - Uploader: `testSkippedItemIsNotUploaded` (a `.pending(.needsUpload)` entry that is skipped → no upload request).
- [ ] Step 2: run, expect FAIL (missing API).
- [ ] Step 3: implement. `Stored` gets `skipped: Set<String> = []`, coding key `skipped`, decoded with `(try? decodeIfPresent) ?? []`. Scanner/uploader call `selectedAssetIDs`; scanner adds `skipped.count` via `addSkipped` to the initial estimate and to `counts()`, and the progress/return counts keep it (skipped IDs are not in the loop, so they never hit `show`).
- [ ] Step 4: targeted tests pass, then all three checks.
- [ ] Step 5: commit "Let the backup index skip items the owner gave up on".

### Task 2: Model and screen (ImmichUI)

**Files:**
- Modify: `Sources/ImmichUI/Backup/BackupModel.swift` (survey ~line 950, `currentEntries` ~915, new published list + actions)
- Modify: `Sources/ImmichUI/Backup/BackupView.swift` (Overview row, problem rows)
- Create: `Sources/ImmichUI/Backup/BackupSkippedList.swift` (modeled on `BackupDeletedOnServerList.swift`, with `#Preview`)
- Modify: `Sources/ImmichUI/Resources/nb.lproj/Localizable.strings`
- Test: `Tests/ImmichKitTests/Backup/BackupModelTests.swift`

**Interfaces:**
- Consumes: Task 1 API.
- Produces: `BackupModel.SkippedItem: Identifiable, Equatable { id: String; date: Date? }`, `private(set) var skippedItems: [SkippedItem]` (newest creation date first, limit `failedItemLimit`), `func skip(_ ids: [String]) async`, `func includeAgain(_ ids: [String]) async`.

- [ ] Step 1: failing model tests: `testSkipMovesFailedItemToSkipped` (seed one failed entry; `skip` → `failedItems` empty, `skippedItems.map(\.id) == [id]`, `counts.failed == 0`, `counts.skipped == 1`, index on disk has it skipped); `testIncludeAgainRestoresProblem` (then `includeAgain` → back in `failedItems`, `counts.skipped == 0`); `testSkippedOnlyMeansEverythingBackedUp` (header status from those counts has kind `.upToDate`).
- [ ] Step 2: run, expect FAIL.
- [ ] Step 3: implement. `skip`/`includeAgain`: `workingCount` guard like `retry`, change the set on `ensureIndex()`, `try? save()` (on error set `error` via `report`), then `refreshCounts()`. `survey`/`currentEntries` use `selectedAssetIDs`; survey adds the skipped count with `addSkipped` (only IDs still in the library per `modificationDates`) and returns skipped IDs for `skippedItems` (dates via `source.assets`, like failed). Skipped thumbnails kept in the `shown` set.
  View: Overview gets `BackupCountRow(title: tr("Skipped"), symbol: "minus.circle.fill", tint: .gray, value:)` as a `NavigationLink` to `BackupSkippedList` when `counts.skipped > 0`, placed before Problems; update the Total comment. Problem row: `.contextMenu` and `.swipeActions` with "Try Again" and "Skip" (`arrow.uturn.forward`), both `.disabled(model.isWorking)`. Skipped list: rows with thumbnail+date and a bordered capsule "Include Again" button; footer text from Global Constraints; empty state `ContentUnavailableView(tr("Nothing Skipped"), systemImage: "checkmark.circle")`.
- [ ] Step 4: targeted tests pass, then all three checks.
- [ ] Step 5: commit "Skip a backup item that keeps failing, and include it again".
