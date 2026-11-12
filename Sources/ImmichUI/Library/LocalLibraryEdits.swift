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

    var isEmpty: Bool { favoriteOverrides.isEmpty && trashedIDs.isEmpty && restoredIDs.isEmpty }

    /// `source` with favorites updated and trashed or restored assets removed, as `options`
    /// shows them (Favorites drops unfavorited photos, Recently Deleted drops restored ones).
    func applied(to source: [TimelineMonth], options: TimelineOptions) -> [TimelineMonth] {
        let removedIDs = options.isTrashed == true ? restoredIDs : trashedIDs
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
