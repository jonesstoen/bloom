# Backup Phase 2 (upload while the app is open) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With a "Backup" switch on, Bloom uploads the selected albums' missing photos and videos while it is in the foreground, shows items deleted on the server without re-uploading them, and lets the user re-upload or retry explicitly.

**Architecture:** Phase 1's index, scanner and model are extended, not replaced. The index records per-resource server IDs and a new `deletedOnServer` state; the scanner re-checks everything it saw on the server; a new `BackupUploader` actor stages each resource to a file and uploads it with a foreground `URLSession` upload task (Phase 3 swaps in a background session); a `BackupRunner` in ImmichUI decides when scan + upload run.

**Tech Stack:** Swift 6 toolchain (package in Swift 5 mode), Swift concurrency/actors, PhotoKit behind `PhotoLibrarySource`, URLSession, SwiftUI, XCTest with `MockImmichService` and `FakePhotoLibrary`.

**Spec:** `docs/superpowers/specs/2026-11-13-backup-phase2-upload-design.md` (builds on `docs/superpowers/specs/2026-11-13-backup-design.md`).

## Global Constraints

- Bloom never deletes or modifies anything in the photo library: no `PHAssetChangeRequest`, no `performChanges` anywhere. No DELETE requests; restoring from the server's trash only on the user's explicit Re-upload.
- New network calls in this phase: `POST /assets` (multipart, header `x-immich-checksum`), `PUT /assets/{id}` with only `livePhotoVideoId` (linking), and the existing `POST /trash/restore/assets`. Nothing else.
- Upload fields: `assetData`, `fileCreatedAt`, `fileModifiedAt`, `filename`, `isFavorite`, `duration` (videos), `livePhotoVideoId` (photo of a Live Photo). No `visibility`, `metadata`, `sidecarData`.
- Response `201` (status `created`) and `200` (status `duplicate`) are both success; the body's `id` is the server asset ID.
- Live Photo: motion video first, then the photo with `livePhotoVideoId`; a half the server already has is never uploaded again.
- Counts: Total = On Server + Remaining + Deleted on Server + Problems, always.
- An item Bloom never saw on the server is never "deleted on server"; nothing under Deleted on Server is uploaded or restored without the user's action.
- Cellular: with the switch for that media type off, no iCloud download and no upload on cellular (item `pending(.waitingForWiFi)`; request also has `allowsCellularAccess = false`).
- API key only in the `x-api-key` header; never in URLs, staged files or logs. Requests go through `SameOriginRedirects.session`.
- Staging files: account's backup directory, subfolder `Staging`, file protection `.completeUntilFirstUserAuthentication`, deleted after each item, folder emptied at launch and at sign-out after the uploader stopped.
- All user-facing text through `tr("…")` with a Norwegian line in the target's `nb.lproj/Localizable.strings`.
- Shared mutable state in actors; views have a `#Preview` using mocks; iOS-only code behind `#if os(iOS)` / `canImport(Photos)`.
- Before every commit: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; `swift build`; `swift test`; `xcodebuild build -scheme ImmichKit -destination 'generic/platform=iOS Simulator' -quiet`. One task, one commit; message ends with the Co-Authored-By line.

## Review Focus

- **A Phase 1 `index.json` on the owner's phone** (no per-resource IDs, `backedUp` entries, possibly trashed duplicates counted as on server) must load without losing anything and be corrected by the next re-check — test in Task 1 and Task 2.
- **The app goes to the background mid-upload, or the switch is turned off,** and comes back: no duplicate on the server, no orphan staging file, the item is retried — test in Task 4 and Task 6.
- **A Live Photo whose motion upload succeeded but photo upload failed** must not leave a stray motion video re-uploaded next time (the retry reuses the motion's server ID via `duplicate`) — test in Task 4.
- **An item edited on the phone while it is being uploaded** must not upload stale bytes under the old checksum — test in Task 4.
- **Thousands of re-check results at once** (13 000 backedUp items) must not flood the UI or the main actor — test in Task 2 (requests batched at 500, one progress event per batch at most).

---

### Task 1: Index — per-resource server IDs and `deletedOnServer`

**Files:**
- Modify: `Sources/ImmichKit/Backup/BackupIndex.swift`
- Modify: `Sources/ImmichKit/Backup/BackupScanner.swift` (`BackupCounts` only)
- Test: `Tests/ImmichKitTests/Backup/BackupIndexTests.swift`

**Interfaces:**
- Produces:
  - `BackupState.deletedOnServer(trashed: Set<DeviceResourceType>, gone: Set<DeviceResourceType>)` — which halves are in the server's trash and which are gone.
  - `BackupEntry.serverIDs: [DeviceResourceType: String]` (default `[:]`), with `init(modificationDate:checksums:state:serverIDs: = [:])`.
  - `BackupCounts.deletedOnServer: Int`; `BackupCounts.add(_:)` counts the new state there.
  - `BackupIndex.entries(where: (BackupEntry) -> Bool, in ids: Set<String>, limit: Int) -> [(String, BackupEntry)]` — filtered inside the actor (replaces one-hop-per-ID scans in the model).

- [ ] **Step 1: Failing tests** — `testPhase1IndexLoadsWithEmptyServerIDs` (write a Phase 1-shaped JSON fixture with a `backedUp` entry, load, assert entry equal except `serverIDs == [:]`); `testDeletedOnServerRoundTrips` (trashed `[.photo]`, gone `[.pairedVideo]`, save, reload, equal); `testCountsAddUpWithDeletedOnServer` (one entry per state → `total == backedUp + pending + deletedOnServer + failed`); `testEntriesWhereFiltersInsideTheIndex` (10 entries, 3 failed, limit 2 → 2 results, all failed).
- [ ] **Step 2: Run, verify they fail** — `swift test --filter BackupIndexTests`
- [ ] **Step 3: Implement** — decode `serverIDs` with `decodeIfPresent` so old files load; keep `BackupState`'s Codable backward compatible (existing cases encode exactly as before).
- [ ] **Step 4: Run, verify pass** — `swift test --filter Backup`
- [ ] **Step 5: Three checks, commit** — "Record which server copies each backed-up photo has"

---

### Task 2: Scanner — re-check everything seen on the server (option C)

**Files:**
- Modify: `Sources/ImmichKit/Backup/BackupScanner.swift`
- Test: `Tests/ImmichKitTests/Backup/BackupScannerTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces: scanner verdicts below; `BackupScanner.scan` unchanged in signature.

Verdict, per item, from the bulk-check answers for its policy resources and its **previous** state:

| answers | previous state was backedUp / deletedOnServer (seen on server) | otherwise |
|---|---|---|
| all duplicate, none trashed | `backedUp(photo-or-only ID)`, `serverIDs` filled | same |
| any trashed or any `accept` | `deletedOnServer(trashed:, gone:)` per resource | trashed ones present → `deletedOnServer`; none trashed → `pending(.needsUpload)` |

A re-hash after an edit starts from `pending(.notChecked)`, so an edited deleted item becomes `needsUpload` (spec: edits are new versions).

- [ ] **Step 1: Failing tests** — `testBackedUpItemsAreRecheckedWithoutReads` (second scan: zero `library.reads`, one check request with all stored checksums); `testPurgedOnServerBecomesDeletedOnServer`; `testTrashedOnServerBecomesDeletedOnServerTrashed`; `testDeletedItemRestoredOnServerBecomesBackedUpAgain`; `testLivePhotoWithMotionGoneIsDeletedOnServerGoneMotion` (`gone == [.pairedVideo]`, `trashed == []`); `testNeverSeenAndAcceptedIsNeedsUploadNotDeleted`; `testFirstCheckFindsTrashedCopyIsDeletedOnServer` (replaces Phase 1's "trashed counts as on server" test — update that test's expectation, don't delete it); `testEditedDeletedItemBecomesNeedsUpload`; `testRecheckOf1300BackedUpSendsThreeBatchedRequests` (batch size 500).
- [ ] **Step 2: Run, verify they fail**
- [ ] **Step 3: Implement** — extend the "already hashed" branch to enqueue `backedUp` and `deletedOnServer` entries; give `verdict` the previous state; store `serverIDs` from duplicate answers.
- [ ] **Step 4: Run, verify pass** — `swift test --filter Backup`
- [ ] **Step 5: Three checks, commit** — "Notice photos deleted on the server"

---

### Task 3: Upload request — multipart body, service calls, integration test

**Files:**
- Create: `Sources/ImmichKit/Backup/AssetUpload.swift` (request/response types, multipart writer)
- Create: `Sources/ImmichKit/Service/LiveImmichService+Upload.swift`
- Modify: `Sources/ImmichKit/Service/ImmichService.swift` (requirements + refusing defaults), `Sources/ImmichKit/Mock/MockImmichService.swift`
- Test: `Tests/ImmichKitTests/Backup/AssetUploadTests.swift`, `Tests/ImmichKitTests/Service/UploadIntegrationTests.swift`

**Interfaces:**
- Produces:
  - `struct AssetUploadRequest: Sendable { fileURL: URL /* staged resource */; filename: String; mimeType: String; checksum: String /* base64 SHA1 */; createdAt: Date; modifiedAt: Date; isFavorite: Bool; duration: TimeInterval?; livePhotoVideoID: String?; allowsCellular: Bool }`
  - `enum AssetUploadStatus: Sendable { case created, duplicate }`; `struct AssetUploadResult: Sendable, Equatable { id: String; status: AssetUploadStatus }`
  - `enum MultipartBody { static func write(_ request: AssetUploadRequest, boundary: String, to url: URL) throws }` — streams the resource file into the body file in chunks (never whole in memory).
  - `ImmichService.uploadAsset(_ request: AssetUploadRequest) async throws -> AssetUploadResult` (default throws `.unexpectedStatus(501)`).
  - `ImmichService.linkLivePhoto(photoID: String, motionID: String) async throws` (`PUT /assets/{photoID}` body `{"livePhotoVideoId": motionID}`; default throws `.unexpectedStatus(501)`).
  - `enum BackupUploadError: Error, Equatable { case rejected(status: Int, message: String) }` for 4xx other than 401/403/429; 401/403 → `ImmichServiceError.unauthorized`; 429/5xx → `.unexpectedStatus(code)`; transport errors → `.network(_)`.
  - Mock: records `uploads: [AssetUploadRequest]`, `links`, configurable per-call result/failure (e.g. `setUploadResults(_:)`, `setUploadFailure(_:afterCalls:)`).

Fields as in Global Constraints. Dates ISO 8601 with fractional seconds, as the service already encodes them. `duration` encoding lives in one function (`static func durationField(_:) -> String`), as an integer per the v3.4.0 spec (unit not stated there: use whole seconds, rounded); the phone check with a video confirms it against v3.3.6.

- [ ] **Step 1: Failing tests** — `testMultipartBodyMatchesFixture` (fixed boundary, 3-byte resource, all fields → exact expected bytes); `testMultipartOmitsDurationAndLivePhotoWhenNil`; `testUploadRequestHeaders` (built `URLRequest`: method POST, path `/api/assets`, `x-api-key`, `x-immich-checksum`, `Content-Type: multipart/form-data; boundary=…`, `allowsCellularAccess` from the request, no key in the URL); `testStatusMapping` (201→created, 200→duplicate, 401/403→unauthorized, 400→rejected with message, 500→unexpectedStatus) via a pure `static func result(status:data:)`; `testLinkLivePhotoBody`. Integration (skips without `IMMICH_URL`/`IMMICH_API_KEY`): upload a generated 1×1 PNG with a random pixel → `created`; again → `duplicate` with the same ID; the test's doc says the asset stays on the server for manual removal.
- [ ] **Step 2: Run, verify they fail**
- [ ] **Step 3: Implement** — upload with `SameOriginRedirects.session.upload(for:fromFile:)` on a body file written next to the resource; delete the body file afterwards; size-limit the response read like other raw calls.
- [ ] **Step 4: Run, verify pass**
- [ ] **Step 5: Three checks, commit** — "Add the asset upload request"

---

### Task 4: Uploader — staging, Live Photos, retries

**Files:**
- Create: `Sources/ImmichKit/Backup/BackupStaging.swift`, `Sources/ImmichKit/Backup/BackupUploader.swift`
- Modify: `Tests/ImmichKitTests/Backup/FakePhotoLibrary.swift` (only if a hook is missing)
- Test: `Tests/ImmichKitTests/Backup/BackupStagingTests.swift`, `Tests/ImmichKitTests/Backup/BackupUploaderTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3; `PhotoLibrarySource.read(_:of:allowNetwork:onData:)`, `BackupResourcePolicy.upload(from:)`, `BackupSettings.allowsNetwork(for:onCellular:)`, `NetworkConditions`.
- Produces:
  - `actor BackupStaging { init(directory: URL, freeSpace: @Sendable () -> Int64); func stage(_ resource: DeviceResource, of asset: DeviceAsset, from source: any PhotoLibrarySource, allowNetwork: Bool) async throws -> (url: URL, checksum: String); func removeAll() }` — throws `BackupStagingError.notEnoughSpace` when free space < max(resource estimate, 0) + 200 MB margin (estimate unknown → margin only).
  - `struct UploadProgress: Sendable, Equatable { done: Int; total: Int; currentFilename: String? }`
  - `actor BackupUploader { init(source:, service:, index:, staging:, settings:, network:); func run(progress: @escaping @Sendable (UploadProgress) -> Void, shouldPause: @escaping @Sendable () async -> Bool) async throws; func retryFailed(_ ids: [String]) async; func reupload(_ ids: [String]) async throws }` — `run` uploads `pending(.needsUpload)` items of the current selection, newest `creationDate` first, one at a time; `shouldPause` is asked between items (the runner uses it for "library changed, rescan first"); cancellation stops after cleaning the staging file of the current item.

Per item (spec "Uploading" 1–6): re-fetch asset; modification date changed → set state `pending(.notChecked)` and clear checksums, skip; stage each policy resource, checksum ≠ stored → same as changed; Live Photo motion first (`duplicate` motion → reuse its ID), photo with `livePhotoVideoID`; success → `backedUp` + `serverIDs`; save index after each item. Errors: `unauthorized` rethrown (run stops); `.network`/`.unexpectedStatus(429, 5xx)` → item stays `needsUpload`, back-off in memory 5 s, 30 s, 2 min, 10 min, then skipped for this session; `rejected` → `failed(reason: message)`; read errors → `failed(reason)` as the scanner does; `needsNetwork` or cellular with switch off → `pending(.waitingForWiFi)`; `notEnoughSpace` → `failed(tr("Not enough free space on the iPhone."))`, and the run stops. `retryFailed` sets `pending(.notChecked)` keeping checksums (the next scan re-checks and queues); `reupload` per spec "Re-upload": trashed halves → `service.restoreAssets`, gone photo → upload with existing motion ID, gone motion → upload then `linkLivePhoto`, whole item gone → `needsUpload`.

- [ ] **Step 1: Failing tests** — staging: `testStagedFileMatchesChecksum`, `testNotEnoughSpaceThrows`, `testRemoveAllEmptiesFolder`. Uploader: `testUploadsNewestFirstAndMarksBackedUp`; `testLivePhotoUploadsMotionFirstThenLinkedPhoto` (mock sees motion then photo with `livePhotoVideoID == motionID`); `testLivePhotoRetryAfterPhotoFailureReusesMotionDuplicate` (first run: motion created, photo 500; second run: motion answered duplicate, no extra motion asset, photo linked); `testChangedAssetIsSentBackToScanner` (fake changes modification date between scan and upload → no upload, state `pending(.notChecked)`, checksums cleared); `testChecksumMismatchIsSentBackToScanner`; `testServerErrorKeepsNeedsUploadAndBacksOff`; `testRejectedBecomesFailedWithServerMessage`; `testUnauthorizedStopsTheRun`; `testCellularWithSwitchOffWaitsForWiFiAndUploadsNothing`; `testCancellationLeavesNoStagingFiles`; `testPauseBetweenItemsIsHonoured`; `testRetryFailedRequeues`; `testReuploadRestoresTrashedAndQueuesGone`; `testReuploadGoneMotionUploadsAndLinks`; `testDeletedOnServerItemsAreNeverUploadedByRun`.
- [ ] **Step 2: Run, verify they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run, verify pass** — `swift test --filter Backup`
- [ ] **Step 5: Three checks, commit** — "Upload missing photos one at a time"

---

### Task 5: PhotoKit — change stream and thumbnails

**Files:**
- Modify: `Sources/ImmichKit/Backup/PhotoLibrarySource.swift`, `Sources/ImmichKit/Backup/PhotoKitLibrarySource.swift`, `Sources/ImmichUI/Backup/BackupModel.swift` (`PreviewPhotoLibrary` only), `Tests/ImmichKitTests/Backup/FakePhotoLibrary.swift`
- Test: `Tests/ImmichKitTests/Backup/FakePhotoLibraryTests.swift`

**Interfaces:**
- Produces:
  - `PhotoLibrarySource.changes() -> AsyncStream<Void>` — one element per PhotoKit library change (PhotoKit: a `PHPhotoLibraryChangeObserver` registered for the stream's lifetime, unregistered on termination). Read-only.
  - `PhotoLibrarySource.thumbnailData(_ id: String, pixelSide: Int) async -> Data?` — JPEG data (PhotoKit: `PHImageManager`, `.fastFormat`, local thumbnails only: `isNetworkAccessAllowed = false`).
  - Fake: `emitChange()`, `thumbnails: [String: Data]`.

- [ ] **Step 1: Failing tests** — `testFakeChangesStreamDeliversEmittedChanges`, `testFakeThumbnailReturnsConfiguredData`.
- [ ] **Step 2–4: Run fail, implement, run pass**
- [ ] **Step 5: Three checks, commit** — "Watch the photo library for changes"

---

### Task 6: Runner — when scanning and uploading happen

**Files:**
- Create: `Sources/ImmichUI/Backup/BackupRunner.swift`
- Modify: `Sources/ImmichKit/Backup/BackupNetwork.swift` (`BackupSettings.isEnabled`, default `false`, persisted with the other settings), `Sources/ImmichUI/Backup/BackupModel.swift`, `Sources/ImmichUI/Root/RootModel.swift`, `Sources/ImmichUI/Root/ImmichRootView.swift`
- Test: `Tests/ImmichKitTests/Backup/BackupRunnerTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 4, 5; `BackupModel`'s existing scan machinery.
- Produces:
  - `@MainActor @Observable final class BackupRunner { init(model: BackupModel, uploader: BackupUploader, source:); var isUploading: Bool; var uploadProgress: UploadProgress?; func appBecameActive(); func appLeftForeground(); func backupScreenOpened(); func setEnabled(_ on: Bool); func stop() async }` — owned by `BackupModel` (or beside it in `ImmichSession`); `BackupModel` exposes it as `runner`.
  - Behaviour: enabled + active → scan, then `uploader.run`; a library change (debounced 2 s) during scanning restarts the scan after it finishes; during uploading sets the pause flag so the current item finishes, then scan, then continue; `appLeftForeground` cancels the run; disabled → nothing runs, Check Now still scans; `stop()` cancels and awaits, then `staging.removeAll()`.
  - `ImmichTabs` forwards `scenePhase` changes to `session.backup.runner`. Sign-out awaits `runner.stop()` before removing the account's backup directory (extend the existing `backup.stop()` call). Launch empties `Staging` for the signed-in account.

- [ ] **Step 1: Failing tests** — `testDisabledRunsNothingOnActive`; `testEnabledActiveScansThenUploads` (mock: one upload); `testLibraryChangeDuringUploadFinishesItemThenRescans` (gate in the fake read; emit change mid-upload; assert first upload completed, then a scan, then the next upload); `testLeavingForegroundCancelsAndRetriesNextTime` (no duplicate request beyond the interrupted one, item still `needsUpload`, staging empty); `testStopRemovesStagingAndRunsNothingAfter`; `testSwitchOffDuringUploadStops`.
- [ ] **Step 2–4: Run fail, implement, run pass** — tests drive time with an injected clock/sleep, not real delays.
- [ ] **Step 5: Three checks, commit** — "Back up while Bloom is open"

---

### Task 7: Backup screen — switch, Deleted on Server, Try Again

**Files:**
- Modify: `Sources/ImmichUI/Backup/BackupView.swift`, `Sources/ImmichUI/Backup/BackupModel.swift`
- Create: `Sources/ImmichUI/Backup/BackupDeletedOnServerList.swift`
- Modify: `Sources/ImmichUI/Resources/nb.lproj/Localizable.strings`, `Sources/ImmichKit/Resources/nb.lproj/Localizable.strings` (for "Not enough free space on the iPhone.")
- Test: `Tests/ImmichKitTests/Backup/BackupModelTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 4, 5, 6.
- Produces: the screen in the spec's sketch. Exact copy (English → Norwegian):
  - "Backup" switch row → "Sikkerhetskopi"
  - "Deleted on Server" → "Slettet på serveren"; subtitles "In the Trash" → "I papirkurven", "Deleted" → "Slettet"
  - "Re-upload" → "Last opp igjen"; "Re-upload All" → "Last opp alle igjen"
  - "Try Again" → "Prøv igjen"; "Try All Again" → "Prøv alle igjen"
  - "Uploading %@ of %@ · %@" → "Laster opp %1$@ av %2$@ · %3$@"; "Uploading %@ of %@" → "Laster opp %1$@ av %2$@"
  - "Bloom uploads while the app is open." → "Bloom laster opp mens appen er åpen."
  - "Not enough free space on the iPhone." → "Ikke nok ledig plass på iPhone."
  - Remove "Uploading comes in a later update." (key and Norwegian line).
  - Model: `deletedItems: [DeletedItem]` (id, date, trashed, thumbnail data; first 200 via `BackupIndex.entries(where:in:limit:)`), `reupload(_ ids:)`, `reuploadAll()`, `retry(_ ids:)`, `retryAll()`; turning the switch on with no included album presents the album picker.

- [ ] **Step 1: Failing tests** — `testCountsRowAddsUpWithDeletedOnServer`; `testReuploadAllCallsUploaderWithEveryDeletedItem`; `testRetryAllRequeuesFailedItems`; `testTurningOnWithoutAlbumsAsksForAlbums` (model flag `needsAlbumChoice`); `testSwitchPersists`.
- [ ] **Step 2–4: Run fail, implement (views with `#Preview` on the mock), run pass**
- [ ] **Step 5: Three checks, commit** — "Show uploads, photos deleted on the server and retries"

---

### After the last task (not a task)

Owner's phone check (spec "Verification"): Back Up key; a new photo, a Live Photo and a short video; switch on; they appear in Immich (Live Photo as one item, video plays, dates right); second check uploads nothing; delete one in Immich → it moves to Slettet på serveren and is not re-uploaded; Last opp igjen restores it. A `duration` rejection on v3.3.6 shows as a Problems reason with the server's message — fix the one encoding function then.
