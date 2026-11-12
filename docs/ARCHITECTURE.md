# Where things are

Bloom is the Swift package in this repository; the iOS app target only shows `ImmichRootView()`.
Open `Package.swift` in Xcode to browse just the package.

## Sources

| Folder | What it holds | Start with |
|---|---|---|
| `ImmichAPI/` | Generated Immich client (do not edit by hand; see README) | `openapi-generator-config.yaml` |
| `ImmichKit/Service/` | Talking to the server: the `ImmichService` protocol, the live service and its write operations, the mock service | `ImmichService.swift`, `LiveImmichService.swift` |
| `ImmichKit/Models/` | Plain domain types (`Asset`, `Album`, `Person`, details) | `Models.swift` |
| `ImmichKit/Editing/` | Results and rules of changes: trash, restore, albums | `TrashResult.swift`, `AlbumEditing.swift` |
| `ImmichKit/Timeline/` | Month buckets and the timeline actor | `Timeline.swift` |
| `ImmichKit/ImageCache/` | Thumbnail memory/disk cache, loader, prefetcher | `ImageLoader.swift` |
| `ImmichKit/Credentials/` | Server URL + API key in the Keychain, connection test | `CredentialStore.swift` |
| `ImmichKit/Mock/` | The deterministic demo library used by tests and previews | `MockLibrary.swift` |
| `ImmichUI/Root/` | Tabs, sign-in/out flow, About Bloom and the app icon picker | `ImmichRootView.swift` |
| `ImmichUI/Library/` | The Library grid: exact layout, pinch, header, selection, Years/Months | `LibraryGridView.swift`, `GridLayout.swift` |
| `ImmichUI/Collections/` | Collections tab: memories, pinned, albums, people, map, add to album | `CollectionsView.swift` |
| `ImmichUI/Viewer/` | Full-screen viewer, info sheet, Live Photos | `AssetViewer.swift` |
| `ImmichUI/Search/` | Search tab | `SearchView.swift` |
| `ImmichUI/Login/` | Sign-in screen | `LoginView.swift` |
| `ImmichUI/Shared/` | Small shared views (glass, the Bloom logo) | `Glass.swift` |
| `*/Resources/nb.lproj/` | Norwegian translations (keyed by the English text) | `Localizable.strings` |

## Tests

`Tests/ImmichKitTests/` mirrors the features: `App`, `Library`, `Collections`, `Viewer`, `Editing`
(trash/restore), `Search` and `Service` (client, models, cache, timeline). They use the mock service;
integration tests skip unless `IMMICH_URL` and `IMMICH_API_KEY` are set.

## Other folders

- `Branding/` — the logo kit and its generator.
- `docs/` — this file and the README screenshots.
- Notes for the coding agents that helped build the app are kept locally and are not part of the repository.
