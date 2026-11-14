import Foundation
import Network

/// One state of the device's network path.
public struct NetworkPath: Sendable, Equatable {
    /// There is a usable path at all (iOS may still not reach the server over it).
    public var isConnected: Bool
    /// Cellular, an expensive path (a personal hotspot), or no path.
    public var isOnCellular: Bool

    public init(isConnected: Bool, isOnCellular: Bool) {
        self.isConnected = isConnected
        self.isOnCellular = isOnCellular
    }
}

/// Whether the device is currently on cellular data. Backup reads it before each iCloud download, and
/// the runner watches `changes()` to carry on when the network comes back or Wi-Fi takes over.
public protocol NetworkConditions: Sendable {
    var isOnCellular: Bool { get async }
    var isConnected: Bool { get async }
    /// Yields the current path once it is known, then every path update. Ends when the caller stops iterating.
    /// No default: a conformer that can't observe the network says so by returning a finished stream (the
    /// runner then never resumes on a reconnect).
    func changes() -> AsyncStream<NetworkPath>
}

extension NetworkConditions {
    /// Conditions that can't tell report connected.
    public var isConnected: Bool { get async { true } }
}

/// `NetworkConditions` from `NWPathMonitor`. Until the first path update arrives it reports
/// cellular, so nothing is downloaded over cellular by mistake, and connected.
public final class PathMonitorNetwork: NetworkConditions, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    /// nil until the first path update.
    private var path: NetworkPath?
    private var listeners: [UUID: AsyncStream<NetworkPath>.Continuation] = [:]

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            let new = NetworkPath(
                isConnected: connected,
                isOnCellular: !connected || path.usesInterfaceType(.cellular) || path.isExpensive)
            // Yielded under the lock, so a new stream can't get an older path after a newer one.
            self.lock.withLock {
                self.path = new
                for listener in self.listeners.values { listener.yield(new) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Bloom.PathMonitorNetwork"))
    }

    deinit {
        monitor.cancel()
        let listeners = lock.withLock { Array(self.listeners.values) }
        for listener in listeners { listener.finish() }
    }

    public var isOnCellular: Bool {
        get async { lock.withLock { path?.isOnCellular ?? true } }
    }

    public var isConnected: Bool {
        get async { lock.withLock { path?.isConnected ?? true } }
    }

    /// Only the newest path is buffered: a slow reader sees where the network ended up.
    public func changes() -> AsyncStream<NetworkPath> {
        let (stream, continuation) = AsyncStream<NetworkPath>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.listeners.removeValue(forKey: id) }
        }
        lock.withLock {
            listeners[id] = continuation
            if let path { continuation.yield(path) }
        }
        return stream
    }
}

extension ImmichServiceError {
    /// Whether `error` means the server couldn't be reached at all (offline, no route, DNS, timeout),
    /// as opposed to an answer the server gave or a broken connection (TLS, a garbled response). Backup
    /// shows such failures as a calm status and tries again when the network comes back; other transport
    /// failures stay errors. `LiveImmichService` keeps the `URLError` code on `.network`; a `.network`
    /// without one (a mock's) is not counted.
    ///
    /// `timedOut` counts: a server behind a VPN that is off (Tailscale) or a network that dropped mostly
    /// shows as a timeout, and trying again when the path changes is what helps.
    public static func isConnectivityFailure(_ error: any Error) -> Bool {
        switch error {
        case let ImmichServiceError.network(_, code):
            return code.map { connectivityCodes.contains($0) } ?? false
        case let error as URLError:
            return connectivityCodes.contains(error.code)
        case is ImmichServiceError, is CancellationError:
            return false
        default:
            let nsError = error as NSError
            return nsError.domain == NSURLErrorDomain && connectivityCodes.contains(URLError.Code(rawValue: nsError.code))
        }
    }

    private static let connectivityCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
    ]
}

/// The user's backup switches, per device. All off by default: no uploads, and no cellular data for
/// uploads or iCloud downloads.
public struct BackupSettings: Sendable, Equatable {
    public static let photosOnCellularKey = "backup.photosOnCellular"
    public static let videosOnCellularKey = "backup.videosOnCellular"
    public static let isEnabledKey = "backup.isEnabled"

    public var photosOnCellular: Bool
    public var videosOnCellular: Bool
    /// The Backup switch: upload while the app is open.
    public var isEnabled: Bool

    public init(photosOnCellular: Bool = false, videosOnCellular: Bool = false, isEnabled: Bool = false) {
        self.photosOnCellular = photosOnCellular
        self.videosOnCellular = videosOnCellular
        self.isEnabled = isEnabled
    }

    /// Reads the switches; missing keys mean off.
    public static func load(from defaults: UserDefaults = .standard) -> BackupSettings {
        BackupSettings(
            photosOnCellular: defaults.bool(forKey: photosOnCellularKey),
            videosOnCellular: defaults.bool(forKey: videosOnCellularKey),
            isEnabled: defaults.bool(forKey: isEnabledKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(photosOnCellular, forKey: Self.photosOnCellularKey)
        defaults.set(videosOnCellular, forKey: Self.videosOnCellularKey)
        defaults.set(isEnabled, forKey: Self.isEnabledKey)
    }

    /// Whether resources of `asset` may come over the network right now. A Live Photo counts as a photo.
    public func allowsNetwork(for asset: DeviceAsset, onCellular: Bool) -> Bool {
        guard onCellular else { return true }
        return asset.isVideo ? videosOnCellular : photosOnCellular
    }
}
