import Foundation
import Network

/// Whether the device is currently on cellular data. Backup reads it before each iCloud download.
public protocol NetworkConditions: Sendable {
    var isOnCellular: Bool { get async }
}

/// `NetworkConditions` from `NWPathMonitor`. Until the first path update arrives it reports
/// cellular, so nothing is downloaded over cellular by mistake.
public final class PathMonitorNetwork: NetworkConditions, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var cellular = true

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let onCellular = path.status != .satisfied || path.usesInterfaceType(.cellular) || path.isExpensive
            self.lock.withLock { self.cellular = onCellular }
        }
        monitor.start(queue: DispatchQueue(label: "Bloom.PathMonitorNetwork"))
    }

    deinit { monitor.cancel() }

    public var isOnCellular: Bool {
        get async { lock.withLock { cellular } }
    }
}

/// The user's backup switches. Both off by default: no cellular data for uploads or iCloud downloads.
public struct BackupSettings: Sendable, Equatable {
    public static let photosOnCellularKey = "backup.photosOnCellular"
    public static let videosOnCellularKey = "backup.videosOnCellular"

    public var photosOnCellular: Bool
    public var videosOnCellular: Bool

    public init(photosOnCellular: Bool = false, videosOnCellular: Bool = false) {
        self.photosOnCellular = photosOnCellular
        self.videosOnCellular = videosOnCellular
    }

    /// Reads the switches; missing keys mean off.
    public static func load(from defaults: UserDefaults = .standard) -> BackupSettings {
        BackupSettings(
            photosOnCellular: defaults.bool(forKey: photosOnCellularKey),
            videosOnCellular: defaults.bool(forKey: videosOnCellularKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(photosOnCellular, forKey: Self.photosOnCellularKey)
        defaults.set(videosOnCellular, forKey: Self.videosOnCellularKey)
    }

    /// Whether resources of `asset` may come over the network right now. A Live Photo counts as a photo.
    public func allowsNetwork(for asset: DeviceAsset, onCellular: Bool) -> Bool {
        guard onCellular else { return true }
        return asset.isVideo ? videosOnCellular : photosOnCellular
    }
}
