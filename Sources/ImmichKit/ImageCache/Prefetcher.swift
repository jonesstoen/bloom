import Foundation

/// Prefetches thumbnails around the visible part of a scrolling grid.
///
/// The grid reports the ordered asset IDs it shows (`setAssets`) and the index range of the
/// visible cells (`visibleRangeChanged`). The prefetcher loads `ahead` images past the visible
/// range in the scroll direction and `behind` images on the other side, nearest first, with at
/// most `maxConcurrent` requests running. Requests whose asset scrolled more than
/// `cancelDistance` items away from the visible range are cancelled. Loaded data ends up in the
/// `ImageLoader` caches, where the cells pick it up.
public actor Prefetcher {
    public enum Direction: Sendable, Equatable {
        case forward
        case backward
    }

    public struct Configuration: Sendable, Equatable {
        /// Items to prefetch past the visible range in the scroll direction.
        public var ahead: Int
        /// Items to prefetch on the opposite side.
        public var behind: Int
        /// Running or queued requests farther than this from the visible range are cancelled.
        public var cancelDistance: Int
        /// Maximum number of concurrent prefetch requests.
        public var maxConcurrent: Int

        public init(ahead: Int = 30, behind: Int = 6, cancelDistance: Int = 60, maxConcurrent: Int = 6) {
            self.ahead = max(0, ahead)
            self.behind = max(0, behind)
            self.cancelDistance = max(cancelDistance, self.ahead, self.behind)
            self.maxConcurrent = max(1, maxConcurrent)
        }
    }

    public let configuration: Configuration
    public let size: ImageSize
    private let loader: ImageLoader

    private var assetIDs: [String] = []
    private var indexByID: [String: Int] = [:]
    private var visible: Range<Int>?
    public private(set) var direction: Direction = .forward

    /// Asset IDs waiting for a free slot, highest priority first.
    private var queue: [String] = []
    private struct Running {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var running: [String: Running] = [:]
    /// Asset IDs prefetched successfully since the last `setAssets`/`cancelAll`.
    private var completed: Set<String> = []

    public init(loader: ImageLoader, size: ImageSize = .thumbnail, configuration: Configuration = Configuration()) {
        self.loader = loader
        self.size = size
        self.configuration = configuration
    }

    /// Sets the ordered asset IDs of the grid. Keeps requests for IDs that are still near the
    /// visible range (e.g. when another month was appended) and cancels the rest.
    public func setAssets(_ ids: [String]) {
        assetIDs = ids
        indexByID = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        completed = completed.filter { indexByID[$0] != nil }
        if let visible {
            let clamped = visible.clamped(to: 0..<ids.count)
            self.visible = clamped
        }
        reschedule()
    }

    /// Reports the indices of the cells currently on screen.
    public func visibleRangeChanged(_ range: Range<Int>) {
        let range = range.clamped(to: 0..<assetIDs.count)
        if let previous = visible {
            if range.lowerBound > previous.lowerBound || range.upperBound > previous.upperBound {
                direction = .forward
            } else if range.lowerBound < previous.lowerBound || range.upperBound < previous.upperBound {
                direction = .backward
            }
        }
        visible = range
        reschedule()
    }

    /// Cancels everything, e.g. when the grid disappears.
    public func cancelAll() {
        for entry in running.values { entry.task.cancel() }
        running = [:]
        queue = []
        completed = []
        visible = nil
    }

    /// Asset IDs with a running request.
    public var runningIDs: Set<String> { Set(running.keys) }
    /// Asset IDs waiting for a slot, in priority order.
    public var queuedIDs: [String] { queue }
    /// `true` when nothing is running or queued.
    public var isIdle: Bool { running.isEmpty && queue.isEmpty }

    /// Indices to prefetch for `visible` scrolling in `direction`: the items ahead (nearest
    /// first), then the items behind (nearest first).
    static func targetIndices(
        visible: Range<Int>,
        direction: Direction,
        count: Int,
        configuration: Configuration
    ) -> [Int] {
        func after(_ n: Int) -> [Int] {
            Array(visible.upperBound..<min(count, visible.upperBound + n))
        }
        func before(_ n: Int) -> [Int] {
            Array((max(0, visible.lowerBound - n)..<visible.lowerBound).reversed())
        }
        switch direction {
        case .forward: return after(configuration.ahead) + before(configuration.behind)
        case .backward: return before(configuration.ahead) + after(configuration.behind)
        }
    }

    // MARK: Scheduling

    private func reschedule() {
        guard let visible else { return }
        let keep = max(0, visible.lowerBound - configuration.cancelDistance)
            ..< (visible.upperBound + configuration.cancelDistance)

        // Visible items are left running: their cells are waiting for the same shared fetch.
        for (id, entry) in running {
            if let index = indexByID[id], keep.contains(index) { continue }
            entry.task.cancel()
            running[id] = nil
        }

        queue = Self.targetIndices(
            visible: visible,
            direction: direction,
            count: assetIDs.count,
            configuration: configuration
        )
        .map { assetIDs[$0] }
        .filter { running[$0] == nil && !completed.contains($0) }

        pump()
    }

    private func pump() {
        while running.count < configuration.maxConcurrent, !queue.isEmpty {
            let id = queue.removeFirst()
            let key = ImageKey(assetID: id, size: size)
            let loader = self.loader
            let token = UUID()
            let task = Task {
                let success = (try? await loader.data(for: key)) != nil
                self.finished(id, token: token, success: success)
            }
            running[id] = Running(token: token, task: task)
        }
    }

    private func finished(_ id: String, token: UUID, success: Bool) {
        // Only clear the entry if it is still ours (it may have been cancelled and restarted).
        guard running[id]?.token == token else { return }
        running[id] = nil
        if success { completed.insert(id) }
        pump()
    }
}
