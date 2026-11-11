import ImmichKit
import SwiftUI

public struct AlbumsView: View {
    @State private var model: CollectionsModel

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        _model = State(initialValue: CollectionsModel(service: service, loader: loader))
    }

    public var body: some View {
        ScrollView {
            if let error = model.albumsError {
                ContentUnavailableView {
                    Label("Can't Load Albums", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await model.loadAlbums() } }
                }
            }
            if model.loadingAlbums && model.albums.isEmpty { ProgressView().padding() }
            if model.loadedAlbums && model.albums.isEmpty {
                ContentUnavailableView("No Albums", systemImage: "rectangle.stack", description: Text("Albums you create in Immich appear here."))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 24) {
                ForEach(model.albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album, service: model.service, loader: model.loader)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CollectionThumbnail(key: album.thumbnailAssetId.map { ImageKey(assetID: $0, size: .thumbnail) }, loader: model.loader)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(album.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                            Text("\(album.assetCount.formatted()) items").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }.buttonStyle(.plain)
                }
            }.padding()
        }
        .navigationTitle("Albums")
        .task { if !model.loadedAlbums { await model.loadAlbums() } }
        .refreshable { await model.loadAlbums() }
    }
}

public struct AlbumDetailView: View {
    @State private var model: LibraryGridModel
    private let album: Album

    public init(album: Album, service: any ImmichService, loader: ImageLoader? = nil) {
        self.album = album
        var options = TimelineOptions.album(album.id)
        options.newestFirst = album.isNewestFirst
        _model = State(initialValue: LibraryGridModel(service: service, options: options, loader: loader))
    }

    public var body: some View { LibraryGridView(model: model, title: album.name) }
}

#Preview("Albums") { NavigationStack { AlbumsView(service: MockImmichService.preview) } }
#Preview("Album detail") {
    NavigationStack { AlbumDetailView(album: MockLibrary.standard.albums[0], service: MockImmichService.preview) }
}
