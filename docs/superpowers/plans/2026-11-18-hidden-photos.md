# Hidden Photos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide/unhide photos (Immich Archive) and show them in a Face ID-locked "Hidden" collection.

**Architecture:** One new service write `setHidden(assetID:hidden:)` (raw PUT like `setFavorite`). The grid model removes confirmed hidden/unhidden assets via `LocalLibraryEdits`, like trash does. A small `HiddenAlbumLock` (`@Observable`, `@MainActor`) wraps `LAContext` behind a protocol so it is testable.

**Tech Stack:** Swift 6, SwiftUI, LocalAuthentication, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-18-hidden-photos-design.md`

## Global Constraints

- Text via `tr()` + `Sources/ImmichUI/Resources/nb.lproj/Localizable.strings`:
  "Hide"="Skjul"; "Unhide"="Vis"; "Hidden"="Skjult"; "Use Face ID for Hidden"="Bruk Face ID for Skjult";
  "In Immich on the web, these photos are in Archive."="I Immich på nettet ligger disse bildene i Arkiv.";
  "Unlock Hidden"="Lås opp Skjult"; "Couldn't hide %@ items. Please try again."="Kunne ikke skjule %@ objekter. Prøv igjen.";
  "Couldn't unhide %@ items. Please try again."="Kunne ikke vise %@ objekter igjen. Prøv igjen."; "View Album"="Vis album" is NOT needed.
  If a key `"Archive"` becomes unused, remove its nb entry only if `LocalizationTests` require it.
- Writes only through `EditGuardedService` (Allow Changes). Never trash or delete.
- Shared views compile on macOS; `LAContext` exists on macOS too. Every new view has a `#Preview`.
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; all three checks before each commit.

## Review Focus

- Hiding from an album/person/search grid: the asset leaves that grid too (it is no longer `timeline`), but the snapshot cache of the main Library must not resurrect it on next launch.
- Hide when the PUT succeeded but the confirming GET failed: treated as uncertain, stays selected, retry is idempotent.
- App goes to background inside Hidden (incl. viewer open): content must be covered/locked on return.
- Setting off: Hidden opens without prompt; device without passcode: opens without prompt (no dead end).
- Allow Changes off: Hide/Unhide not offered (same gate as favorites).

---

### Task 1: Service write

**Files:** `Sources/ImmichKit/Service/ImmichService.swift`, `LiveImmichService+Detail.swift`, `Sources/ImmichKit/Editing/EditingPermission.swift` (EditGuardedService), `Sources/ImmichKit/Mock/MockImmichService.swift`; tests next to existing setFavorite/EditGuarded tests.

**Produces:** `func setHidden(assetID: String, hidden: Bool) async throws -> Asset` on `ImmichService` (protocol requirement, no default implementation that silently succeeds).

- [ ] Tests: live request body is exactly `{"visibility":"archive"}` / `{"visibility":"timeline"}` on `PUT /assets/{id}` (use the existing URLProtocol/stub pattern from the setFavorite test); EditGuarded throws `.editingOff` when off and calls nothing; mock flips `isArchived` and the asset leaves `timeBuckets` for `.timeline` and appears for `.archive`.
- [ ] RED, implement, GREEN, three checks, commit "Hide and unhide a photo on the server".

### Task 2: Hide/Unhide in grids, selection and viewer

**Files:** `Sources/ImmichUI/Library/LocalLibraryEdits.swift`, `LibraryGridModel+Editing.swift`, `LibraryGridModel.swift` (reconcile like trash), `LibrarySelectionModel.swift`, `LibrarySelectionControls.swift`, `Sources/ImmichUI/Viewer/AssetViewer.swift` (+ whatever passes actions into it from `LibraryGridView.swift`); tests in the existing grid/selection model test files.

**Produces:** `LibraryGridModel.setHidden(_ assets: [Asset], hidden: Bool) async -> (confirmed: [String], failed: [String])`; `LibrarySelectionModel.setHidden(_ hidden: Bool) async`.

- [ ] Tests: hiding from a `.timeline` grid removes confirmed IDs from the grid and from the saved snapshot; unhiding from an `.archive` grid removes them there; a failing asset stays selected with the error string; Allow Changes off → actions absent (view-level gate; test the model guard if one exists).
- [ ] Implement: `LocalLibraryEdits.hiddenIDs`/`unhiddenIDs` (removed when they no longer match `options.visibility`), study the trash path (`moveToTrash`, `applyTrashOutcome`, reconcile in `LibraryGridModel.swift:~167`) and follow it rather than inventing a parallel cache rule. Selection menu: "Hide" in the existing `…` menu when the grid is not archive; "Unhide" when it is. Viewer More menu: "Hide"/"Unhide" (`eye.slash`/`eye`), dismissing to the next asset like trash does.
- [ ] RED, GREEN, three checks; reviewer (opus) pass on the diff; commit "Hide photos from the library and unhide them".

### Task 3: Hidden collection, lock and setting

**Files:** create `Sources/ImmichUI/Collections/HiddenAlbumLock.swift`; modify `CollectionsView.swift` (row ~247), `Sources/ImmichUI/Root/ImmichRootView.swift` (toggle next to Allow Changes, `@AppStorage("hiddenRequiresAuthentication")` default true), strings; tests `Tests/.../HiddenAlbumLockTests.swift`.

**Produces:** `protocol DeviceAuthenticator: Sendable { func canAuthenticate() -> Bool; func authenticate(reason: String) async -> Bool }`, `LADeviceAuthenticator` (`.deviceOwnerAuthentication`), `@MainActor @Observable final class HiddenAlbumLock { var isUnlocked: Bool; func unlock(requiresAuthentication: Bool) async; func lock() }`.

- [ ] Tests (fake authenticator): setting off → unlocked without calling authenticate; cannot authenticate → unlocked; success → unlocked; failure/cancel → stays locked; `lock()` relocks.
- [ ] Implement: row "Hidden" `eye.slash` + trailing `lock.fill` while locked. Destination shows a locked placeholder (`ContentUnavailableView(tr("Hidden"), systemImage: "eye.slash")` + "Unlock Hidden" button) until unlocked, prompting automatically on appear; content = `TimelineCollectionView` with archive options and the footer text. Relock on `onDisappear` of the destination and on `scenePhase != .active` (cover content immediately on `.inactive`).
- [ ] RED, GREEN, three checks, commit "Show hidden photos in a Face ID-locked Hidden collection".

Owner step (Xcode, after Task 3): add `NSFaceIDUsageDescription` = "Bloom bruker Face ID for å låse opp Skjult." to the ImmichPhotos target's Info.
