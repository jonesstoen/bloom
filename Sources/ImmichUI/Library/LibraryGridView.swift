import ImmichKit
import SwiftUI

/// The Library tab: every photo in a square grid with one section per month, like
/// "All Photos" in the Photos app. Oldest at the top, opening scrolled to the newest at the bottom.
///
/// Months appear right away with placeholder cells sized from the server's counts and load as
/// they scroll into view. Visible cells drive the prefetcher, which loads thumbnails ahead.
public struct LibraryGridView: View {
    @State private var model: LibraryGridModel
    @State private var selectedAsset: Asset?
    @State private var transitionSourceID: String?
    @State private var viewerScrollTarget: String?
    @State private var densityAnchorID: String?
    @Namespace private var photoTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let title: String
    private let onSelect: (Asset) -> Void

    /// - Parameters:
    ///   - title: navigation title ("Library").
    ///   - onSelect: called when an asset is tapped (opens the viewer).
    public init(model: LibraryGridModel, title: String = "Library", onSelect: @escaping (Asset) -> Void = { _ in }) {
        _model = State(initialValue: model)
        self.title = title
        self.onSelect = onSelect
    }

    public init(service: any ImmichService, title: String = "Library", onSelect: @escaping (Asset) -> Void = { _ in }) {
        self.init(model: LibraryGridModel(service: service), title: title, onSelect: onSelect)
    }

    private static let spacing: CGFloat = 2

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: max(1, model.columnCount))
    }

    public var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Menu {
                    ForEach(GridDensity.allCases, id: \.rawValue) { density in
                        Button { changeDensity(density) } label: {
                            if density == model.density {
                                Label("\(density.rawValue) Columns", systemImage: "checkmark")
                            } else { Text("\(density.rawValue) Columns") }
                        }
                    }
                } label: { Label("Grid density", systemImage: "square.grid.3x3") }
            }
            #endif
            .task {
                if model.phase == .idle { await model.load() }
            }
            .onDisappear { model.stopPrefetching() }
            #if os(iOS)
            .fullScreenCover(item: $selectedAsset) { asset in
                if reduceMotion {
                    viewer(asset)
                } else {
                    viewer(asset)
                        .navigationTransition(.zoom(sourceID: transitionSourceID ?? asset.id, in: photoTransition))
                }
            }
            #else
            .sheet(item: $selectedAsset) { asset in viewer(asset).frame(minWidth: 700, minHeight: 500) }
            #endif
    }

    private func viewer(_ asset: Asset) -> some View {
        AssetViewer(assets: model.viewerAssets(around: transitionSourceID ?? asset.id), selectedID: asset.id,
                    service: model.service, loader: model.loader) { id in
            if transitionSourceID != id {
                transitionSourceID = id
                viewerScrollTarget = id
            }
            if let month = model.months.first(where: { $0.assets.contains(where: { $0.id == id }) }) {
                model.monthAppeared(month.id)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Load Library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        case .loaded where model.isEmpty:
            ContentUnavailableView(
                "No Photos or Videos",
                systemImage: "photo.on.rectangle",
                description: Text("Photos and videos you upload to Immich appear here.")
            )
        case .loaded:
            grid
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.spacing, pinnedViews: [.sectionHeaders]) {
                ForEach(model.months) { month in
                    Section {
                        cells(for: month)
                    } header: {
                        MonthHeader(title: LibraryGridModel.monthTitle(for: month.bucket))
                    }
                }
            }
            footer
        }
        .defaultScrollAnchor(model.newestFirst ? .top : .bottom)
        .refreshable { await model.load() }
        #if os(iOS)
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            changeDensity(model.density.pinched(by: value.magnification))
        })
        #endif
        .onChange(of: model.density) { _, _ in
            if let id = densityAnchorID { proxy.scrollTo(id, anchor: .top) }
        }
        .onChange(of: viewerScrollTarget) { _, id in
            if let id { proxy.scrollTo(id, anchor: .center) }
        }
        }
    }

    private func changeDensity(_ density: GridDensity) {
        guard density != model.density else { return }
        densityAnchorID = model.visibleAnchorID
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { model.density = density }
    }

    @ViewBuilder
    private func cells(for month: TimelineMonth) -> some View {
        if month.isLoaded {
            ForEach(month.assets) { asset in
                Button { transitionSourceID = asset.id; selectedAsset = asset; onSelect(asset) } label: {
                    ThumbnailCell(asset: asset, loader: model.loader, images: model.images)
                }
                .buttonStyle(.plain)
                .id(asset.id)
                #if os(iOS)
                .matchedTransitionSource(id: asset.id, in: photoTransition)
                #endif
                .onAppear {
                    model.assetAppeared(asset.id)
                    model.monthAppeared(month.id)
                }
                .onDisappear { model.assetDisappeared(asset.id) }
            }
        } else {
            ForEach(0..<month.bucket.count, id: \.self) { index in
                PlaceholderCell()
                    .onAppear { model.monthAppeared(month.id) }
            }
        }
    }

    private var footer: some View {
        Text(model.footerText)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

/// Month section header on a bar material, pinned while its section scrolls.
private struct MonthHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Previews

#Preview("Library") {
    let mock = MockImmichService.preview
    return NavigationStack {
        LibraryGridView(model: LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil)))
    }
}

#Preview("Month header") {
    let _ = MockImmichService.preview
    MonthHeader(title: "June 2026")
}

#Preview("Newest first, slow") {
    NavigationStack {
        LibraryGridView(model: LibraryGridModel(
            service: MockImmichService(library: .standard, latency: .milliseconds(400)),
            options: .library,
            loader: nil
        ))
    }
}

#Preview("Empty") {
    NavigationStack {
        LibraryGridView(service: MockImmichService())
    }
}

#Preview("Error") {
    // The latency gives the failure time to be set before the first request returns.
    let mock = MockImmichService(library: .small, latency: .milliseconds(300))
    return NavigationStack {
        LibraryGridView(service: mock)
    }
    .task { await mock.setFailure(.network("The request timed out.")) }
}
