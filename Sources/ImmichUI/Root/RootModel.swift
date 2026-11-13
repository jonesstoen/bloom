import CryptoKit
import Foundation
import ImmichKit
import Observation

/// One connection's shared services and library state; discarded when signing out.
@MainActor
public final class ImmichSession: Identifiable {
    public let id = UUID()
    public let service: any ImmichService
    public let loader: ImageLoader
    public let library: LibraryGridModel
    public let search: SearchModel
    public let snapshotStore: TimelineSnapshotStore?

    init(service: any ImmichService, disk: DiskImageCache?, snapshotStore: TimelineSnapshotStore? = nil) {
        self.service = service
        self.snapshotStore = snapshotStore
        let loader = ImageLoader(service: service, disk: disk)
        self.loader = loader
        self.library = LibraryGridModel(service: service, loader: loader, snapshotStore: snapshotStore)
        self.search = SearchModel(service: service, loader: loader)
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
    /// Allow Changes, shared with every session's service (see `LibraryChanges`).
    @ObservationIgnored public let editing: EditingPermission

    /// - Parameter editing: defaults to the saved Allow Changes setting (off unless turned on).
    public init(store: CredentialStore = CredentialStore(),
                makeService: @escaping ConnectionTester.ServiceFactory = { LiveImmichService(credentials: $0) },
                editing: EditingPermission? = nil) {
        self.store = store
        self.makeService = makeService
        self.editing = editing ?? EditingPermission(isAllowed: LibraryChanges.storedValue)
    }

    init(previewService: any ImmichService) {
        store = CredentialStore(storage: InMemorySecureStorage())
        makeService = { _ in previewService }
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
            if let credentials { connected(credentials) }
            else { phase = .signedOut }
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
            try await Task.detached { try store.clear() }.value
            session?.library.stopPrefetching()
            await session?.snapshotStore?.invalidate()
            await session?.loader.invalidate()
            if persistsImages { await Self.removeLeftoverFiles(keeping: nil) }
            session = nil
            error = nil
            phase = .signedOut
        } catch {
            self.error = tr("Couldn't remove the saved connection. Please try again.")
        }
    }

    public func dismissError() { error = nil }

    private func connected(_ credentials: ServerCredentials) {
        let service = EditGuardedService(base: makeService(credentials), permission: editing)
        let disk = persistsImages ? DiskImageCache(directory: Self.cacheDirectory(for: credentials)) : nil
        let snapshots = persistsImages ? TimelineSnapshotStore(
            directory: Self.cacheDirectory(for: credentials).appendingPathComponent("Timeline", isDirectory: true)
        ) : nil
        session = ImmichSession(service: service, disk: disk, snapshotStore: snapshots)
        error = nil
        phase = .signedIn
        if persistsImages {
            let current = Self.cacheDirectory(for: credentials)
            Task.detached(priority: .utility) { await Self.removeLeftoverFiles(keeping: current) }
        }
    }

    /// Other accounts' caches and share files from a quit or crashed app. Nothing is being shared
    /// at sign-in or sign-out, so no share folder in use can be removed.
    private nonisolated static func removeLeftoverFiles(keeping current: URL?) async {
        CacheProtection.removeOtherAccounts(keeping: current)
        SelectionShareFiles.removeLeftovers()
    }

    /// Hash the connection identity: no raw credentials appear in cache paths.
    static func cacheDirectory(for credentials: ServerCredentials) -> URL {
        let identity = Data((credentials.serverURL.absoluteString + "\u{0}" + credentials.apiKey).utf8)
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return DiskImageCache.defaultDirectory.appendingPathComponent(digest, isDirectory: true)
    }
}
