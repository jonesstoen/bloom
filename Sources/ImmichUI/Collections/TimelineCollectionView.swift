import ImmichKit
import SwiftUI

/// A timeline-backed collection (Recently Added, Archive, Recently Deleted) in the library grid.
public struct TimelineCollectionView: View {
    @State private var model: LibraryGridModel
    private let title: String

    private let allowsRestore: Bool
    private let onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)?

    public init(title: String, options: TimelineOptions, service: any ImmichService, loader: ImageLoader? = nil,
                allowsRestore: Bool = false, onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)? = nil) {
        _model = State(initialValue: LibraryGridModel(service: service, options: options, loader: loader))
        self.title = title
        self.allowsRestore = allowsRestore
        self.onRestore = onRestore
    }

    public var body: some View { LibraryGridView(model: model, title: title, allowsRestore: allowsRestore, onRestore: onRestore) }
}

/// All favorite photos and videos in the library grid.
public struct FavoritesView: View {
    @State private var model: LibraryGridModel

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        _model = State(initialValue: LibraryGridModel(
            service: service, options: TimelineOptions(isFavorite: true, newestFirst: false), loader: loader))
    }

    public var body: some View { LibraryGridView(model: model, title: tr("Favorites")) }
}

#Preview("Favorites") {
    NavigationStack { FavoritesView(service: MockImmichService.preview) }
}
