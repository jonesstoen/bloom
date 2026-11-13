import ImmichKit
import Observation
import SwiftUI

/// The assets of a fixed metadata search (all videos, all Live Photos, one place), newest
/// first, loaded page by page.
@MainActor @Observable
public final class QueryGridModel {
    public private(set) var assets: [Asset] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var error: String?
    @ObservationIgnored public let query: MetadataSearchQuery
    @ObservationIgnored public let service: any ImmichService
    @ObservationIgnored public let loader: ImageLoader
    @ObservationIgnored private var next: SearchPageToken?
    @ObservationIgnored private var seenTokens: Set<SearchPageToken> = []
    @ObservationIgnored private var seenIDs: Set<String> = []
    @ObservationIgnored let pageSize: Int

    public init(query: MetadataSearchQuery, service: any ImmichService, loader: ImageLoader? = nil, pageSize: Int = 200) {
        self.query = query
        self.service = service
        self.loader = loader ?? ImageLoader(service: service)
        self.pageSize = pageSize
    }

    public var canLoadMore: Bool { next != nil }

    /// Loads the first page, or the next one.
    public func loadMore() async {
        guard !isLoading, !hasLoaded || next != nil else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let results = try await service.metadataSearch(query, page: next, size: pageSize)
            try Task.checkCancellation()
            let fresh = results.assets.filter { seenIDs.insert($0.id).inserted }
            assets.append(contentsOf: fresh)
            // Stop if the server repeats a page token (it would loop forever).
            if let token = results.next, seenTokens.insert(token).inserted, !fresh.isEmpty {
                next = token
            } else {
                next = nil
            }
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            self.error = tr("Couldn't load these items. Please try again.")
        }
    }
}

/// A Photos-style grid for a `QueryGridModel`, opening the viewer on tap.
public struct QueryGridView: View {
    @State private var model: QueryGridModel
    @State private var selected: Asset?
    private let title: String
    private let emptyMessage: String
    @State private var images = ThumbnailImageCache()

    public init(title: String, query: MetadataSearchQuery, service: any ImmichService,
                loader: ImageLoader? = nil, emptyMessage: String = tr("Nothing here yet.")) {
        _model = State(initialValue: QueryGridModel(query: query, service: service, loader: loader))
        self.title = title
        self.emptyMessage = emptyMessage
    }

    public var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1.5), count: 3), spacing: 1.5) {
                ForEach(model.assets) { asset in
                    Button { selected = asset } label: {
                        ThumbnailCell(asset: asset, loader: model.loader, images: images)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if asset.id == model.assets.last?.id, model.error == nil {
                            Task { await model.loadMore() }
                        }
                    }
                }
            }
            if model.isLoading { ProgressView().padding() }
            if let error = model.error, !model.assets.isEmpty {
                VStack(spacing: 12) {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(tr("Try Again")) { Task { await model.loadMore() } }
                }
                .padding()
            }
            if model.hasLoaded && !model.assets.isEmpty {
                Text(tr("%@ Items", "\(model.assets.count.formatted(.number.locale(Localization.locale)))\(model.canLoadMore ? "+" : "")"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            }
        }
        .overlay {
            if let error = model.error, model.assets.isEmpty {
                ContentUnavailableView {
                    Label(tr("Can't Load"), systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button(tr("Try Again")) { Task { await model.loadMore() } }
                }
            } else if model.hasLoaded && model.assets.isEmpty {
                ContentUnavailableView(title, systemImage: "photo.on.rectangle", description: Text(emptyMessage))
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selected) { asset in
            AssetViewer(assets: model.assets, selectedID: asset.id, service: model.service, loader: model.loader, thumbnails: images)
        }
        #else
        .sheet(item: $selected) { asset in
            AssetViewer(assets: model.assets, selectedID: asset.id, service: model.service, loader: model.loader, thumbnails: images)
                .frame(minWidth: 700, minHeight: 500)
        }
        #endif
        .task { if !model.hasLoaded { await model.loadMore() } }
    }
}

#Preview("Videos") {
    NavigationStack {
        QueryGridView(title: tr("Videos"), query: MetadataSearchQuery(filters: SearchFilters(kind: .video)),
                      service: MockImmichService.preview)
    }
}
