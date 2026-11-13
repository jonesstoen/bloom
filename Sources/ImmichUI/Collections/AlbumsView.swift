import ImmichKit
import SwiftUI

public struct AlbumsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.allowsLibraryChanges) private var allowsChanges
    @State private var model: CollectionsModel

    public init(service: any ImmichService, loader: ImageLoader? = nil) {
        _model = State(initialValue: CollectionsModel(service: service, loader: loader))
    }

    @State private var naming = false
    @State private var newName = ""
    @State private var createError: String?

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CollectionLoadState(isEmpty: model.albums.isEmpty, isLoading: model.loadingAlbums,
                                    hasLoaded: model.loadedAlbums, error: model.albumsError,
                                    errorTitle: tr("Can't Load Albums"),
                                    emptyTitle: tr("No Albums"), emptySymbol: "rectangle.stack",
                                    emptyDescription: tr("Albums you create in Immich appear here."),
                                    retry: { await model.loadAlbums() }) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(model.albums) { album in
                            NavigationLink {
                                AlbumDetailView(album: album, service: model.service, loader: model.loader)
                            } label: {
                                albumCard(album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .navigationTitle(tr("Albums"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { if !model.loadedAlbums { await model.loadAlbums() } }
        .refreshable { await model.loadAlbums() }
        .onReceive(NotificationCenter.default.publisher(for: .bloomAlbumsDidChange)) { _ in
            Task { await model.loadAlbums() }
        }
        .toolbar {
            if allowsChanges {
                ToolbarItem(placement: .primaryAction) {
                    Button(tr("New Album"), systemImage: "plus") { naming = true }
                }
            }
        }
        .alert(tr("New Album"), isPresented: $naming) {
            TextField(tr("Title"), text: $newName)
            Button(tr("Cancel"), role: .cancel) { newName = "" }
            Button(tr("Save")) {
                let name = newName
                newName = ""
                Task {
                    do {
                        _ = try await model.service.createAlbum(name: name, assetIDs: [])
                        NotificationCenter.default.post(name: .bloomAlbumsDidChange, object: nil)
                    } catch { createError = tr("Couldn't create the album. Please try again.") }
                }
            }
        }
        .alert(createError ?? "", isPresented: Binding(get: { createError != nil }, set: { if !$0 { createError = nil } })) {
            Button(tr("OK")) { createError = nil }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 150),
                  spacing: 16, alignment: .top)]
    }

    private func albumCard(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CollectionThumbnail(key: album.thumbnailAssetId.map { ImageKey(assetID: $0, size: .thumbnail) },
                                loader: model.loader, symbol: "rectangle.stack")
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.65)],
                                   startPoint: .center, endPoint: .bottom)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .bottomLeading) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(album.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.6), radius: 3)
                            .padding(12)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            if dynamicTypeSize.isAccessibilitySize {
                Text(album.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(tr("%@ items", album.assetCount.formatted(.number.locale(Localization.locale))))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(album.name)
        .accessibilityValue(tr("%@ items", album.assetCount.formatted(.number.locale(Localization.locale))))
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

    public var body: some View { LibraryGridView(model: model, title: album.name, allowsSelection: true) }
}

#Preview("Albums") { NavigationStack { AlbumsView(service: MockImmichService.preview) } }
#Preview("Albums — large text") {
    NavigationStack { AlbumsView(service: MockImmichService.preview) }
        .environment(\.dynamicTypeSize, .accessibility3)
}
#Preview("Albums — empty") {
    NavigationStack { AlbumsView(service: MockImmichService()) }
}
#Preview("Album detail") {
    NavigationStack { AlbumDetailView(album: MockLibrary.standard.albums[0], service: MockImmichService.preview) }
}
