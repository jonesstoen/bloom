# Backup from the iPhone to Immich: design

Status: draft for the owner's approval, 2026-11-13.

## Intent

Bloom should replace the official Immich app completely: the owner wants only Bloom on the phone.
Today the Immich app backs up the camera roll automatically in the background; the first time, the
owner left it open until it finished. Bloom must do the same job at least as reliably, with an iOS
look instead of the Immich app's Material style. The Immich app's Backup screen (selected albums,
total / backed up / remaining counts, an on/off switch, details of what remains) is the starting
point for the screen.

## Goals

- Automatic backup of the photos and videos in the albums the user selects, in the background,
  without opening the app.
- A first run that recognises everything the Immich app already uploaded (about 12 958 items on the
  owner's server) without creating duplicates, and can be left running.
- Album choice with include **and** exclude: an item is backed up if it is in an included album and
  in no excluded album (for example "Recents" included, "Screenshots" excluded).
- A status screen the user can trust: total = backed up + remaining, and every item that is not
  backed up is listed with a reason.

## Anti-goals (failure even if it "works")

- **Deleting anything.** Bloom never deletes or modifies anything in the iPhone's photo library, and
  the backup never deletes anything on the server. Bloom only reads the library. The screen says so.
- **Items silently missing.** No item may disappear from the count without a visible reason
  ("couldn't be downloaded from iCloud", "server error", "waiting for Wi-Fi", ...).
- **Duplicates.** Items already on the server must be recognised, including those uploaded by the
  Immich app.

## Non-goals for the first version

- Freeing up space by deleting from the phone (maybe later, as a separate, explicit feature).
- Creating Immich albums that mirror the phone's albums.
- Notifications. Status is shown in the app.
- iPad, Mac, other people's libraries.

## Decisions made with the owner

- **Approach A** (below): uploads handed to iOS's background transfer service.
- **Cellular data**: two switches, "Use cellular data for photos" and "Use cellular data for
  videos", **both off by default**. When uploads wait for Wi-Fi the status screen says so.
- **Include and exclude albums**, as above.
- **First run** may take a while; progress must be clear.
- **Edited after backup**: the edited version is uploaded as a new asset; the original stays on the
  server next to it (what the Immich app does). This is not a duplicate in the anti-goal's sense.

## Calls made while writing (the owner can correct them)

- **"Total"** means the items in the included albums minus those in excluded albums; items outside
  the selection are not counted at all. On first setup the user picks albums, with "Recents" suggested.
- **iCloud downloads follow the cellular switches**: with the switch for that media type off, Bloom
  only asks PhotoKit for iCloud originals on Wi-Fi; otherwise the item waits ("waiting for Wi-Fi").
- **Large videos are in scope**, uploaded from a staged file by the background session (no chunking).
- **Removed from the phone after backup**: stays on the server; it simply leaves Bloom's counts.
- **One server and account at a time**, as Bloom works today; the index is cleared with sign-out.
- **v3.3.6 vs the v3.4.0 spec**: before building the upload, an integration test against the owner's
  server confirms `checkBulkUpload`, `POST /assets` with `x-immich-checksum` and `livePhotoVideoId`.

## What the spike established (2026-11-13, on the owner's iPhone, 40 mixed items)

A throwaway screen hashed every PhotoKit resource (SHA1, base64) and asked the server with
`POST /assets/bulk-upload-check` which it already had.

- Every one of the 40 items (newest, Live Photos, edited, oldest) was found on the server.
- The Immich app uploaded **the current version** of each item:
  - unedited photo: `.photo`; edited photo: `.fullSizePhoto`
  - Live Photo: `.photo` + `.pairedVideo`; edited Live Photo: `.fullSizePhoto` + `.fullSizePairedVideo`
  - video: `.video` (edited videos were not in the sample; assume `.fullSizeVideo`, verify)
  - other resources (adjustment data, the unidentified resource type 16) were never what was uploaded.
- Bloom must upload exactly the same resource to keep checksums identical.
- Reading took 0.33 s per item on average including iCloud downloads (slowest 4.6 s). The full first
  run over ~13 000 items is estimated at 1–2 hours, mostly iCloud downloads.
- Checksum is the only way to recognise existing items: the v3.4.0 API has no device asset ID or
  device ID (no `/assets/exist`, no device fields on upload or on assets).

## Approaches considered

- **A. iOS background transfers (chosen).** Bloom exports each item's file(s) to a staging folder and
  hands the upload to a background `URLSession`, which iOS continues after the app is suspended or
  quit, respecting cellular settings. `BGAppRefreshTask` (short) finds new items and enqueues them;
  `BGProcessingTask` (longer, typically at night while charging) does hashing and iCloud downloads;
  the first run uses iOS 26's `BGContinuedProcessingTask`, started by the user, with system progress
  on the Lock Screen and in the Dynamic Island so the app need not stay open. Most reliable, most work,
  and needs bounded staging space.
- **B. Only while the app runs or iOS grants processing time.** Simpler; a photo taken in the morning
  may wait until night. Rejected: does not match "automatic".
- **Foreground only.** Rejected: not automatic.

## How it works (decided parts)

- **Permissions**: photo library read access (`NSPhotoLibraryUsageDescription`, already in the app
  target, English and Norwegian); the API key needs `asset.upload`. A new access level
  "View, Organize and Back Up" in `APIKeyAccess` adds `asset.upload` and is checked by
  `APIKeyPermissionTests`. Limited photo access must be handled (only selected items are visible).
- **Local index**: a persistent store, per account, of PhotoKit local identifier → modification date,
  chosen resource(s), SHA1 checksum(s), state (pending, uploaded, failed with reason, excluded) and the
  server asset ID. Hashes are computed once and reused while the item's modification date is unchanged
  (an edit changes the current version, so the item is re-checked).
- **Recognising existing items**: batches of checksums to `checkBulkUpload`; `duplicate` marks the
  item as backed up (keeping the server asset ID). Uploads also send `x-immich-checksum`.
- **Upload**: `POST /assets` multipart with `assetData`, `fileCreatedAt`, `fileModifiedAt`,
  `filename`, `duration` for videos and `isFavorite`; a `duplicate` response counts as success.
  Live Photos: upload the motion part first, then the photo with `livePhotoVideoId`.
- **Choosing the resource**: the current version per the spike table above.
- **Never delete**: no PhotoKit change requests anywhere in the backup code; no DELETE calls.
- **Security**: everything goes through the existing redirect-guarded session and the http policy;
  the API key never appears in staged files or URLs.

## Screens (iOS style, to be mocked up before building)

- **Backup** (from the account menu, and a status line in the Library like Photos' "Updated just now"):
  albums row ("Recents, 1 excluded" → album picker), counts total / backed up / remaining, on/off
  switch, Wi-Fi/cellular state, "Bloom never deletes photos from your iPhone", and a details list of
  remaining and failed items with reasons and a retry.
- **Album picker**: phone albums with item counts; each album is Included, Excluded or neither.
- **Settings**: the two cellular switches.
- **First run**: a clear progress view ("Checking 4 210 of 12 958 · downloading from iCloud") that
  hands over to the system's continued-processing progress when the user leaves the app.

## Constraints

- iOS 26 app target, Swift package architecture as in `CLAUDE.md` (models in ImmichKit, views in
  ImmichUI, shared state in actors, everything localised with `tr()`).
- Immich v3.4.0 API spec; the owner's server is v3.3.6.
- The app target (outside this repo) needs the background modes and task identifiers; the owner adds
  them in Xcode with exact instructions.
- Unit tests with the mock service; PhotoKit behind a protocol so the logic is testable without a
  photo library.

## Left to the builder

- Store technology for the index (SQLite, Core Data or files), staging-folder limits and cleanup.
- Batch sizes, concurrency, retry and back-off policy.
- How background refresh and processing tasks are scheduled, within iOS's rules.
- Exact layout of the screens, after the owner has seen mockups.
- Splitting the work into phases (e.g. index and recognition first, then upload, then background).
