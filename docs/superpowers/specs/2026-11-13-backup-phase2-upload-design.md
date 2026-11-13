# Backup phase 2: upload while the app is open — design

Status: draft for the owner's approval, 2026-11-13. Builds on
`docs/superpowers/specs/2026-11-13-backup-design.md` (the overall backup design, approved) and on
Phase 1 (recognition), which is on main and confirmed working on the owner's iPhone.

## Intent

Phase 1 tells the owner which photos are already on the server. Phase 2 makes Bloom actually back
up the rest, so the owner can stop depending on the Immich app. It uploads only while Bloom is open;
Phase 3 moves the same work into the background. Phase 2 is built so that Phase 3 reuses it, not
replaces it.

## Goals

- A **"Backup" on/off switch**. While it is on and Bloom is in the foreground (any screen), Bloom
  checks the selected albums and uploads what the server lacks, quietly, without the user starting it.
- Uploads are **identical to what the Immich app uploads** (same resource, same bytes, same checksum),
  so nothing the Immich app already uploaded is uploaded twice.
- **Live Photos** arrive on the server as one Live Photo (photo linked to its motion video).
- **Deleted on the server is shown, not undone** (owner's choice "C"): items that were on the server
  and are now in its trash or gone are counted under "Deleted on Server", never re-uploaded
  automatically, and can be restored or re-uploaded with an explicit button.
- The counts always add up: Total = On Server + Remaining + Deleted on Server + Problems.
- Every item that is not on the server shows why (waiting for Wi-Fi, uploading, failed with reason,
  deleted on server).

## Anti-goals (failure even if it "works")

- Deleting or modifying anything in the photo library, or deleting anything on the server.
  (Restoring from the server's trash is allowed: it is the user's explicit "re-upload" choice.)
- An item silently missing from the counts or silently never uploaded.
- Duplicates on the server, including a Live Photo uploaded as two separate assets.
- Re-uploading something the user deleted in Immich without being asked.
- Using cellular data for a media type whose cellular switch is off.

## Non-goals for Phase 2

- Background uploads, background refresh, `BGContinuedProcessingTask` (Phase 3).
- A status line in the Library, first-run guidance (Phase 4).
- Parallel uploads, resumable/chunked uploads, notifications, albums on the server.

## Decisions made with the owner

- **Deleted on the server → option C**: re-check every scan; trashed or gone items go to a separate
  "Deleted on Server" row with a "Re-upload" action; nothing happens automatically.
- **When uploads run → option A**: one switch; with it on, checking and uploading run whenever the app
  is in the foreground, on any screen. The same switch drives the background work in Phase 3.
  The screen is kept awake only while the Backup screen is open (as in Phase 1).
- **How uploads are made → staged file + URLSession upload task** (chosen by Claude, the owner handed
  over the how; see Approaches).

## Approaches considered (how uploads are made)

- **1. Staged file + `URLSession.uploadTask(with:fromFile:)` (chosen).** Each resource is read from
  PhotoKit into a file in a staging folder, the multipart body is written to a file, and a foreground
  `URLSession` uploads it. Large videos never sit in memory, and Phase 3 hands the same files to a
  background session.
- **2. The generated OpenAPI client's `uploadAsset`.** Builds the body in memory and cannot run in a
  background session. Rejected (large videos, Phase 3 would redo it).
- **3. Background `URLSession` now.** That is Phase 3 and needs app-target setup (background modes);
  much harder to test. Rejected for Phase 2.

## How it works

### States (extends Phase 1's index)

`BackupState` gains **`deletedOnServer`** next to `pending`, `backedUp` and `failed`. Because a Live
Photo is two server assets, the index stores **per resource** what the server knows (server asset ID,
and for `deletedOnServer` whether that half is trashed or gone); `backedUp(serverAssetID:)` keeps the
photo's (or only) asset ID for display. Phase 1 indexes migrate on load: existing `backedUp` entries
are kept and get their per-resource IDs filled in by the next re-check.
Pending reasons stay `notChecked`, `needsUpload`, `waitingForWiFi` in the index. *Claude's call:*
"uploading" and "will retry (back-off)" are uploader status in memory only, shown under Remaining;
back-off and the per-session retry count reset at relaunch.

### Re-checking what is on the server (option C)

Each scan re-checks `backedUp` items by their stored checksums (no reads from the library; about
26 requests of 500 for 13 000 items):

- server still has it, not trashed → stays `backedUp`
- duplicate but `isTrashed == true` → `deletedOnServer(trashed: true, id)`
- server no longer has it (`accept`) → `deletedOnServer(trashed: false, nil)`
- a Live Photo counts as on the server only while **both** resources are (as in Phase 1); if either
  is trashed or gone, the item is `deletedOnServer`.

A `pending(.needsUpload)` item is never classified as deleted: only something Bloom saw on the server
before can be "deleted on server". Phase 1's rule "trashed duplicate counts as on server" is replaced
by this.

*Claude's call:* an item under Deleted on Server that is **edited on the phone** afterwards (new
modification date, new checksum) is treated as a new version and goes to `needsUpload`, as the
overall design decides for edits; untouched, it stays under Deleted on Server.

`deletedOnServer` items are re-checked too: if they reappear on the server (restored in the Immich
web app, or uploaded by another device), they go back to `backedUp`.

### Re-upload (the explicit action)

Per item and "Re-upload All" in the Deleted on Server list:
- trashed → restore from the server's trash (`POST /trash/restore/assets`, already used by Bloom's
  Recently Deleted; needs `asset.delete`, which the Back Up key level includes) → `backedUp`.
- gone → `pending(.needsUpload)`, then uploaded like any other item.
- *Claude's call:* a **Live Photo** is handled per half: trashed halves are restored, gone halves are
  uploaded. Gone photo → upload it with `livePhotoVideoId` = the existing motion asset. Gone motion
  with the photo still there → upload the motion, then link it with `PUT /assets/{id}`
  (`updateAsset`, field `livePhotoVideoId`). Never upload a half the server still has.

### Uploading

A new actor in ImmichKit (`BackupUploader`) works through `pending(.needsUpload)` items, **one item
at a time**, newest first (so today's photos are on the server first).

For each item:
1. Re-read the asset from PhotoKit. If its modification date changed since the checksums were made,
   send it back to the scanner (it will be re-hashed and re-checked) instead of uploading.
2. Pick the resources with Phase 1's `BackupResourcePolicy`.
3. For each resource, stream it from PhotoKit into a staging file while computing SHA1. If the
   checksum differs from the stored one, discard and send the item back to the scanner.
4. Write the multipart body to a second staging file and upload it with `x-immich-checksum`.
   Fields: `assetData` (with the resource's original filename and MIME type), `fileCreatedAt`
   (asset creation date), `fileModifiedAt` (asset modification date, also for edited versions),
   `filename`, `isFavorite` (the phone's favourite flag), `duration` for videos, and
   `livePhotoVideoId` for the photo of a Live Photo. *Claude's call:* no `visibility`, `metadata` or
   `sidecarData`. If the owner's v3.3.6 server rejects a field as specified, the builder may adjust
   the encoding (one place, covered by the fixture test).
5. **Live Photo**: the motion video first, then the photo with `livePhotoVideoId` = the motion
   asset's ID. If the motion video was already on the server (a `duplicate`), use that ID.
6. Response `201 created` or `200 duplicate` → `backedUp(serverAssetID)` of the photo (or the only)
   resource. Delete the staging files.

iCloud: reading follows the cellular switches as in Phase 1 (network for iCloud originals only on
Wi-Fi unless the switch for that type is on). Uploads follow the same switches: on cellular with the
switch off, the item becomes `pending(.waitingForWiFi)` and the request is also made with
`allowsCellularAccess = false` as a second guard.

### Security

- The upload request goes to the signed-in server only, through the same no-redirect-to-other-origin
  rule as every Bloom request (`SameOriginRedirects`) and the existing http policy.
- The API key goes in the `x-api-key` header only; never in a URL, a staged file or a log.
- Staging files live in the account's protected container directory with
  `.completeUntilFirstUserAuthentication`, are deleted after each item, and the staging folder is
  emptied at launch and at sign-out (after the uploader is stopped, as the scanner is today).

### Errors and retry

- **Network lost / timeout / 5xx / 429** → item stays pending with reason "Will retry" and is retried
  with back-off (seconds → minutes); the run continues with other items when it makes sense.
- **401/403** → the run stops; the Phase 1 message about the key's permissions is shown. The switch
  is not blocked up front: Phase 1 already sends a probe check before any work and shows that message
  at once. The `backup` key level (Phase 1) has `asset.upload` and `asset.delete`.
- **Other 4xx** (e.g. unsupported format) → `failed(reason)` with the server's message.
- **Read failures** (iCloud download failed, resource gone) → `failed(reason)`, as in Phase 1.
- **Not enough free space** to stage the item → `failed("Not enough free space on the iPhone")`.
- Failed items have **"Try Again"** (per item and all). A failed item is not retried automatically
  more than a few times per app session, so a permanently broken file doesn't loop.
- An upload interrupted by the app leaving the foreground is simply retried next time; the server's
  checksum check makes that safe.

### When it runs

With the switch on: when the app becomes active, when the Backup screen is opened, and when the photo
library changes (PhotoKit change observer, debounced), run a scan of the selection, then upload. When
the app leaves the foreground, the current upload is cancelled (Phase 3 changes this). *Claude's
call:* a library change during an upload never interrupts it: the current item finishes, then the
run rescans before the next item (so a long video isn't restarted while the camera is in use). Switch off →
nothing runs; Check Now on the Backup screen still works as in Phase 1. The switch is per device,
off by default, and turning it on with no album selected opens the album picker.

## Screens

Backup screen, changes from Phase 1 (everything localised, Norwegian lines added):

```
 Sikkerhetskopi                         Ferdig
 ┌───────────────────────────────────────────┐
 │ Sikkerhetskopi                     [ ● ]  │   ← new switch
 └───────────────────────────────────────────┘
 ┌───────────────────────────────────────────┐
 │ Album                         Nylig  >    │
 └───────────────────────────────────────────┘
 ┌───────────────────────────────────────────┐
 │ Totalt                           12 960   │
 │ På serveren                      12 941   │
 │ Gjenstår                             15   │   (· 3 venter på Wi-Fi)
 │ Slettet på serveren                   3 > │   ← new, opens list
 │ Problemer                             1 > │
 └───────────────────────────────────────────┘
   Laster opp 4 av 15 · IMG_1234.HEIC          ← progress while uploading
 ┌───────────────────────────────────────────┐
 │ Sjekk nå                                  │
 └───────────────────────────────────────────┘
   Bloom laster opp mens appen er åpen.
   Bloom sletter aldri bilder fra iPhone.
```

- "Slettet på serveren" list: thumbnail + date per item, "I papirkurven" or "Slettet" as subtitle,
  "Last opp igjen" per item and "Last opp alle igjen".
- "Problemer" list: reason per item, "Prøv igjen" per item and for all.
- The phrase "Uploading comes in a later update" is removed.

## Verification

- Unit tests with the mock service and the fake photo library: re-check transitions (backedUp ↔
  deletedOnServer, Live Photo with one half trashed), upload order, Live Photo motion-first and
  linking (including motion already a duplicate), changed-while-uploading goes back to the scanner,
  checksum mismatch, each error class, cellular rules, re-upload restore vs upload, counts add up,
  stop at sign-out leaves no staging files.
- The multipart body builder is tested byte-for-byte against a fixture.
- An integration test (skips without `IMMICH_URL`/`IMMICH_API_KEY`) uploads a tiny generated image,
  checks `201`, uploads it again expecting `200 duplicate`, and leaves it on the server (no delete
  calls; documented so the owner can remove it by hand).
- **Phone check by the owner** before Phase 2 counts as done, because the API key never reaches the
  agent's environment: take a new photo, a Live Photo and a short video, switch on, watch them appear
  in Immich (Live Photo as one item, video plays, dates right), then a second check finds nothing to do.

## Constraints

- As the overall design and `CLAUDE.md`: Swift concurrency, shared state in actors, ImmichKit for
  logic, ImmichUI for views, `#Preview` with mocks, `tr()` with Norwegian, three checks per commit.
- Spec v3.4.0 (`POST /assets`, operation `uploadAsset`, multipart `AssetMediaCreateDto`); the owner's
  server is v3.3.6. The spec types `duration` as an integer; older servers took a string
  ("HH:MM:SS.ffffff") — the phone check with a video decides, the builder keeps the encoding in one place.
- `uploadAsset` is not in the generator filter; the body is built by hand like `checkBulkUpload`.

## Left to the builder

- Exact back-off schedule and the per-session retry cap for failed items.
- How the PhotoKit change observer is debounced and wired; how the uploader and scanner share one run.
- MIME type and filename source per resource (from `PHAssetResource`).
- Staging folder layout and the free-space margin.
- How the per-item "uploading" status reaches the UI (throttled like Phase 1's progress).
