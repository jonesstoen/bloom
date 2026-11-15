# Backup in the background: steps in the Xcode app target

Bloom's package does the work. The app target (`ImmichPhotos`) needs three small changes so iOS may
wake Bloom for Backup. Do them in this order, **before you install the new build on the phone**.

## 1. Background Modes

Target `ImmichPhotos` › **Signing & Capabilities** › **+ Capability** › **Background Modes**. Tick:

- **Background fetch**
- **Background processing**

(This adds `fetch` and `processing` to `UIBackgroundModes` in Info.)

## 2. Permitted task identifiers

Target › **Info** › add the key `BGTaskSchedulerPermittedIdentifiers`
("Permitted background task scheduler identifiers"), type **Array**, with two items (type String):

1. `no.johannesstoen.bloom.backup.processing`
2. `no.johannesstoen.bloom.backup.refresh`

> **Warning:** do this before you install. Without these identifiers the app crashes at launch
> (`BGTaskScheduler` throws when a task is registered with an identifier that isn't permitted). If it
> already crashes, add the identifiers and install again.

## 3. The app delegate

In `ImmichPhotosApp.swift`, inside the `App` struct, add this line:

```swift
@UIApplicationDelegateAdaptor(BloomAppDelegate.self) private var appDelegate
```

`BloomAppDelegate` comes from `ImmichUI` (`import ImmichUI`). It registers the two background tasks
and receives the finished uploads from iOS when Bloom has been closed.

## Trying the tasks from the Xcode debugger

Run Bloom from Xcode with Backup on and at least one album chosen, then pause the app (the pause
button in the debug bar) and enter this in the lldb console, one identifier at a time:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"no.johannesstoen.bloom.backup.processing"]
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"no.johannesstoen.bloom.backup.refresh"]
```

Resume the app (continue) and watch the console. The processing task does the heavy work (checking
and staging large files); the refresh task only queues small photos that are already on the phone.
`_simulateExpirationForTaskWithIdentifier:` with the same identifier tests that a task stops cleanly
when iOS runs out of patience. This only works on a real iPhone, not in the Simulator.

## Phone checklist

iOS decides when background tasks run, so test with a real night:

- [ ] Settings › General › Background App Refresh is on for Bloom (Bloom shows a hint on the Backup
      screen when it is off). Low Power Mode is off.
- [ ] Backup is on, albums are chosen, and the first run has finished with the app open.
- [ ] Take a few photos, then close Bloom (swipe it away) and plug the iPhone in to charge overnight, on Wi-Fi.
- [ ] In the morning, check Immich: the new photos are there. Open Bloom › Backup: "Last backup" shows the night.
- [ ] Start a big upload (a video), then force-quit Bloom mid-upload. Wait a minute: the upload still finishes.
      Open Bloom: "Uploading in the background" counts down to zero and nothing is uploaded twice.
- [ ] A Live Photo counts as one item in Backup and shows as one Live Photo in Immich (the motion
      half is hidden from the timeline).
