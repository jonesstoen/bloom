import Foundation
import ImmichKit

/// Tracks which loaded assets are on screen and tells a `Prefetcher` about the asset list and
/// the visible range, so thumbnails ahead of the scroll direction load early.
///
/// Updates go through one stream so the prefetcher sees them in order.
@MainActor
final class PrefetchFeed {
    private enum Update: Sendable {
        case assets([String])
        case visible(Range<Int>)
        case cancel
    }

    private let updates: AsyncStream<Update>.Continuation
    /// Assets whose cells are on screen.
    private(set) var visibleIDs: Set<String> = []
    /// The last range sent to the prefetcher, `nil` when nothing is visible.
    private(set) var lastVisibleRange: Range<Int>?

    init(prefetcher: Prefetcher) {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        updates = continuation
        Task {
            for await update in stream {
                switch update {
                case .assets(let ids): await prefetcher.setAssets(ids)
                case .visible(let range): await prefetcher.visibleRangeChanged(range)
                case .cancel: await prefetcher.cancelAll()
                }
            }
        }
    }

    /// Ends the stream; the prefetcher cancels what it is loading.
    nonisolated func finish() {
        updates.yield(.cancel)
        updates.finish()
    }

    func setAssets(_ ids: [String]) { updates.yield(.assets(ids)) }

    func appeared(_ id: String) { visibleIDs.insert(id) }

    func disappeared(_ id: String) { visibleIDs.remove(id) }

    /// Forgets assets that are no longer in the grid.
    func keepVisible(_ ids: Set<String>) { visibleIDs.formIntersection(ids) }

    func cancel() {
        visibleIDs = []
        lastVisibleRange = nil
        updates.yield(.cancel)
    }

    /// Sends the range spanned by the visible assets, positions given by `positionByID`.
    /// `force` resends it after the positions changed.
    func report(positions positionByID: [String: Int], force: Bool = false) {
        if force { lastVisibleRange = nil }
        guard let range = Self.visibleRange(of: visibleIDs, in: positionByID) else {
            lastVisibleRange = nil
            updates.yield(.cancel)
            return
        }
        guard range != lastVisibleRange else { return }
        lastVisibleRange = range
        updates.yield(.visible(range))
    }

    /// The index range spanned by `ids`, or `nil` if none of them has a position.
    static func visibleRange(of ids: Set<String>, in indexByID: [String: Int]) -> Range<Int>? {
        let indices = ids.compactMap { indexByID[$0] }
        guard let low = indices.min(), let high = indices.max() else { return nil }
        return low..<(high + 1)
    }
}
