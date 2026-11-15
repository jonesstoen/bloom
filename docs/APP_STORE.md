# Publishing Bloom on the App Store

What App Store Connect and App Review ask for, with the answers that fit Bloom. The app target lives
in its own Xcode project; the steps below say what to add there. Check each answer against the app
as it is when you submit: they describe Bloom as of November 2026.

## Privacy policy URL

Use the policy in this repository:
`https://github.com/jonesstoen/bloom/blob/main/PRIVACY.md` (English and Norwegian).

## App Privacy ("privacy labels")

In App Store Connect › App Privacy, answer **"No, we do not collect data from this app."**

Why that is accurate under Apple's definitions: "collect" means data transmitted off the device in
a way that the developer or a third-party partner can access. Bloom sends data only to the user's
own Immich server, which the user runs or chose, never to the developer or to any third party. There
is no analytics, crash reporting, advertising or tracking SDK, and no account with the developer.
The Apple Maps tiles on the Map screen are an Apple system service, not data collected by the app.

The result shown on the store page is **Data Not Collected**. Tracking: **No**.

## Privacy manifests

- The package already ships `PrivacyInfo.xcprivacy` in `ImmichKit` and `ImmichUI`: no tracking, no
  collected data, and the two "required reason" APIs it uses:
  - `NSPrivacyAccessedAPICategoryFileTimestamp`, reason `C617.1`: the image cache and the library
    snapshot read and set modification dates of files inside the app's own container (least
    recently used eviction).
  - `NSPrivacyAccessedAPICategoryUserDefaults`, reason `CA92.1`: settings (grid size, sort, filter,
    folded sections, Allow Changes) read and written only by the app.
- Copy [`docs/app-target/PrivacyInfo.xcprivacy`](app-target/PrivacyInfo.xcprivacy) into the app
  target (File › Add Files, tick the app target). The app target itself only shows
  `ImmichRootView`, so its manifest declares nothing beyond "no tracking, no data collected".
- Xcode › Product › Archive, then in the Organizer: **Generate Privacy Report** to check the
  combined result before uploading.

## Info.plist keys in the app target

| Key | Value | Why |
|---|---|---|
| `NSLocalNetworkUsageDescription` | see below | iOS asks before an app reaches devices on the local network (a server at home). Without it the connection fails silently. |
| `UIBackgroundModes` | `fetch`, `processing` | Backup runs while Bloom is closed (Xcode: Background Modes › Background fetch, Background processing). |
| `BGTaskSchedulerPermittedIdentifiers` | `no.johannesstoen.bloom.backup.processing`, `no.johannesstoen.bloom.backup.refresh` | The two background tasks Backup schedules. Missing, the app crashes at launch. Steps: [`app-target/BACKGROUND_BACKUP.md`](app-target/BACKGROUND_BACKUP.md). |
| `ITSAppUsesNonExemptEncryption` | `NO` | Bloom only uses the encryption built into iOS (HTTPS/TLS), which is exempt; this skips the export compliance question on every upload. |

Text for `NSLocalNetworkUsageDescription`:

- English (Info.plist): `Bloom connects to your Immich server when it is on your local network.`
- Norwegian (`nb.lproj/InfoPlist.strings` in the app target):
  `"NSLocalNetworkUsageDescription" = "Bloom kobler til Immich-serveren din når den er på det lokale nettverket.";`

Bloom uses no camera, microphone, location or contacts, so no other usage descriptions are needed.
Backup reads the Photos library (read-only), which needs `NSPhotoLibraryUsageDescription`. In the review
notes, say that Backup is optional, off by default and uploads only to the user's own server, and that
the background modes exist only to send those uploads while the app is closed.

## App Transport Security

Bloom itself refuses plain http to the internet and asks before using it on a local network. For
servers on the user's own network or on Tailscale over http, ATS must also allow it:

- `NSAppTransportSecurity › NSAllowsLocalNetworking = YES` covers `.local` names, unqualified
  (single-label) names and IP addresses, according to Apple's documentation. Verify with a real
  local server before submitting.
- Tailscale MagicDNS names over http (`http://name.tailnet.ts.net`) need an exception domain
  `ts.net` with `NSIncludesSubdomains` and `NSExceptionAllowsInsecureHTTPLoads`. Tailscale encrypts
  that traffic itself. Leave it out if you only support https (Tailscale can serve https with
  `tailscale serve`), which avoids having to justify it in review.
- Never set `NSAllowsArbitraryLoads`.

## App Review

- **Demo access is required.** Review needs a way to see the app working. Either give them a test
  Immich server and an API key with read-only permissions in the review notes, or ship a demo mode
  in release builds (today `-BloomDemo` only works in Debug builds).
- Review notes: explain that Bloom is a client for a self-hosted Immich server, that it needs the
  user's own server, and that the API key should have only the permissions shown on the sign-in
  screen.
- Bloom is not affiliated with Immich; do not use Immich's name or logo in a way that suggests
  otherwise (the app name, icon and screenshots are Bloom's own).
- Age rating questionnaire: no objectionable content is part of the app; user photos are the
  user's own content on their own server.
