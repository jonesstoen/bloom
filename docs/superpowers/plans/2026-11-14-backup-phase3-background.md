# Backup Phase 3 (background) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With the Backup switch on, photos reach the server within 24 hours without opening Bloom, through a background `URLSession`, a nightly processing task and app refresh, behind a transport boundary that a future PhotoKit upload extension can replace.

**Architecture:** Phase 2's scanner, index, verdicts and runner stay. Uploads move from awaited foreground requests to a `BackupTransport`: the background-session implementation stages one multipart body per resource, enqueues it, and records results through a recorder actor before telling iOS it is done. A headless `BackupEngine` can be built from Keychain credentials for cold launches. `BGProcessingTask` (charging) and `BGAppRefreshTask` drive scanning and enqueuing when Bloom is closed.

**Tech Stack:** Swift concurrency/actors, URLSession background configuration, BackgroundTasks, PhotoKit (`PHPersistentChangeToken`), SwiftUI, XCTest with fakes.

**Spec:** `docs/superpowers/specs/2026-11-14-backup-phase3-background-design.md` (approved 2026-11-14); builds on the Phase 2 design and code.

## Global Constraints

- Everything in the Phase 2 plan's Global Constraints still holds (read-only PhotoKit, no DELETE, option C, counts add up, cellular switches, key only in `x-api-key`, `tr()` + Norwegian, `#Preview` with mocks, actors, three checks per commit with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
- One new multipart field: `visibility=hidden`, for Live Photo motion halves only.
- Background session: one identifier per signed-in account (stable, non-secret hash of server URL + user ID), `sessionSendsLaunchEvents = true`, `isDiscretionary = false`, delegate refuses cross-origin redirects (same rule as `SameOriginRedirects`), per-request cellular flags from the switches.
- A task's result is persisted in the index **before** the system completion handler is called; the delegate and its sink exist **before** the session is created.
- Reconcile never deletes the body file of a task iOS still reports; cleanup deletes only unreferenced staging files (no more "empty Staging at launch").
- Staged files: `.completeUntilFirstUserAuthentication`, excluded from backup; staging budget ~2 GB of staged-but-unrecorded bodies; 2–4 tasks in flight.
- Heavy work (hashing, iCloud downloads, staging large videos) only with the app open or in the processing task (`requiresExternalPower = true`, `requiresNetworkConnectivity = true`); the refresh task enqueues only small, already-local photos.
- Background tasks enqueue and finish; they don't wait for uploads.
- iOS 26 APIs only. No `BGContinuedProcessingTask`, no PhotoKit upload extension.
- The app target (`../ImmichPhotos`) is never edited by agents; the owner gets exact Xcode steps.

## Review Focus

- **Bloom killed by the system mid-upload, then relaunched by iOS in the background for the session's events**: the result is recorded once, the body file is removed, no duplicate is created — test in Task 3.
- **Two accounts**: results for account A's session arriving after a sign-out or while B is signed in are ignored and never written into B's index — test in Task 3 and Task 5.
- **A Live Photo where one half finished and the other failed, across relaunches**: only the missing half is re-sent, the link happens once both IDs exist, the motion stays hidden — test in Task 4.
- **The switch turned off while tasks are in flight**: in-flight tasks are cancelled, scheduled BG tasks cancelled, nothing new enqueued — test in Task 6.
- **A Phase 2 index with `uploading`-free states and items mid-retry**: loads and continues without re-uploading anything already on the server — test in Task 4.

---

### Task 1: Transport boundary and result recorder

**Files:**
- Create: `Sources/ImmichKit/Backup/BackupTransport.swift`, `Sources/ImmichKit/Backup/BackupResultRecorder.swift`
- Modify: `Sources/ImmichKit/Backup/BackupIndex.swift` (persist in-flight job records)
- Test: `Tests/ImmichKitTests/Backup/BackupResultRecorderTests.swift`

**Interfaces:**
- Produces:
  - `struct UploadJob: Sendable, Codable, Equatable { assetID: String; resource: DeviceResourceType; attempt: UUID; bodyFile: URL; checksum: String }`
  - `enum UploadOutcome: Sendable, Equatable { case uploaded(AssetUploadResult); case failed(UploadFailure) }` with `UploadFailure` carrying HTTP status / `ImmichServiceError` classification used by Phase 2's `classify`.
  - `protocol BackupTransport: Sendable { func enqueue(_ job: UploadJob, request: URLRequest) async throws; func inFlight() async -> [UploadJob]; func cancelAll() async }`
  - `actor BackupResultRecorder { init(index: BackupIndex, staging: BackupStaging); func record(_ job: UploadJob, _ outcome: UploadOutcome) async }` — applies Phase 2's success/failure rules (serverIDs, needsLink, backedUp, retry bookkeeping persisted) through `index.update(...)`, saves, then deletes the job's body file.
  - `BackupIndex`: `jobs: [UploadJob]` persisted with entries (`addJob`, `removeJob(attempt:)`, `jobs(for:)`), decoded with `decodeIfPresent` so Phase 2 files load.
- [ ] Failing tests: `testRecordingSuccessMarksBackedUpAndDeletesBody`, `testRecordingDuplicateCountsAsSuccess`, `testRecordingIsIdempotentForTheSameAttempt` (second record of the same attempt changes nothing), `testRecordingForAChangedEntryIsIgnored` (checksums differ → no write), `testRejectedBecomesFailedWithMessage`, `testPhase2IndexLoadsWithNoJobs`.
- [ ] Run, see them fail; implement; run `swift test --filter BackupResultRecorder`; three checks; commit "Record upload results through one recorder".

### Task 2: Single-pass staging into the body file

**Files:**
- Modify: `Sources/ImmichKit/Backup/BackupStaging.swift`, `Sources/ImmichKit/Backup/AssetUpload.swift`
- Test: `Tests/ImmichKitTests/Backup/BackupStagingTests.swift`, `Tests/ImmichKitTests/Backup/AssetUploadTests.swift`

**Interfaces:**
- Consumes: `UploadJob` (Task 1).
- Produces:
  - `BackupStaging.stageBody(_ resource: DeviceResource, of asset: DeviceAsset, from source: any PhotoLibrarySource, allowNetwork: Bool, fields: MultipartFields, expectedChecksum: String) async throws -> (bodyFile: URL, boundary: String)` — streams PhotoKit bytes into the multipart body (prefix, data, suffix) while hashing; throws `BackupStagingError.checksumMismatch` and removes the file when the hash differs.
  - `struct MultipartFields` (filename, mimeType, createdAt, modifiedAt, isFavorite, duration, livePhotoVideoID, `hidden: Bool` → `visibility=hidden`).
  - `BackupStaging.removeUnreferenced(keeping: Set<URL>)`; `removeAll()` stays for sign-out only.
  - Budget: total bytes of staged-but-unrecorded bodies ≤ budget (default 2 GB) plus the Phase 2 free-space rule.
- [ ] Failing tests: `testBodyMatchesTheMultipartFixtureByteForByte` (reuse Phase 2's fixture), `testHiddenAddsVisibilityHidden`, `testChecksumMismatchThrowsAndLeavesNoFile`, `testBudgetRefusesBeyondTheLimit`, `testRemoveUnreferencedKeepsReferencedFiles`, `testOneCopyOnDisk` (no separate resource file left).
- [ ] Run fail; implement (autoreleasepool per chunk as Phase 2); run pass; three checks; commit "Stage each resource once, straight into its upload body".

### Task 3: Background session transport, reconcile and cold launch

**Files:**
- Create: `Sources/ImmichKit/Backup/BackgroundSessionTransport.swift`
- Test: `Tests/ImmichKitTests/Backup/BackgroundSessionTransportTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2; `LiveImmichService.makeUploadRequest(_:boundary:bodyFile:)` (Phase 2) or an equivalent request builder that adds `x-immich-checksum` and `x-api-key`.
- Produces:
  - A small session abstraction for tests: `protocol UploadSessionDriving { func uploadTask(with: URLRequest, fromFile: URL) -> UploadTaskHandle; func allTasks() async -> [UploadTaskHandle]; func invalidateAndCancel() }`; the live one wraps `URLSession(configuration: .background(withIdentifier:))`.
  - `final class BackgroundSessionTransport: BackupTransport` — `taskDescription` = encoded `UploadJob` attempt; collects response bodies per task; on completion parses with `LiveImmichService.result(status:data:)`, calls `recorder.record` and only then counts the event done; `func handleEvents(completion: @escaping () -> Void)` stores the system handler and calls it after all pending records finished (`urlSessionDidFinishEvents`); `func reconcile() async` (jobs in index without a live task and without a result → back to `needsUpload`; files not referenced by index jobs or live tasks → removed).
  - `static func sessionIdentifier(serverURL: URL, userID: String) -> String` (prefix `no.johannesstoen.bloom.backup.` + short SHA-256 hex; no secrets).
- [ ] Failing tests (fake session): `testResultIsRecordedBeforeTheCompletionHandler`, `testEventsBeforeTheHandlerIsStoredAreNotLost`, `testRelaunchRecordsAFinishedTaskOnce`, `testReconcileRequeuesAJobWithNoTaskAndNoResult`, `testReconcileKeepsTheBodyOfALiveTask`, `testCrossOriginRedirectIsRefused`, `testCellularFlagsFollowTheSwitches`, `testIdentifierDiffersPerAccountAndHoldsNoSecret`.
- [ ] Run fail; implement; run pass; three checks; commit "Upload through a background session that survives relaunch".

### Task 4: Uploader on the transport (Live Photos, retries, runner)

**Files:**
- Modify: `Sources/ImmichKit/Backup/BackupUploader.swift`, `Sources/ImmichUI/Backup/BackupRunner.swift`, `Sources/ImmichUI/Backup/BackupModel.swift`
- Test: `Tests/ImmichKitTests/Backup/BackupUploaderTests.swift`, `Tests/ImmichKitTests/Backup/BackupRunnerTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3 (a `FakeTransport` in tests that completes jobs on command).
- Produces:
  - `BackupUploader.run` stages and **enqueues** (keeping up to 2–4 jobs in flight and the budget), instead of awaiting each upload; results arrive via the recorder.
  - Live Photo: motion staged with `hidden: true`, photo staged without `livePhotoVideoID`, both enqueued; when both IDs are recorded and `needsLink` is set, `linkLivePhoto` is called at the next opportunity (`BackupUploader.linkPending() async`), retried with Phase 2 rules; only halves without a known server ID are sent.
  - Phase 2 retry/back-off/hold/skip rules apply to recorded failures (persisted retry state).
  - `BackupRunner`: leaving the foreground no longer cancels uploads (they belong to iOS); it still cancels scanning and staging. Switch off → `transport.cancelAll()`.
- [ ] Failing tests: `testEnqueuesWithoutWaitingAndKeepsTheInFlightLimit`, `testLivePhotoMotionIsHiddenAndLinkedOnceBothFinished`, `testRetrySendsOnlyTheMissingHalf`, `testLeavingTheForegroundKeepsUploadsGoing`, `testSwitchOffCancelsInFlightUploads`, `testPhase2IndexContinuesWithoutReuploading`, plus Phase 2 tests updated only where the awaited-upload assumption changes (state why in the report; don't weaken).
- [ ] Run fail; implement; run pass; three checks; commit "Hand uploads to the background session".

### Task 5: Headless engine and change tokens

**Files:**
- Create: `Sources/ImmichUI/Backup/BackupEngine.swift` (or ImmichKit if it needs no UI types)
- Modify: `Sources/ImmichKit/Backup/PhotoLibrarySource.swift`, `PhotoKitLibrarySource.swift`, `Tests/ImmichKitTests/Backup/FakePhotoLibrary.swift`, `Sources/ImmichUI/Root/RootModel.swift`
- Test: `Tests/ImmichKitTests/Backup/BackupEngineTests.swift`

**Interfaces:**
- Produces:
  - `PhotoLibrarySource.changedAssetIDs(since token: Data?) async -> (ids: Set<String>?, token: Data?)` — `ids == nil` means "token expired or unavailable, do a full scan"; PhotoKit uses `fetchPersistentChanges(since:)`; the token is archived in the account's backup directory.
  - `final class BackupEngine` (one per account) built **without UI** from Keychain credentials + account directory: owns index, scanner, staging, recorder, transport, uploader. `static func forSessionIdentifier(_ id: String) -> BackupEngine?` (nil when no signed-in account matches → caller invalidates that session). `RootModel` builds its session's backup from the same engine so foreground and background share one instance per process.
  - `BackupEngine.runIncremental(budget:)` (refresh: changed IDs only, small local photos only, link pending) and `runProcessing()` (full scan + enqueue within budget + link pending); both stop on cancellation.
- [ ] Failing tests: `testIncrementalScanChecksOnlyChangedAssets`, `testExpiredTokenFallsBackToFullScan`, `testRefreshSkipsICloudOnlyAndLargeVideos`, `testUnknownSessionIdentifierGivesNoEngine`, `testSignedOutAccountResultsAreIgnored`, `testForegroundAndBackgroundShareOneEngine`.
- [ ] Run fail; implement; run pass; three checks; commit "Build the backup engine headlessly and find new photos by change token".

### Task 6: Scheduling and the app-target hook

**Files:**
- Create: `Sources/ImmichUI/Backup/BackupBackgroundTasks.swift` (`#if os(iOS)`)
- Modify: `Sources/ImmichUI/Root/RootModel.swift`, `Sources/ImmichUI/Root/ImmichRootView.swift`, `Sources/ImmichUI/Backup/BackupRunner.swift`
- Test: `Tests/ImmichKitTests/Backup/BackupSchedulingTests.swift`

**Interfaces:**
- Produces:
  - Task identifiers `no.johannesstoen.bloom.backup.processing` and `no.johannesstoen.bloom.backup.refresh`.
  - A one-line hook for the app target (builder picks: `@UIApplicationDelegateAdaptor(BloomAppDelegate.self)` or a scene modifier) that registers both BG tasks at launch and forwards `handleEventsForBackgroundURLSession` to `BackupEngine.forSessionIdentifier(...)?.transport.handleEvents(...)`.
  - A scheduler abstraction (`protocol BackgroundTaskScheduling`) so tests check: submit on switch on and on backgrounding (processing: external power + network; refresh: earliest ~1 h), resubmit at the start of each run, cancel all on switch off and sign-out, expiration handler cancels the engine run and calls `setTaskCompleted(success: false)`, normal end calls `setTaskCompleted(success: true)`.
  - Sign-out: cancel BG tasks, `transport.cancelAll()`, invalidate the session, then Phase 2 cleanup order.
- [ ] Failing tests: `testSwitchOnSchedulesBothTasks`, `testSwitchOffCancelsTasksAndUploads`, `testProcessingRequiresPowerAndNetwork`, `testExpirationStopsTheRunAndReportsFailure`, `testEachRunReschedules`, `testSignOutCancelsEverything`.
- [ ] Run fail; implement; run pass; three checks; commit "Schedule nightly and refresh backup runs".

### Task 7: Status screen, privacy text and owner steps

**Files:**
- Modify: `Sources/ImmichUI/Backup/BackupView.swift`, `Sources/ImmichUI/Backup/BackupModel.swift`, `Sources/ImmichUI/Resources/nb.lproj/Localizable.strings`, `PRIVACY.md`, `docs/APP_STORE.md`
- Create: `docs/app-target/BACKGROUND_BACKUP.md` (owner's Xcode steps)
- Test: `Tests/ImmichKitTests/Backup/BackupModelTests.swift`

**Interfaces:**
- Produces, with exact copy (English → Norwegian):
  - "Uploading in the background: %lld" → "Lastes opp i bakgrunnen: %lld"
  - "Last backup: %@" → "Siste sikkerhetskopi: %@" (relative date, Norwegian locale)
  - "Bloom backs up when it is open and at night while charging. iOS decides the exact time." → "Bloom tar sikkerhetskopi når appen er åpen og om natten mens den lader. iOS bestemmer nøyaktig når."
  - "Background App Refresh is off for Bloom. Turn it on in Settings to back up when Bloom is closed." → "Bakgrunnsoppdatering er av for Bloom. Slå den på i Innstillinger for å ta sikkerhetskopi når Bloom er lukket."
  - Remove "Bloom uploads while the app is open." (key and nb line).
  - PRIVACY.md (en + nb): background uploads keep the request header with the API key in iOS system storage while the upload runs.
  - `docs/app-target/BACKGROUND_BACKUP.md`: Background Modes (Background fetch, Background processing), `BGTaskSchedulerPermittedIdentifiers` with both identifiers, the one-line hook, how to trigger tasks from the debugger.
- [ ] Failing tests: `testInFlightCountShowsUploadingInTheBackground`, `testLastBackupComesFromTheLastRecordedSuccess`, `testRefreshOffHintShowsWhenDenied`; LocalizationTests cover the copy.
- [ ] Run fail; implement (previews with mocks); run pass; three checks; commit "Show background backup status".

---

After the last task (not a task): the owner adds the app-target steps from `docs/app-target/BACKGROUND_BACKUP.md`, then the phone checks from the spec's Verification section.
