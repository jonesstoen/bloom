import CryptoKit
import Foundation
import ImmichKit
import Observation
import SwiftUI

/// One connection's shared services and library state; discarded when signing out.
@MainActor
public final class ImmichSession: Identifiable {
    public let id = UUID()
    public let service: any ImmichService
    public let loader: ImageLoader
    public let library: LibraryGridModel
    public let search: SearchModel
    public let snapshotStore: TimelineSnapshotStore?
    let backup: BackupModel
    private var foregroundRefresh = LibraryForegroundRefresh()

    /// - Parameter backup: defaults to the preview photo library with a throwaway index.
    init(service: any ImmichService, disk: DiskImageCache?, snapshotStore: TimelineSnapshotStore? = nil,
         backup: BackupModel? = nil) {
        self.service = service
        self.backup = backup ?? BackupModel(
            source: PreviewPhotoLibrary(), service: service,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("BloomPreviewBackup-\(UUID().uuidString)", isDirectory: true))
        self.snapshotStore = snapshotStore
        let loader = ImageLoader(service: service, disk: disk)
        self.loader = loader
        let library = LibraryGridModel(service: service, loader: loader, snapshotStore: snapshotStore)
        self.library = library
        self.search = SearchModel(service: service, loader: loader)
        // Photos uploaded from this iPhone appear in the Library without a manual refresh.
        self.backup.onServerLibraryChanged = { [weak library] in
            guard let library else { return }
            Task { await library.load() }
        }
    }

    /// Forwarded by the tabs. Coming back after a while in the background revalidates the
    /// Library (see `LibraryForegroundRefresh`); returns that work, for tests to wait on.
    @discardableResult
    func scenePhaseChanged(_ phase: ScenePhase, at now: Date = Date()) -> Task<Void, Never>? {
        guard foregroundRefresh.phaseChanged(to: phase, at: now) else { return nil }
        let library = self.library
        return Task { await library.revalidate() }
    }
}

@MainActor @Observable
public final class RootModel {
    public enum Phase: Equatable { case loading, signedOut, signedIn, failed }
    public private(set) var phase: Phase = .loading
    public private(set) var session: ImmichSession?
    public private(set) var error: String?
    public private(set) var isSigningOut = false
    @ObservationIgnored private let store: CredentialStore
    @ObservationIgnored private let makeService: ConnectionTester.ServiceFactory
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var persistsImages = true
    /// Where the signed-in account's backup engine comes from; without it the Backup screen scans but
    /// uploads nothing (tests and previews that don't need uploads).
    @ObservationIgnored private let backupEngines: BackupEngineRegistry?
    /// Allow Changes, shared with every session's service (see `LibraryChanges`).
    @ObservationIgnored public let editing: EditingPermission

    /// The app's root model: the Keychain, the live server and the process's backup engines (shared with
    /// background launches, see `BackupEngine`).
    public convenience init() {
        let engines = BackupEngineRegistry.shared
        self.init(
            store: CredentialStore(), makeService: { LiveImmichService(credentials: $0) }, editing: engines.editing,
            backupEngines: engines)
    }

    /// Without backup engines: the Backup screen scans but doesn't upload.
    /// - Parameter editing: defaults to the saved Allow Changes setting (off unless turned on).
    public convenience init(store: CredentialStore,
                            makeService: @escaping ConnectionTester.ServiceFactory = { LiveImmichService(credentials: $0) },
                            editing: EditingPermission? = nil) {
        self.init(store: store, makeService: makeService, editing: editing, backupEngines: nil)
    }

    init(store: CredentialStore, makeService: @escaping ConnectionTester.ServiceFactory, editing: EditingPermission?,
         backupEngines: BackupEngineRegistry?) {
        self.store = store
        self.makeService = makeService
        self.editing = editing ?? EditingPermission(isAllowed: LibraryChanges.storedValue)
        self.backupEngines = backupEngines
    }

    init(previewService: any ImmichService) {
        store = CredentialStore(storage: InMemorySecureStorage())
        makeService = { _ in previewService }
        backupEngines = nil
        editing = EditingPermission(isAllowed: true)
        session = ImmichSession(service: previewService, disk: nil)
        persistsImages = false
        phase = .signedIn
    }

    public func restore() async {
        guard phase == .loading, !restoring else { return }
        restoring = true
        defer { restoring = false }
        do {
            let store = self.store
            let credentials = try await Task.detached { try store.load() }.value
            try Task.checkCancellation()
            guard phase == .loading else { return }
            guard let credentials else {
                phase = .signedOut
                return
            }
            let service = makeSessionService(credentials)
            // Opening the engine reads the account's index, which can be large: off the main thread.
            var engine: BackupEngine?
            if let engines = backupEngines {
                engine = await Task.detached { engines.engine(for: credentials, service: service) }.value
            }
            try Task.checkCancellation()
            guard phase == .loading else { return }
            connected(credentials, service: service, engine: engine)
        } catch is CancellationError { return }
        catch {
            self.error = tr("Couldn't read your saved connection. Unlock your device and try again, or remove the saved connection.")
            phase = .failed
        }
    }

    public func retryRestore() async {
        error = nil
        phase = .loading
        await restore()
    }

    public func makeLoginModel() -> LoginModel {
        LoginModel(store: store, tester: ConnectionTester(makeService: makeService)) { [weak self] credentials in
            self?.connected(credentials)
        }
    }

    public func signOut() async {
        guard !isSigningOut, session?.library.isMutating != true else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            let store = self.store
            let signedOutCredentials = try await Task.detached { () -> ServerCredentials? in
                let previous = try? store.load()
                try store.clear()
                return previous
            }.value
            session?.library.stopPrefetching()
            // The engine's background runs first, so none stages into the folder the runner then empties.
            await session?.backup.engine?.cancelRuns()
            // A running scan or upload saves the index and stages files: wait for both (this also
            // stops the runner and empties its staging folder) before the directory is removed.
            await session?.backup.stop()
            // Then the rest of the account's engine: its session, its index and its directory.
            await session?.backup.engine?.close()
            await session?.snapshotStore?.invalidate()
            await session?.loader.invalidate()
            if persistsImages {
                await Self.removeLeftoverFiles(keeping: nil)
                if let credentials = signedOutCredentials {
                    try? FileManager.default.removeItem(at: Self.backupDirectory(for: credentials))
                }
            }
            session = nil
            error = nil
            phase = .signedOut
        } catch {
            self.error = tr("Couldn't remove the saved connection. Please try again.")
        }
    }

    public func dismissError() { error = nil }

    private func makeSessionService(_ credentials: ServerCredentials) -> any ImmichService {
        EditGuardedService(base: makeService(credentials), permission: editing)
    }

    /// `engine`: the account's backup engine if the caller has it already; else made here (or none, without
    /// engines). A new sign-in has no index on disk yet, so making it here reads nothing large.
    private func connected(
        _ credentials: ServerCredentials, service: (any ImmichService)? = nil, engine: BackupEngine? = nil
    ) {
        let service = service ?? makeSessionService(credentials)
        let engine = engine ?? backupEngines?.engine(for: credentials, service: service)
        let disk = persistsImages ? DiskImageCache(directory: Self.cacheDirectory(for: credentials)) : nil
        let snapshots = persistsImages ? TimelineSnapshotStore(
            directory: Self.cacheDirectory(for: credentials).appendingPathComponent("Timeline", isDirectory: true)
        ) : nil
        let backup = engine.map { BackupModel(engine: $0) } ?? BackupModel(
            source: Self.photoLibrary, service: service, directory: Self.backupDirectory(for: credentials))
        let session = ImmichSession(service: service, disk: disk, snapshotStore: snapshots, backup: backup)
        // Staged files left by an upload the system ended. Queued before the first run, which waits for it.
        session.backup.runner.removeLeftoverStaging()
        self.session = session
        error = nil
        phase = .signedIn
        if persistsImages {
            let current = Self.cacheDirectory(for: credentials)
            Task.detached(priority: .utility) { await Self.removeLeftoverFiles(keeping: current) }
        }
    }

    /// The device's photo library on iOS; the preview library where PhotoKit isn't available.
    private static var photoLibrary: any PhotoLibrarySource { BackupEngineRegistry.photoLibrary }

    /// Other accounts' caches and share files from a quit or crashed app. Nothing is being shared
    /// at sign-in or sign-out, so no share folder in use can be removed.
    private nonisolated static func removeLeftoverFiles(keeping current: URL?) async {
        CacheProtection.removeOtherAccounts(keeping: current)
        removeLeftoverBackups(keeping: current)
        SelectionShareFiles.removeLeftovers()
    }

    /// Other accounts' backup indexes (a failed credential load or a rotated key). `current` is the
    /// account's cache directory; it shares its digest folder name with the backup directory.
    nonisolated static func removeLeftoverBackups(in root: URL = backupRoot, keeping current: URL?) {
        CacheProtection.removeOtherAccounts(in: root, keeping: current)
    }

    nonisolated static var backupRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Bloom/Backup", isDirectory: true)
    }

    /// `<Application Support>/Bloom/Backup/<digest>`. Unlike the caches this must survive low-storage
    /// purges, because the index holds checksums that are expensive to recompute.
    nonisolated static func backupDirectory(for credentials: ServerCredentials) -> URL {
        backupRoot.appendingPathComponent(accountDigest(for: credentials), isDirectory: true)
    }

    /// The account's name on disk (its cache and backup folders) and in its backup session identifier.
    nonisolated static func accountDigest(for credentials: ServerCredentials) -> String {
        let identity = Data((credentials.serverURL.absoluteString + "\u{0}" + credentials.apiKey).utf8)
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash the connection identity: no raw credentials appear in cache paths.
    static func cacheDirectory(for credentials: ServerCredentials) -> URL {
        DiskImageCache.defaultDirectory.appendingPathComponent(accountDigest(for: credentials), isDirectory: true)
    }
}
