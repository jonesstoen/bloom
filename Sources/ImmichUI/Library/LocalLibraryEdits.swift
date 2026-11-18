import Foundation
import ImmichKit

/// Writes the server has confirmed but the current `Timeline` may not reflect yet.
///
/// A `Timeline` caches the months it loaded. After a favorite toggle, a move to trash or a
/// restore, those cached months still hold the old state until a fresh load replaces them, so
/// the grid applies these edits on top of every snapshot it shows.
struct LocalLibraryEdits {
    /// Favorite flags set in this session, by asset id.
    var favoriteOverrides: [String: Bool] = [:]
    /// Moved to trash: hidden from library views.
    var trashedIDs: Set<String> = []
    /// Restored from trash: hidden from the Recently Deleted view.
    var restoredIDs: Set<String> = []
    /// Hidden (moved to the archive): removed from the timeline grid (`visibility == .timeline`).
    var hiddenIDs: Set<String> = []
    /// Unhidden (back in the timeline): removed from the grid that shows the archive.
    var unhiddenIDs: Set<String> = []
    /// The viewer found these gone from the server, by asset id, with the month (bucket id) they
    /// were in. Hidden from every view until a fresh copy of that month replaces the guess
    /// (`confirmMissing(inMonths:)`). Not a write: a load never has to start over for them.
    var missingIDs: [String: String] = [:]

    var isEmpty: Bool { favoriteOverrides.isEmpty && trashedIDs.isEmpty && restoredIDs.isEmpty
        && hiddenIDs.isEmpty && unhiddenIDs.isEmpty && missingIDs.isEmpty }

    /// The server sent fresh copies of these months: whatever it says about their assets wins.
    mutating func confirmMissing(inMonths monthIDs: some Sequence<String>) {
        guard !missingIDs.isEmpty else { return }
        let months = Set(monthIDs)
        missingIDs = missingIDs.filter { !months.contains($0.value) }
    }

    /// `source` with favorites updated and trashed, restored, hidden or unhidden assets removed, as `options`
    /// shows them (Favorites drops unfavorited photos, Recently Deleted drops restored ones).
    func applied(to source: [TimelineMonth], options: TimelineOptions) -> [TimelineMonth] {
        // Hide and unhide only move assets between the timeline and the archive: the timeline grid
        // drops hidden photos, the archive grid unhidden ones. Grids that show both (albums,
        // `visibility == nil`) and Recently Deleted are unaffected.
        var removedIDs = (options.isTrashed == true ? restoredIDs : trashedIDs).union(missingIDs.keys)
        switch options.visibility {
        case .timeline?: removedIDs.formUnion(hiddenIDs)
        case .archive?: removedIDs.formUnion(unhiddenIDs)
        case nil: break
        }
        // Without overrides the server's Favorites response is taken as it is.
        let onlyFavorites = options.isFavorite == true && !favoriteOverrides.isEmpty
        guard !favoriteOverrides.isEmpty || !removedIDs.isEmpty else { return source }
        return source.map { original in
            guard let days = original.days else { return original }
            var month = original
            var removed = false
            month.days = days.compactMap { originalDay in
                var day = originalDay
                day.assets = originalDay.assets.compactMap { original in
                    var asset = original
                    if let favorite = favoriteOverrides[asset.id] { asset.isFavorite = favorite }
                    if (onlyFavorites && !asset.isFavorite) || removedIDs.contains(asset.id) {
                        removed = true
                        return nil
                    }
                    return asset
                }
                return day.assets.isEmpty ? nil : day
            }
            // For a changed loaded month, count its actual remaining items. A retained bucket
            // count can belong to a newer response than the days it accompanies.
            if removed || onlyFavorites { month.bucket.count = month.assetCount }
            return month
        }
    }

    /// Throws unless `confirmed` and `failed` split exactly the `requested` IDs: a response that
    /// mentions other assets, or leaves some out, says nothing reliable about what happened.
    static func validate(confirmed: [String], failed: [String], requested: Set<String>) throws {
        let confirmed = Set(confirmed), failed = Set(failed)
        guard confirmed.isSubset(of: requested), failed.isSubset(of: requested),
              confirmed.isDisjoint(with: failed), confirmed.union(failed) == requested else {
            throw ImmichServiceError.invalidResponse
        }
    }
}
