# Backup phase 3: backup in the background — design

Status: draft for the owner's approval, 2026-11-14. Builds on
`docs/superpowers/specs/2026-11-13-backup-design.md` (overall backup design, approved) and Phase 2
(`docs/superpowers/specs/2026-11-13-backup-phase2-upload-design.md`, on main, tested on the owner's iPhone).

## Intent

Bloom should replace the official Immich app. The last thing missing is backup without opening Bloom:
with the Backup switch on, photos taken during the day must reach the server **within 24 hours** without the
owner doing anything ("a photo taken in the day can upload in the evening or at night"). Opening Bloom still
uploads at once, as in Phase 2.

## Goals

- With the switch on and Bloom not open, new photos and videos in the selected albums are uploaded within
  24 hours, typically overnight while charging, plus whenever iOS grants short background time.
- Uploads that have started finish even if Bloom is closed, suspended or killed by the system.
- Phase 2 behaviour stays: opening Bloom checks and uploads at once; Deleted on Server (option C), Try Again,
  cellular switches, Live Photos as one item, never deleting anything.
- The status screen tells the truth about background work ("Last backup: tonight 03:12", items uploading).
- Built so that Apple's PhotoKit background upload extension can replace the transport later (see Approaches).

## Anti-goals

- Everything from Phase 1 and 2 (deleting, silent misses, duplicates, re-uploading deletions, cellular when off).
- Losing an upload's result because the app was suspended before it was recorded.
- A background job that eats battery: heavy work (hashing, iCloud downloads) only while charging.
- The API key in URLs, staged files or logs.

## Non-goals

- The user-started long-running first run with Lock Screen progress (`BGContinuedProcessingTask`). The first
  big run is done with the app open, as in Phase 2; nightly jobs finish what's left. Can be added later.
- Apple's PhotoKit background upload extension (needs server support Immich doesn't have yet).
- Notifications. Real-time upload of a photo seconds after it is taken while Bloom is closed (iOS doesn't
  wake apps for new photos without the PhotoKit extension).

## Decisions made with the owner

- **Target latency:** at most 24 hours; day photos uploading in the evening or at night is fine.
- **Approach B:** background URL session + nightly processing task + app refresh; no long-running first-run task.
- **Prepare for the PhotoKit extension:** keep the upload transport behind a boundary so it can be swapped.

## Approaches considered

- **A. Everything in the original design**, including `BGContinuedProcessingTask` for a user-started first run
  with Lock Screen progress. Most work; the extra part is used once. Not chosen (can be added later).
- **B. Background URL session + BGProcessingTask + BGAppRefreshTask (chosen).** Meets 24 hours with less code.
- **C. PhotoKit background upload extension** (`PHBackgroundResourceUploadExtension`, iOS 26.1;
  `PHBackgroundResourceUploadJobExtension`, iOS 27). The system finds new assets, downloads from iCloud and
  uploads on its own schedule — the best long-term option. Not possible now: the system uploads the raw
  resource as the request body, while Immich's `POST /assets` needs `multipart/form-data` with fields. Immich has
  an open, unmerged PR for a raw resumable-upload endpoint (immich-app/immich#22385); the owner's server is
  v3.3.6 and the checked-in spec v3.4.0 has no such endpoint. Developers also report the extension not being
  scheduled when iCloud Photos is on (iOS 26.4). Revisit when Immich ships the endpoint.

## How it works

### One upload path for foreground and background

All uploads go through one **background `URLSession`**, also while Bloom is open. Phase 2's foreground upload
(`SameOriginRedirects.session.upload(for:fromFile:)` inside `uploadAsset`) is replaced for backup uploads. So
leaving the app no longer cancels an upload; iOS finishes it. The Phase 2 runner keeps deciding *when to scan
and enqueue*; it no longer cancels uploads when the app goes to the background.

- Session: `URLSessionConfiguration.background(withIdentifier:)`, one identifier per signed-in account (so a
  different account never receives another's results), `sessionSendsLaunchEvents = true`,
  `isDiscretionary = false`, a delegate that refuses cross-origin redirects like `SameOriginRedirects`.
- Cellular per request: `allowsCellularAccess` (and expensive/constrained access) from the switch for that
  media type, as in Phase 2.
- At most a small number of tasks in flight (builder: 2–4) and a staging budget (builder: ~2 GB); items beyond
  that wait in the index, not in the session.

### Transport boundary (for approach C later)

A protocol in ImmichKit, e.g. `BackupTransport`, with: enqueue an item's resources (with what the request needs),
report finished results (asset ID, created/duplicate, or error) to a sink that records them in the index, list
what is in flight, cancel all. Phase 3 implements it with the background session. A future PhotoKit-extension
transport implements the same protocol; the index, scanner, verdicts and UI don't change.

### The upload artifact

One staged **multipart body file per resource**: streamed from PhotoKit straight into the body file while
computing SHA‑1 in the same pass (Phase 2 writes the resource and then a second copy as the body). The body file
stays until its task's result is recorded, then it is deleted.

*Claude's call:* the scanner keeps hashing as in Phase 2 (the checksums are needed for the bulk check and option C
before anything is staged); the same-pass hash during staging *verifies* the staged bytes against the recorded
checksum. On a mismatch (the asset changed between scan and staging) the body is discarded and the item goes back
to the scanner, as in Phase 2 — never uploaded under a checksum the index didn't check.

### Results survive suspension and relaunch

These are the weak spots found in another open-source Immich client (Arrnav/photos-app, studied read-only;
see HANDOFF); Bloom does them correctly:

- The delegate and its result sink exist **before** the background session is created, so early events are
  never dropped.
- A task's result (status, response body → asset ID) is **persisted in the index before** anything else
  happens; `urlSessionDidFinishEvents` calls the system completion handler only after those writes finished
  (not after a fixed delay).
- Each task carries its item in `taskDescription` (asset ID, resource type, attempt). On launch, Bloom
  reconciles: tasks iOS still has stay; an item marked "uploading" with no task and no recorded result is
  requeued (the server's checksum dedupe makes a re-send safe); body files nothing refers to are deleted.
  Reconcile never deletes the body file of a task iOS still reports.
- The Phase 2 problem "launch cleanup empties Staging" is removed: cleanup only deletes unreferenced files.

### Live Photos

The two halves can't be chained reliably in the background (the photo needs the motion's server ID). So:
- the motion video is uploaded with `visibility=hidden` (Immich hides linked motion videos anyway; this keeps it
  hidden before the link exists);
- the photo is uploaded at the same time without `livePhotoVideoId`;
- once both IDs are known, Bloom links them with `PUT /assets/{id}` (`linkLivePhoto`, Phase 2) in the next wake
  (delegate wake, refresh, processing or foreground). Phase 2's `needsLink` marker keeps the item queued until
  linked, so a scan can't call it backed up early.
This adds one multipart field (`visibility`) to Phase 2's list, for motion halves only.

*Claude's calls:* a retry sends only the half without a known server ID (as Phase 2). A hidden motion video waits
on the server until the link succeeds; the link is retried at every wake and shows under Problems after the
Phase 2 retry rules give up. The link `PUT` is sent whenever `needsLink` is set, even if the photo came back as a
duplicate (setting the same `livePhotoVideoId` again is harmless).

### When work happens

- **Foreground (Phase 2):** opening Bloom, Check Now, library changes, network returning → scan + enqueue.
- **Nightly processing task** (`BGProcessingTaskRequest`, `requiresExternalPower = true`,
  `requiresNetworkConnectivity = true`): scan the selection (incremental), re-check (option C), stage and
  enqueue as many items as the budget and time allow, link Live Photos, record results. Ends cleanly on the
  expiration handler.
- **App refresh task** (`BGAppRefreshTaskRequest`, short): find new assets since last time via
  `PHPhotoLibrary.fetchPersistentChanges(since:)` with a stored `PHPersistentChangeToken` (full scan as
  fallback when the token is expired), enqueue a few small items that fit, link Live Photos, record results.
  No iCloud downloads and no large videos here.
- Both are rescheduled at the start of every run and when the app goes to the background, only while the
  switch is on. Turning the switch off cancels scheduled tasks and in-flight uploads.
- **Delegate wakes** (`handleEventsForBackgroundURLSession`): record results, then may enqueue the next small
  item if one is staged; no scanning.

*Claude's calls:*
- The processing and refresh tasks **enqueue and finish**; they don't wait for uploads. Results arrive through
  delegate wakes (or the next launch's reconcile). `setTaskCompleted` is called when staging/enqueuing is done or
  on expiration.
- The staging budget caps staged-but-unrecorded bodies in total. A large video backlog may take several nights on
  a slow connection; the 24-hour goal is for a normal day's photos, and the first big run is done with the app open.
- Uploads use a non-discretionary session: what has been enqueued finishes promptly, also on battery. Heavy work
  (hashing, iCloud downloads, staging large videos) only happens with the app open or in the processing task
  (charging); the refresh task enqueues only small, already-local photos.
- Cold launch: the session identifier encodes which account it belongs to (a stable, non-secret hash of server
  URL + user). The package can build the backup stack headlessly from the Keychain credentials and the account's
  index directory (no UI), recreate the session with its delegate, and hand the completion handler back once
  results are recorded. If the identifier matches no signed-in account, the session is invalidated and its
  results ignored.
- Phase 2's `uploadAsset` (foreground) stays for other callers; backup uploads use the background transport.

### Status screen

- "Uploading in the background: N" while tasks are in flight; "Last backup: <relative time>" from the last
  recorded success; existing counts unchanged (an uploading item counts under Remaining).
- A short explanation under the switch: Bloom backs up when it is open and at night while charging; iOS decides
  the exact time. A hint when Background App Refresh is off for Bloom
  (`UIApplication.backgroundRefreshStatus`).

### Sign-out

Cancel all tasks and invalidate the account's session, cancel scheduled tasks, stop the runner, then remove
staging and the index (Phase 2 order). Results arriving for a signed-out account's session identifier are
ignored.

### Security and privacy

- The key goes only in the `x-api-key` request header. iOS keeps background request headers for the task's
  lifetime in system storage; this is inherent to background uploads and goes into PRIVACY.md (en + nb).
- Staged files: `.completeUntilFirstUserAuthentication` (background work runs while the phone is locked after
  first unlock), excluded from iCloud backup, deleted after their result is recorded.

### App target (owner, in Xcode, with exact steps)

- Signing & Capabilities → Background Modes: *Background fetch* and *Background processing*.
- Info: `BGTaskSchedulerPermittedIdentifiers` with the two task identifiers.
- One line in the app's `App`: a scene/app-delegate hook the package provides (the builder chooses SwiftUI
  `.backgroundTask` scene modifiers or a `UIApplicationDelegateAdaptor`; `handleEventsForBackgroundURLSession`
  must be wired either way).

## Verification

- Unit tests with fakes for the session (task list, delegate events, relaunch), PhotoKit changes, clock and
  network: result persisted before completion handler; reconcile cases; Live Photo hidden motion + link later;
  refresh does no iCloud/large work; processing respects expiration; switch off cancels; sign-out isolation.
- On the phone (owner): trigger tasks from Xcode's debugger
  (`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"…"]`);
  take photos, close Bloom, leave it charging overnight, check Immich in the morning; kill Bloom mid-upload and
  see the upload finish; check a Live Photo is one item with no visible separate video.

## Constraints

- As before: Swift concurrency, actors, ImmichKit/ImmichUI split, `tr()` with Norwegian, `#Preview` with mocks,
  three checks per commit, unit tests use the mock service.
- iOS 26 deployment target; the owner's phone may run iOS 27 — use only APIs available on iOS 26.
- `uploadAsset` multipart format as in Phase 2, plus `visibility=hidden` for motion halves.

## Left to the builder

- Exact concurrency, staging budget, task identifiers and how much the refresh task may do.
- How the background session's delegate hands results to the index actor safely.
- Scene modifier vs app delegate adaptor for the app target hook.
- How the change token is stored (in the account's index directory).
