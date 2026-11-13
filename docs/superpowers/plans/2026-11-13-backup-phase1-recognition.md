# Backup, Phase 1: Library Index, Recognition and Status Screen — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bloom can show, for the albums the user selects, how many photos and videos are already on the Immich server and how many remain, recognising the Immich app's uploads by checksum, without uploading anything yet.

**Architecture:** PhotoKit sits behind a `PhotoLibrarySource` protocol (ImmichKit) so all logic is unit-tested with a fake. A pure `BackupResourcePolicy` picks the resources the Immich app uploads; a `BackupScanner` actor hashes them (SHA1, base64), asks the server with `checkBulkUpload` and records results in a persistent per-account `BackupIndex` actor. ImmichUI adds `BackupModel`, a Backup screen and an album picker, opened from the account menu.

**Tech Stack:** Swift 6, SwiftUI (iOS 26), PhotoKit, CryptoKit (`Insecure.SHA1`), Network (`NWPathMonitor`), XCTest with `MockImmichService`.

**Spec:** `docs/superpowers/specs/2026-11-13-backup-design.md`

## Global Constraints

- Bloom never deletes or modifies anything in the photo library: no `PHAssetChangeRequest`, no `performChanges` anywhere.
- No DELETE or upload requests in this phase; `POST /assets/bulk-upload-check` is the only new call.
- Resource choice (from the spike): unedited photo `.photo`; edited photo `.fullSizePhoto`; Live Photo `.photo` + `.pairedVideo`; edited Live Photo `.fullSizePhoto` + `.fullSizePairedVideo`; video `.video`, edited video `.fullSizeVideo`. Never adjustment data or other types.
- Checksum: SHA1 of the resource bytes, base64-encoded.
- iCloud downloads follow the cellular switches: with the switch for that media type off, request network access only on Wi-Fi; otherwise the item stays pending with reason "waiting for Wi-Fi". Both switches default to off.
- "Total" = items in any included album minus items in any excluded album.
- All user-facing text through `tr("…")` with a Norwegian line in `Sources/ImmichUI/Resources/nb.lproj/Localizable.strings`.
- Shared mutable state in actors; views have a `#Preview` using mocks; iOS-only code behind `#if os(iOS)` / `canImport(Photos)`.
- Verification before every commit: `swift build`, `swift test`, iOS Simulator `xcodebuild` (see `CLAUDE.local.md`). One task, one commit.

## Review Focus

- **An item in both an included and an excluded album** is excluded (counts and scanning) — test in Task 2.
- **An item edited after it was recognised** (new modification date) is re-hashed and becomes pending if the server lacks the new checksum — test in Task 4.
- **A resource that fails to read (iCloud unavailable)** leaves the item failed with a reason and does not stop the scan — test in Task 4.
- **Signing out or switching account** must not show another account's index — test in Task 3.
- **A Live Photo where only one of its two resources is on the server** counts as pending, not backed up — test in Task 4.

---

### Task 1: API key level and `checkBulkUpload`

**Files:**
- Modify: `Sources/ImmichKit/Credentials/APIKeyPermissions.swift` (add `backup` level, `APIKeyPermissions.backup = ["asset.upload"]`)
- Modify: `Sources/ImmichUI/Login/KeySetupView.swift` (title/allows/refuses texts for `.backup`) and `nb.lproj` strings
- Create: `Sources/ImmichKit/Backup/BulkUploadCheck.swift`
- Modify: `Sources/ImmichKit/Service/ImmichService.swift`, `Sources/ImmichKit/Editing/EditingPermission.swift` (forward), `Sources/ImmichKit/Mock/MockImmichService.swift`
- Create: `Sources/ImmichKit/Service/LiveImmichService+Backup.swift`
- Test: `Tests/ImmichKitTests/App/APIKeyPermissionTests.swift`, `Tests/ImmichKitTests/Backup/BulkUploadCheckTests.swift`

**Interfaces:**
- Produces: `public struct BulkUploadCheckItem: Sendable, Hashable { public let id: String; public let checksum: String }`
- Produces: `public struct BulkUploadCheckResult: Sendable, Equatable { public let id: String; public let isDuplicate: Bool; public let serverAssetID: String?; public let isTrashed: Bool }`
- Produces: protocol requirement `func checkBulkUpload(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult]` with a default that throws `ImmichServiceError.unexpectedStatus(501)`; `EditGuardedService` forwards it (it reads nothing on the server's library and needs no edit permission).
- Produces: `MockImmichService.setServerChecksums(_ checksums: Set<String>)`; mock reports `isDuplicate` for those, records `.bulkUploadCheck(count)` in `requests`.

- [ ] **Step 1: Failing tests**
  - `APIKeyPermissionTests`: add `("checkBulkUpload", .backup)` style entry — change the operations table to carry an `APIKeyAccess` level instead of a Bool; assert `APIKeyAccess.backup.permissions == readOnly + changes + ["asset.upload"]`.
  - `BulkUploadCheckTests.testLiveRequestAndDecoding`: stub transport returns `{"results":[{"id":"0","action":"reject","reason":"duplicate","assetId":"s1","isTrashed":false},{"id":"1","action":"accept"}]}`; assert request path `/assets/bulk-upload-check`, JSON body `{"assets":[{"id":"0","checksum":"a"},{"id":"1","checksum":"b"}]}`, results `[("0", true, "s1", false), ("1", false, nil, false)]`.
  - `testRejectForUnsupportedFormatIsNotADuplicate`: `{"id":"0","action":"reject","reason":"unsupported-format"}` → `isDuplicate == false`.
  - `testMockMarksKnownChecksums`.
- [ ] **Step 2: Run, verify failures** — `swift test --filter 'BulkUploadCheckTests|APIKeyPermissionTests'`
- [ ] **Step 3: Implement** Live call with `rawPOST(path:json:operationID: "checkBulkUpload")` (generator filter unchanged), batches are the caller's job; `KeySetupView` texts for `.backup`: title "View, Organize and Back Up"; allows "Everything in View and Organize, plus backing up this iPhone"; refuses "Can't change your account or other people's libraries"; detail footer as for `.organize` plus "It can also upload photos to your library." (all with Norwegian lines).
- [ ] **Step 4: Run tests, all three checks**
- [ ] **Step 5: Commit** — "Add the backup API key level and bulk upload check"

### Task 2: Photo library source and selection

**Files:**
- Create: `Sources/ImmichKit/Backup/PhotoLibrarySource.swift` (protocol + value types)
- Create: `Sources/ImmichKit/Backup/BackupSelection.swift`
- Create: `Sources/ImmichKit/Backup/BackupResourcePolicy.swift`
- Create: `Sources/ImmichKit/Backup/PhotoKitLibrarySource.swift` (`#if canImport(Photos)`)
- Create: `Tests/ImmichKitTests/Backup/FakePhotoLibrary.swift`
- Test: `Tests/ImmichKitTests/Backup/BackupSelectionTests.swift`, `BackupResourcePolicyTests.swift`

**Interfaces:**
- Produces:
  - `public enum DeviceResourceType: String, Sendable, Codable { case photo, fullSizePhoto, pairedVideo, fullSizePairedVideo, video, fullSizeVideo, other }`
  - `public struct DeviceResource: Sendable, Hashable { public let type: DeviceResourceType; public let filename: String }`
  - `public struct DeviceAsset: Sendable, Hashable { public let id: String; public let isVideo: Bool; public let creationDate: Date; public let modificationDate: Date; public let isFavorite: Bool; public let duration: TimeInterval; public let resources: [DeviceResource] }`
  - `public struct DeviceAlbum: Sendable, Hashable, Identifiable { public let id: String; public let title: String; public let count: Int }`
  - `public protocol PhotoLibrarySource: Sendable { func authorization() async -> PhotoAccess; func albums() async -> [DeviceAlbum]; func assetIDs(inAlbum id: String) async -> Set<String>; func asset(_ id: String) async -> DeviceAsset?; func read(_ resource: DeviceResource, of assetID: String, allowNetwork: Bool, onData: @Sendable (Data) -> Void) async throws }` with `public enum PhotoAccess: Sendable { case full, limited, denied }`
  - `public struct BackupSelection: Codable, Sendable, Equatable { public var included: Set<String>; public var excluded: Set<String>; public func assetIDs(in source: some PhotoLibrarySource) async -> Set<String> }`
  - `public enum BackupResourcePolicy { public static func upload(from resources: [DeviceResource]) -> [DeviceResource] }`
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Failing tests**
  - `BackupResourcePolicyTests`: `[photo]→[photo]`; `[photo, other, fullSizePhoto]→[fullSizePhoto]`; `[photo, pairedVideo]→[photo, pairedVideo]`; `[photo, other, fullSizePairedVideo, pairedVideo, fullSizePhoto]→[fullSizePhoto, fullSizePairedVideo]`; `[video]→[video]`; `[video, fullSizeVideo]→[fullSizeVideo]`; `[other]→[]`.
  - `BackupSelectionTests.testIncludedMinusExcluded`: albums A {1,2,3}, B {3,4}, S {2}; included {A,B}, excluded {S} → {1,3,4}.
  - `testNothingIncludedIsEmpty`; `testUnknownAlbumIDsAreIgnored`.
- [ ] **Step 2: Run, verify failures**
- [ ] **Step 3: Implement** the policy (photo side: `fullSizePhoto` else `photo`; motion side: `fullSizePairedVideo` else `pairedVideo`; video: `fullSizeVideo` else `video`), the selection, the fake (dictionary-backed, configurable read failures and per-call `allowNetwork` recording), and `PhotoKitLibrarySource` (albums = user albums + smart albums Recents, Favorites, Screenshots, Videos, Live Photos with `estimatedAssetCount`; `read` via `PHAssetResourceManager.requestData` with `isNetworkAccessAllowed = allowNetwork`; maps `PHAssetResourceType`). No change requests.
- [ ] **Step 4: Run tests, all three checks**
- [ ] **Step 5: Commit** — "Add the photo library source, album selection and resource policy"

### Task 3: Persistent backup index

**Files:**
- Create: `Sources/ImmichKit/Backup/BackupIndex.swift`
- Test: `Tests/ImmichKitTests/Backup/BackupIndexTests.swift`
- Modify: `Sources/ImmichUI/Root/RootModel.swift` (clear on sign-out; directory per account like `cacheDirectory(for:)`, under Application Support, not Caches)

**Interfaces:**
- Produces:
  - `public enum BackupState: Codable, Sendable, Equatable { case pending(reason: PendingReason), backedUp(serverAssetID: String), failed(reason: String) }`, `public enum PendingReason: String, Codable, Sendable { case notChecked, needsUpload, waitingForWiFi }`
  - `public struct BackupEntry: Codable, Sendable, Equatable { public var modificationDate: Date; public var checksums: [DeviceResourceType: String]; public var state: BackupState }`
  - `public actor BackupIndex { public init(directory: URL); public func entry(for assetID: String) -> BackupEntry?; public func set(_ entry: BackupEntry, for assetID: String); public func selection() -> BackupSelection; public func setSelection(_ s: BackupSelection); public func save() throws; public func clear() }`
- Consumes: `BackupSelection` (Task 2).

- [ ] **Step 1: Failing tests** — round-trip through `save()` and a new `BackupIndex` on the same directory; `clear()` removes the file; two directories never see each other's entries; file written with `CacheProtection.writingOptions`; a corrupt file loads as empty (not a crash).
- [ ] **Step 2: Run, verify failures**
- [ ] **Step 3: Implement** — one JSON file `index.json`; saves are explicit (the scanner saves every 200 items and at the end).
- [ ] **Step 4: Run tests, all three checks**
- [ ] **Step 5: Commit** — "Add the persistent per-account backup index"

### Task 4: Scanner — hash, check, record

**Files:**
- Create: `Sources/ImmichKit/Backup/Checksum.swift` (`public struct SHA1Stream { public mutating func update(_ data: Data); public func base64() -> String }`)
- Create: `Sources/ImmichKit/Backup/BackupScanner.swift`
- Create: `Sources/ImmichKit/Backup/BackupNetwork.swift` (`public protocol NetworkConditions: Sendable { var isOnCellular: Bool { get async } }`, `NWPathMonitor` implementation, `BackupSettings { photosOnCellular = false; videosOnCellular = false }` stored in `UserDefaults` keys `backup.photosOnCellular`, `backup.videosOnCellular`)
- Test: `Tests/ImmichKitTests/Backup/BackupScannerTests.swift`

**Interfaces:**
- Produces: `public struct BackupCounts: Sendable, Equatable { public var total, backedUp, pending, failed: Int; public var waitingForWiFi: Int }` (invariant `total == backedUp + pending + failed`)
- Produces: `public actor BackupScanner { public init(source: some PhotoLibrarySource, service: any ImmichService, index: BackupIndex, network: any NetworkConditions, settings: BackupSettings); public func scan(progress: @Sendable (BackupCounts, Int /*checked*/) -> Void) async throws -> BackupCounts; public func counts() async -> BackupCounts }`
- Consumes: Tasks 1–3.

- [ ] **Step 1: Failing tests** (fake library + `MockImmichService.setServerChecksums`)
  - `testRecognisesItemsAlreadyOnServer`: 3 photos, 2 on server → counts `(total 3, backedUp 2, pending 1, failed 0)`; checks sent in one `bulkUploadCheck`.
  - `testUnchangedItemsAreNotRehashedOnTheNextScan`: second scan reads 0 resources.
  - `testEditedItemIsRecheckedAndPendingWhenServerLacksNewVersion` (Review Focus).
  - `testLivePhotoIsBackedUpOnlyWhenBothResourcesAreOnServer` (Review Focus).
  - `testReadFailureMarksFailedAndContinues` (Review Focus): reason string non-empty, other items still counted.
  - `testCellularOffDoesNotAllowNetworkReads`: on cellular with both switches off → every `read` call had `allowNetwork == false`; items needing iCloud become `waitingForWiFi`.
  - `testCountsInvariant` over a mixed library.
  - `testBatchesOf500` with 1 200 items → 3 check requests.
  - `testCancellationSavesProgress`: cancel mid-scan, new scanner on same index resumes without re-reading recorded items.
  - `testSHA1Base64` known vector: `"abc"` → `"qZk+NkcGgWq6PiVxeFDCbJzQ2J0="`.
- [ ] **Step 2: Run, verify failures**
- [ ] **Step 3: Implement** — selection from the index; per item: skip if entry exists with same `modificationDate` and checksums for all policy resources; else read each policy resource (network allowed per the cellular rule; a read that needs iCloud but isn't allowed → `pending(.waitingForWiFi)`), batch checksums (id = `"\(assetID)|\(type.rawValue)"`), item is `backedUp` only if every resource is a duplicate (use the photo resource's server ID), else `pending(.needsUpload)`; progress after each item; save every 200.
- [ ] **Step 4: Run tests, all three checks**
- [ ] **Step 5: Commit** — "Recognise photos already on the server by checksum"

### Task 5: Backup screen, album picker, entry point

**Files:**
- Create: `Sources/ImmichUI/Backup/BackupModel.swift` (`@MainActor @Observable`, owns scanner, exposes counts, progress, access, selection, settings; `scan()`, `cancel()`)
- Create: `Sources/ImmichUI/Backup/BackupView.swift`, `Sources/ImmichUI/Backup/BackupAlbumPicker.swift`
- Modify: `Sources/ImmichUI/Root/ImmichRootView.swift` (account menu "Backup" → sheet), `RootModel`/`ImmichSession` (create `BackupModel` per session with `PhotoKitLibrarySource` on iOS)
- Modify: `nb.lproj/Localizable.strings`
- Test: `Tests/ImmichKitTests/Backup/BackupModelTests.swift`

**Interfaces:**
- Consumes: `BackupScanner`, `BackupIndex`, `BackupSelection`, `BackupSettings`, `PhotoLibrarySource` (Tasks 2–4).

- [ ] **Step 1: Failing tests** — model with fake source: `scan()` publishes counts; selection change persists to the index and triggers a rescan; denied access shows `access == .denied` and no scan; `cancel()` stops progress.
- [ ] **Step 2: Run, verify failures**
- [ ] **Step 3: Implement the screens** (owner sees simulator screenshots before commit):
  - Backup: albums row ("Recents · 1 excluded" → picker); counts rows Total / On Server / Remaining (Remaining shows "waiting for Wi-Fi" when relevant); a "Check Now" button with progress "Checking 4 210 of 12 958"; failed items section with reasons; footer "Bloom never deletes photos from your iPhone."; two cellular switches (off by default); note "Uploading comes in a later update" while Phase 2 isn't built.
  - Album picker: list with counts; tap cycles Included → Excluded → neither, shown with checkmark / minus SF Symbols; "Recents" suggested on first setup.
  - Limited access: banner explaining only selected photos are visible, with a button to the iOS settings.
- [ ] **Step 4: Run tests, three checks, simulator screenshots for the owner**
- [ ] **Step 5: Commit** — "Show which photos are already backed up"

---

## Later phases (own plans, after Phase 1 is on the phone)

- **Phase 2 — Upload in the foreground:** integration test against the owner's v3.3.6 server first (`checkBulkUpload`, `POST /assets` with `x-immich-checksum`, `livePhotoVideoId`); staging folder; multipart `uploadAsset`; Live Photos motion-first; `duplicate` counts as success; failure reasons and retry.
- **Phase 3 — Background:** background `URLSession` upload tasks from staged files, `BGAppRefreshTask` / `BGProcessingTask` scheduling, iOS 26 `BGContinuedProcessingTask` for the first run, app-target setup steps (background modes, task identifiers) for the owner.
- **Phase 4 — Polish:** Library status line like Photos, details list of remaining items, first-run guidance.
