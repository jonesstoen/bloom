# ImmichKit

A Swift package for a native iPhone Immich client, using iOS 18 Photos as its design target. The package provides the UI and supporting services; the small iOS app target is created separately in Xcode.

## Package structure

| Target | Contents |
| --- | --- |
| `ImmichAPI` | Checked-in OpenAPI spec, generator configuration and generated client |
| `ImmichKit` | Domain models, live/mock services, timeline actor, image cache, prefetcher, search and Keychain credentials |
| `ImmichUI` | Login, month library grid, media viewer, Albums, People, Search and `ImmichRootView` |
| `ImmichKitTests` | Unit tests using the mock, transport fixtures and optional live-server integration tests |

The `ImmichKit` library product exposes all three modules. Deployment targets are iOS 18 and macOS 15. iOS gets full-screen swipe paging, thumbnail zoom transitions and pinch density controls; macOS compiles the shared UI and provides a sheet viewer with previous/next controls.

## Create the iPhone app in Xcode

1. Open full Xcode and choose **File → New → Project → iOS → App**. Name it `ImmichPhotos`, select **SwiftUI** and **Swift**, and choose your signing team and a unique bundle identifier. Save the app project beside this package rather than inside its Sources folder.
2. In the app target's **General** settings, set **Minimum Deployments → iOS** to **18.0** or later.
3. Choose **File → Add Package Dependencies… → Add Local…** and select this repository's folder (the one containing `Package.swift`). Add the **ImmichKit** library product to the `ImmichPhotos` app target. Confirm it appears under the target's **Frameworks, Libraries, and Embedded Content**.
4. Replace the generated app entry point with:

   ```swift
   import SwiftUI
   import ImmichUI

   @main
   struct ImmichPhotosApp: App {
       var body: some Scene {
           WindowGroup {
               ImmichRootView()
           }
       }
   }
   ```

   The generated `ContentView` is no longer needed. No API key, server URL or extra service wiring belongs in the app source.
5. Select an iPhone simulator or your signed-in physical device and run. On first launch, enter the server URL and API key in the login screen. The connection test checks an authenticated endpoint before saving to the Keychain. Subsequent launches restore that connection; **Library → Account → Sign Out** clears it and the session's image cache.
6. For a server on your local network, add **Privacy - Local Network Usage Description** (`NSLocalNetworkUsageDescription`) to the app target's Info settings, explaining that the app connects to the user's photo server. Prefer a server with trusted HTTPS. If you deliberately use plain HTTP, configure a narrowly scoped App Transport Security exception in the app target for that server; the package does not disable ATS globally.

Browsing does not require permission to the iPhone's Photos library: images come from Immich. Uploading and saving to the device's photo library are not implemented.

## Language

The app is in Norwegian Bokmål when the device's preferred language is Norwegian (nb, no or nn),
otherwise in English. Texts live in `Sources/ImmichKit/Resources/nb.lproj` and
`Sources/ImmichUI/Resources/nb.lproj` (`Localizable.strings`, keyed by the English text). Wrap new
user-facing text in `tr("…")`; `LocalizationTests` fails if a text has no Norwegian translation.
Dates and month names follow the same language. No setting in the app target is needed.

## Preview without a server

All UI screens have mock previews. For a complete app demo, use:

```swift
import ImmichKit
import ImmichUI

ImmichRootView(service: MockImmichService.preview)
```

This root initializer uses an in-memory session and does not read the real Keychain. The deterministic mock has hundreds of generated photos, albums, people and metadata. Its search uses word matching rather than CLIP, and mock videos show a placeholder because they have no playable media.

## Run all three checks

Run from the package directory with full Xcode installed:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -scheme ImmichKit -destination 'generic/platform=iOS Simulator' -quiet
```

The prefix is needed for SwiftPM as well on this machine: `xcode-select` points to CommandLineTools, whose Swift 6.1 compiler is too old for the resolved dependency versions. Keep `Package.resolved` when reproducing these builds.

Integration tests skip cleanly unless both `IMMICH_URL` and `IMMICH_API_KEY` are supplied through your local environment. Do not put credentials in source files, shell history, logs or commits. Unit tests and previews need no live credentials.

Known harmless warnings are the unhandled OpenAPI spec/config files in SwiftPM and Xcode's “Supported platforms for the buildables in the current scheme is empty” message. The build must still exit successfully.

## API generation and compatibility

The checked-in spec is **Immich v3.4.0**. **Re-check it against the real server's `/api/server/version` before relying on live compatibility.** See `PROGRESS.md` for date decoding, older-server response fallbacks, timeline shape and media content-type handling.

The OpenAPI generator build plugin is intentionally not enabled: unattended Xcode builds otherwise require plugin approval. Generated sources live in `Sources/ImmichAPI/GeneratedSources/`. Only regenerate after changing the spec or operation filter:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift package --allow-writing-to-package-directory generate-code-from-openapi --target ImmichAPI
```

Commit the generated changes and rerun all three checks.

## Remaining validation

- Re-check the API spec version against the real server and run the integration suite with local credentials.
- Exercise paging, double-tap zoom, downward dismissal, pinch anchoring and thumbnail transitions on a simulator/device; compilation and model tests do not verify animation quality.
- Check authenticated video playback, large libraries, offline/reconnect behavior and Dynamic Type/VoiceOver on a physical iPhone.

The root shares one loader across tabs and namespaces its disk cache by a digest of the connection identity, so different server/account connections do not reuse each other's thumbnails. Custom service integrations that create loaders directly should likewise supply a separate `DiskImageCache` directory per connection.
