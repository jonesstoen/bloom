# How Bloom fits together

Bloom is the Swift package in this repository; the iOS app target only shows `ImmichRootView()`.
Open `Package.swift` in Xcode to browse just the package.

```
ImmichUI   SwiftUI screens and their @Observable models (main actor)
   │        LibraryGridModel, SearchModel, CollectionsModel, ViewerAssetModel …
   ▼
ImmichKit  ImmichService protocol ── EditGuardedService ── LiveImmichService / MockImmichService
   │        Timeline (actor), ImageLoader + DiskImageCache (actor), Prefetcher, CredentialStore
   ▼
ImmichAPI  client generated from openapi.json (swift-openapi-generator)
```

## Data flow

- **Sign-in.** `RootModel` restores the server URL and API key from the Keychain
  (`CredentialStore`) and builds an `ImmichSession`: one service, one image loader and the Library
  model, shared by all tabs. Signing out discards the session and its caches.
- **Library.** `Timeline` (an actor) loads the month buckets first (`GET /timeline/buckets`, counts
  only) and a month's assets when it comes near the screen. `LibraryGridModel` turns that into one
  continuous grid: loaded months show their photos, the others placeholders sized from the counts.
  The months are saved to disk (`TimelineSnapshotStore`), so the next launch shows the grid at once
  and revalidates it with the server.
- **Images.** Every thumbnail and preview goes through `ImageLoader`: memory cache, then disk cache
  (per connection), then one shared request per image. The `Prefetcher` loads thumbnails ahead of
  the scroll from the range of cells on screen.
- **Viewer.** Opens with the grid's thumbnail, loads the preview, then the full asset (EXIF, Live
  Photo, video). Originals for sharing are downloaded to a temporary file.
  Opening uses the grid's cached month index to assemble contiguous loaded pages without
  scanning and flattening the library's days again on the main actor.
  Decoded previews and playback are retained only for the current item and two neighbours on
  each side. Visited models keep favorite/detail state while releasing media outside that window.
  Viewer and selection sharing use the same original-to-disk downloader with guarded redirects.
  Prepared files remain owned until sharing ends; failures and cancellation remove partial files.
- **Search and Collections** call the service directly through their own small models.

## Talking to Immich

`ImmichService` is the only way the UI reaches the server; previews and tests use
`MockImmichService`, a deterministic generated library.

- **Reads** use the generated client. Where the v3.4.0 spec requires fields that older servers
  don't send (people, search results, asset details, memories, server version), the live service
  falls back to lenient decoders (`Lenient*.swift`) instead of failing.
- **Writes** (favorite, trash, restore, albums) and the trash settings check use small hand-written
  JSON requests (`rawRequest`/`rawPUT` in `LiveImmichService`). Their bodies are tiny, and each
  result is checked against what was asked for: only IDs the server confirms count as done.
- **Authentication** is the `x-api-key` header: `APIKeyMiddleware` adds it to generated calls, and
  the hand-written requests set the same header. The key is never logged or written anywhere but
  the Keychain.

## Changes are opt-in and careful

- **View-only by default.** `EditGuardedService` wraps the session's service and refuses every
  write until **Allow Changes** is turned on (`EditingPermission`); the UI also hides edit controls
  (`allowsLibraryChanges` environment value).
- **Trash, never delete.** Moving to trash first checks that the server's trash is on and keeps
  items, sends `force: false` one asset at a time, and re-reads an asset when a response is lost
  rather than sending again. Nothing in Bloom deletes permanently.
- **Uncertain outcomes stay uncertain.** If a write may or may not have reached the server, the grid
  keeps what it showed but doesn't save or reuse it until a fresh load replaces it
  (`LibraryGridModel+Editing`). Confirmed changes are applied on top of cached months
  (`LocalLibraryEdits`).

## The Library grid

SwiftUI's lazy grids only estimate rows they haven't built, which is not exact enough for jumping
to a month, keeping a photo in place while pinching, or the dates in the header. So the grid has its
own layout: `GridLayout` gives exact positions for the uniform square cells, `LibraryGridScroll`
builds only the rows near the screen and does every programmatic scroll by y. Months uses the same
idea (`MonthsLayout`). Years, Months and All stay alive while hidden so switching can zoom between
them (`LibraryScale.zoom`).

## Sources

| Folder | What it holds | Start with |
|---|---|---|
| `ImmichAPI/` | Generated Immich client (do not edit by hand; see README) | `openapi-generator-config.yaml` |
| `ImmichKit/Service/` | Talking to the server: the `ImmichService` protocol, the live service and its write operations, the mock service | `ImmichService.swift`, `LiveImmichService.swift` |
| `ImmichKit/Models/` | Plain domain types (`Asset`, `Album`, `Person`, details) | `Models.swift` |
| `ImmichKit/Editing/` | Results and rules of changes: trash, restore, albums, Allow Changes | `EditingPermission.swift`, `TrashResult.swift`, `AlbumEditing.swift` |
| `ImmichKit/Timeline/` | Month buckets and the timeline actor | `Timeline.swift` |
| `ImmichKit/ImageCache/` | Thumbnail memory/disk cache, loader, prefetcher | `ImageLoader.swift` |
| `ImmichKit/Credentials/` | Server URL + API key in the Keychain, connection test | `CredentialStore.swift` |
| `ImmichKit/Mock/` | The deterministic demo library used by tests and previews | `MockLibrary.swift` |
| `ImmichUI/Root/` | Tabs, sign-in/out flow, About Bloom and the app icon picker | `ImmichRootView.swift` |
| `ImmichUI/Library/` | The Library grid: exact layout, pinch, header, selection, Years/Months | `LibraryGridView.swift`, `LibraryGridScroll.swift`, `LibraryGridModel.swift`, `GridLayout.swift`, `MonthsLayout.swift` |
| `ImmichUI/Collections/` | Collections tab: memories, pinned, albums, people, map, add to album | `CollectionsView.swift`, `CollectionSections.swift` |
| `ImmichUI/Viewer/` | Full-screen viewer, info sheet, Live Photos | `AssetViewer.swift` |
| `ImmichUI/Search/` | Search tab | `SearchView.swift` |
| `ImmichUI/Login/` | Sign-in screen | `LoginView.swift` |
| `ImmichUI/Shared/` | Small shared views (glass, the Bloom logo) and the Allow Changes setting | `Glass.swift`, `LibraryChanges.swift` |
| `*/Resources/nb.lproj/` | Norwegian translations (keyed by the English text) | `Localizable.strings` |

## Tests

`Tests/ImmichKitTests/` mirrors the features: `App`, `Library`, `Collections`, `Viewer`, `Editing`
(trash/restore), `Search` and `Service` (client, models, cache, timeline). They use the mock service;
integration tests skip unless `IMMICH_URL` and `IMMICH_API_KEY` are set.

## Other folders

- `Branding/` — the logo kit and its generator.
- `docs/` — this file and the README screenshots.
- Notes for the coding agents that helped build the app are kept locally and are not part of the repository.
