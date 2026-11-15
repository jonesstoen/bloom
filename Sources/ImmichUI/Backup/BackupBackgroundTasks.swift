import Foundation
import ImmichKit
import os
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

// MARK: - Tasks and requests

/// Bloom's two scheduled backup tasks. Their identifiers go in the app's Info.plist under
/// `BGTaskSchedulerPermittedIdentifiers`.
public enum BackupTaskKind: String, CaseIterable, Sendable {
    /// The nightly run on power: full scan, hashing, iCloud downloads and videos (`BackupEngine.runProcessing`).
    case processing = "no.johannesstoen.bloom.backup.processing"
    /// The short app-refresh run: new small photos already on the phone (`BackupEngine.runIncremental`).
    case refresh = "no.johannesstoen.bloom.backup.refresh"

    public var identifier: String { rawValue }
}

/// A task request as `BGTaskScheduler` gets it, without BackgroundTasks (so it can be checked on macOS).
struct BackupTaskRequest: Equatable, Sendable {
    let kind: BackupTaskKind
    var earliestBeginDate: Date?
    var requiresExternalPower = false
    var requiresNetworkConnectivity = false
}

/// What Bloom needs of `BGTaskScheduler` (tests use a fake).
protocol BackgroundTaskScheduling: Sendable {
    func submit(_ request: BackupTaskRequest) throws
    func cancel(_ kind: BackupTaskKind)
}

/// What Bloom needs of a `BGTask` that iOS started (tests use a fake).
protocol BackgroundTaskHandle: AnyObject, Sendable {
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    func setTaskCompleted(success: Bool)
}

/// Submits and cancels both backup tasks. A submit replaces an earlier request with the same identifier.
struct BackupTaskScheduler: Sendable {
    /// The refresh task's earliest start, from now.
    static let refreshDelay: TimeInterval = 60 * 60

    private let base: any BackgroundTaskScheduling
    private let now: @Sendable () -> Date

    init(_ base: any BackgroundTaskScheduling, now: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base
        self.now = now
    }

    /// Schedules nothing (macOS, previews, tests that don't look).
    static let none = BackupTaskScheduler(NoBackgroundTasks())

    /// The system's scheduler on iOS; `none` elsewhere.
    static var live: BackupTaskScheduler {
        #if os(iOS)
        BackupTaskScheduler(SystemBackgroundTasks())
        #else
        none
        #endif
    }

    /// Processing: whenever iOS finds the phone on power and online (in practice at night). Refresh: not before
    /// an hour from now; iOS picks the time from how Bloom is used.
    static func requests(now: Date) -> [BackupTaskRequest] {
        [
            BackupTaskRequest(kind: .processing, requiresExternalPower: true, requiresNetworkConnectivity: true),
            BackupTaskRequest(kind: .refresh, earliestBeginDate: now.addingTimeInterval(refreshDelay)),
        ]
    }

    func submitAll() {
        for request in Self.requests(now: now()) {
            do {
                try base.submit(request)
            } catch {
                // Background App Refresh off, too many requests, or the Simulator: the app still backs up when open.
                Self.log.notice("Couldn't schedule \(request.kind.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelAll() {
        for kind in BackupTaskKind.allCases { base.cancel(kind) }
    }

    private static let log = Logger(subsystem: "no.johannesstoen.bloom", category: "backup-tasks")
}

private struct NoBackgroundTasks: BackgroundTaskScheduling {
    func submit(_ request: BackupTaskRequest) throws {}
    func cancel(_ kind: BackupTaskKind) {}
}

// MARK: - Running a task

/// Runs the scheduled tasks iOS starts and hands session events to the right account's transport.
enum BackupBackgroundTasks {
    /// How long a refresh run enqueues (iOS gives an app-refresh task about 30 s).
    static let refreshBudget: Duration = .seconds(25)

    /// Runs `kind` for the signed-in account (`lookup`), on a task of its own (the caller, iOS's launch handler,
    /// returns at once). The run reschedules both tasks at its start (`BackupEngine`), enqueues and finishes.
    /// `task` is completed exactly once: with `true` when the run ends, with `false` when iOS expires it first
    /// (the run is cancelled then). Signed out, the scheduled tasks are cancelled and nothing runs; with the
    /// Keychain not readable yet (before the first unlock) nothing runs and the schedule is left as it is.
    @discardableResult
    static func handle(
        _ kind: BackupTaskKind, task: any BackgroundTaskHandle, scheduler: BackupTaskScheduler,
        lookup: @escaping @Sendable () -> BackupEngineLookup
    ) -> Task<Void, Never> {
        let completion = TaskCompletion(task)
        let run = Task.detached {
            switch lookup() {
            case .found(let engine):
                switch kind {
                case .processing: await engine.runProcessing()
                case .refresh: await engine.runIncremental(budget: refreshBudget)
                }
                completion.complete(success: true)
            case .noAccount:
                scheduler.cancelAll()
                completion.complete(success: true)
            case .credentialsUnavailable:
                completion.complete(success: false)
            }
        }
        task.setExpirationHandler {
            run.cancel()
            completion.complete(success: false)
        }
        return run
    }

    /// The events of background session `identifier` (`handleEventsForBackgroundURLSession`). The account's own
    /// session: its transport gets `completion` and calls it once every result is recorded. A session of no
    /// signed-in account (signed out, or another account): invalidated, so its results are ignored, then
    /// `completion`. The Keychain not readable yet: the session may well be the account's, with uploads under
    /// way, so it is left alone; just `completion`. `lookup` may read the Keychain and the index: call this off
    /// the main thread.
    static func handleEvents(
        forSession identifier: String, lookup: (String) -> BackupEngineLookup,
        invalidate: (String) -> Void, completion: @escaping @Sendable () -> Void
    ) {
        switch lookup(identifier) {
        case .found(let engine):
            engine.transport.handleEvents(completion: completion)
        case .noAccount:
            invalidate(identifier)
            completion()
        case .credentialsUnavailable:
            completion()
        }
    }
}

/// Calls `setTaskCompleted` once, whichever of the run's end and the expiration comes first.
private final class TaskCompletion: Sendable {
    private let task: any BackgroundTaskHandle
    private let done = OSAllocatedUnfairLock(initialState: false)

    init(_ task: any BackgroundTaskHandle) {
        self.task = task
    }

    func complete(success: Bool) {
        let first = done.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        if first { task.setTaskCompleted(success: success) }
    }
}

#if os(iOS)

// MARK: - iOS

private struct SystemBackgroundTasks: BackgroundTaskScheduling {
    func submit(_ request: BackupTaskRequest) throws {
        let made: BGTaskRequest
        switch request.kind {
        case .processing:
            let processing = BGProcessingTaskRequest(identifier: request.kind.identifier)
            processing.requiresExternalPower = request.requiresExternalPower
            processing.requiresNetworkConnectivity = request.requiresNetworkConnectivity
            made = processing
        case .refresh:
            made = BGAppRefreshTaskRequest(identifier: request.kind.identifier)
        }
        made.earliestBeginDate = request.earliestBeginDate
        try BGTaskScheduler.shared.submit(made)
    }

    func cancel(_ kind: BackupTaskKind) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: kind.identifier)
    }
}

/// A `BGTask` iOS started. Its methods may be called from any thread.
private final class SystemBackgroundTask: BackgroundTaskHandle, @unchecked Sendable {
    private let task: BGTask

    init(_ task: BGTask) {
        self.task = task
    }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

/// iOS's completion handler for a session's events, called on the main thread.
private final class MainThreadCompletion: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        if Thread.isMainThread { handler() } else { DispatchQueue.main.async { self.handler() } }
    }
}

extension BackupBackgroundTasks {
    private static let registered = OSAllocatedUnfairLock(initialState: false)

    /// Registers the launch handlers of both tasks with `BGTaskScheduler`. Must run before
    /// `application(_:didFinishLaunchingWithOptions:)` returns, once per process (later calls do nothing).
    static func register() {
        let first = registered.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }
        for kind in BackupTaskKind.allCases {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: kind.identifier, using: nil) { task in
                handle(kind, task: SystemBackgroundTask(task), scheduler: .live, lookup: {
                    BackupEngineRegistry.shared.signedInEngine()
                })
            }
        }
    }

    /// Ends a background session no signed-in account owns: its tasks are cancelled and its results dropped.
    static func invalidateSession(_ identifier: String) {
        URLSession(configuration: .background(withIdentifier: identifier), delegate: nil, delegateQueue: nil)
            .invalidateAndCancel()
    }
}

/// The app target's hook, one line in its `App`:
///
///     @UIApplicationDelegateAdaptor(BloomAppDelegate.self) private var appDelegate
///
/// It registers the backup tasks at launch and hands background-session events to the account's transport.
/// An app delegate rather than SwiftUI's `.backgroundTask` scene modifier: that has no processing task, and it
/// only runs once a scene exists, while `BGTaskScheduler` wants the handlers registered before launch finishes.
public final class BloomAppDelegate: NSObject, UIApplicationDelegate {
    /// How `BackgroundSessionTransport.sessionIdentifier` starts: other sessions aren't backup's.
    private static let sessionPrefix = "no.johannesstoen.bloom.backup."

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackupBackgroundTasks.register()
        return true
    }

    public func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        let completion = MainThreadCompletion(completionHandler)
        guard identifier.hasPrefix(Self.sessionPrefix) else {
            completion.call()
            return
        }
        // Reads the Keychain and may open the account's index: not on the main thread.
        Task.detached(priority: .userInitiated) {
            BackupBackgroundTasks.handleEvents(
                forSession: identifier, lookup: { BackupEngineRegistry.shared.lookup(sessionIdentifier: $0) },
                invalidate: { BackupBackgroundTasks.invalidateSession($0) }, completion: { completion.call() })
        }
    }
}

#endif
