import ImmichKit
import SwiftUI

/// The Library tab: every photo in one continuous square grid, like the Photos app's library.
/// Oldest at the top, opening scrolled to the newest at the bottom.
///
/// Months appear right away with placeholder cells sized from the server's counts and load as
/// they scroll into view. Visible cells drive the prefetcher, which loads thumbnails ahead.
public struct LibraryGridView: View {
    @State private var model: LibraryGridModel
    @State private var viewerItem: ViewerItem?
    @State private var scrollSync: Task<Void, Never>?
    @State private var transitionSourceID: String?
    @State private var viewerScrollTarget: String?
    /// Follows the fingers while pinching (never animated), relative to the last density switch.
    @State private var liveScale: CGFloat = 1
    /// Bridges a density switch: the new layout starts at the old cell size and springs to 1.
    @State private var settleScale: CGFloat = 1
    /// Magnification at which the current density was reached during this pinch.
    @State private var pinchBaseline: CGFloat = 1
    @Namespace private var photoTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let title: String
    private let headerStyle: HeaderStyle
    private let accessory: AnyView?
    private let onSelect: (Asset) -> Void

    public enum HeaderStyle: Sendable {
        /// Photos' library tab: a large title floating over the photos, with glass buttons.
        case largeTitle
        /// A regular navigation bar with a back button (album and person grids).
        case navigationBar
    }

    /// - Parameters:
    ///   - title: the title ("Library").
    ///   - headerStyle: `.largeTitle` for a top-level tab, `.navigationBar` when pushed.
    ///   - accessory: extra glass button(s) shown next to the grid options (e.g. the account menu).
    ///   - onSelect: called when an asset is tapped (opens the viewer).
    public init(model: LibraryGridModel, title: String = "Library", headerStyle: HeaderStyle = .navigationBar,
                accessory: AnyView? = nil, onSelect: @escaping (Asset) -> Void = { _ in }) {
        _model = State(initialValue: model)
        self.title = title
        self.headerStyle = headerStyle
        self.accessory = accessory
        self.onSelect = onSelect
    }

    public init(service: any ImmichService, title: String = "Library", headerStyle: HeaderStyle = .navigationBar,
                onSelect: @escaping (Asset) -> Void = { _ in }) {
        self.init(model: LibraryGridModel(service: service), title: title, headerStyle: headerStyle, onSelect: onSelect)
    }

    private static let spacing: CGFloat = 1.5
    private var usesLargeTitle: Bool {
        #if os(iOS)
        headerStyle == .largeTitle
        #else
        false
        #endif
    }

    public var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(usesLargeTitle ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                if !usesLargeTitle {
                    ToolbarItem(placement: .topBarTrailing) { densityMenu }
                }
            }
            .overlay(alignment: .top) {
                if usesLargeTitle { largeHeader }
            }
            #endif
            .task {
                if model.phase == .idle { await model.load() }
            }
            .onDisappear { model.stopPrefetching() }
            #if os(iOS)
            .fullScreenCover(item: $viewerItem) { item in
                if reduceMotion {
                    viewer(item)
                } else {
                    viewer(item)
                        .navigationTransition(.zoom(sourceID: transitionSourceID ?? item.selectedID, in: photoTransition))
                }
            }
            #else
            .sheet(item: $viewerItem) { item in viewer(item).frame(minWidth: 700, minHeight: 500) }
            #endif
    }

    /// The viewer gets its list of assets once, when it opens, so swiping doesn't rebuild it.
    private func viewer(_ item: ViewerItem) -> some View {
        AssetViewer(assets: item.assets, selectedID: item.selectedID,
                    service: model.service, loader: model.loader) { id in
            guard transitionSourceID != id else { return }
            transitionSourceID = id
            model.assetShownInViewer(id)
            // Keep the photo's cell on screen behind the viewer (so closing zooms back into it),
            // but only once swiping pauses: scrolling the grid on every swipe loads thumbnails
            // the user can't see and makes paging stutter.
            scrollSync?.cancel()
            scrollSync = Task {
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled { viewerScrollTarget = id }
            }
        }
    }

    private func open(_ asset: Asset) {
        transitionSourceID = asset.id
        viewerItem = ViewerItem(assets: model.viewerAssets(around: asset.id), selectedID: asset.id)
        onSelect(asset)
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

    // MARK: Header

    private var densityMenu: some View {
        Menu {
            Picker("Grid", selection: Binding(get: { model.density }, set: { changeDensity($0) })) {
                ForEach(GridDensity.allCases, id: \.rawValue) { density in
                    Text("\(density.rawValue) Columns").tag(density)
                }
            }
        } label: {
            Label("Grid options", systemImage: "line.3.horizontal.decrease")
        }
    }

    /// Large title and subtitle over a soft blur, with glass buttons on the right, like Photos.
    private var largeHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                Text(model.visibleMonthTitle ?? model.footerText)
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())
                    .animation(.default, value: model.visibleMonthTitle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            HStack(spacing: 10) {
                densityMenu
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .photosGlass(in: Circle())
                if let accessory { accessory }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollViewReader { proxy in
        ScrollView {
            GridCells(model: model, columnCount: model.columnCount, spacing: Self.spacing,
                      transition: photoTransition, onTap: open)
                .equatable()
            footer
        }
        .contentMargins(.top, usesLargeTitle ? 96 : 0, for: .scrollContent)
        .ignoresSafeArea(edges: usesLargeTitle ? .top : [])
        // Only for the first position: anchoring on later size changes (e.g. a new column count)
        // fights the scroll to the pinch anchor and can leave the screen on unrendered rows.
        .defaultScrollAnchor(model.newestFirst ? .top : .bottom, for: .initialOffset)
        .refreshable { await model.load() }
        #if os(iOS)
        .scaleEffect(liveScale * settleScale, anchor: .center)
        .clipped()
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in pinchChanged(value, proxy: proxy) }
                .onEnded { _ in pinchEnded() }
        )
        #endif
        .onChange(of: viewerScrollTarget) { _, id in
            if let id { proxy.scrollTo(id, anchor: .center) }
        }
        .onAppear { densityProxy = proxy }
        }
    }

    @State private var densityProxy: ScrollViewProxy?

    /// Follows the fingers like Photos: the grid scales live, and as soon as the pinch passes a
    /// step it switches columns around the asset in the middle of the screen. One pinch can step
    /// through several densities.
    private func pinchChanged(_ value: MagnifyGesture.Value, proxy: ScrollViewProxy) {
        let relative = value.magnification / pinchBaseline
        let next = model.density.pinched(by: relative)
        if next != model.density {
            pinchBaseline = value.magnification
            switchDensity(to: next, proxy: proxy, fromVisualScale: liveScale)
        } else {
            // Rubber-band at the ends (3 or 7 columns): the grid only gives a little.
            let atLimit = (relative > 1 && model.density == .three) || (relative < 1 && model.density == .seven)
            let resistance: CGFloat = atLimit ? 0.15 : 0.6
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { liveScale = 1 + (relative - 1) * resistance }
        }
    }

    private func pinchEnded() {
        pinchBaseline = 1
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { liveScale = 1 }
    }

    private func changeDensity(_ density: GridDensity) {
        guard let proxy = densityProxy else { model.density = density; return }
        switchDensity(to: density, proxy: proxy, fromVisualScale: 1)
    }

    /// Switches columns without animating the grid's layout (relayouting thousands of cells in an
    /// animation is what made everything reload). Instead the new layout is shown scaled to the
    /// size the old cells had on screen and springs to its real size: one continuous motion.
    private func switchDensity(to density: GridDensity, proxy: ScrollViewProxy, fromVisualScale visual: CGFloat) {
        guard density != model.density else { return }
        let anchor = model.visibleCenterID
        let ratio = CGFloat(density.rawValue) / CGFloat(model.density.rawValue)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.density = density
            if let anchor { proxy.scrollTo(anchor, anchor: .center) }
            liveScale = 1
            settleScale = reduceMotion ? 1 : visual * ratio * settleScale
        }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0)) { settleScale = 1 }
    }

    private var footer: some View {
        Text(model.footerText)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

private struct ViewerItem: Identifiable {
    let id = UUID()
    let assets: [Asset]
    let selectedID: String
}

/// The cells of the grid, split out and `Equatable` so that state changes in the parent
/// (pinch scale on every gesture frame, the viewer's current photo) don't rebuild 10 000+
/// cells. It still updates by itself when the model's months load (Observation).
private struct GridCells: View, Equatable {
    let model: LibraryGridModel
    let columnCount: Int
    let spacing: CGFloat
    let transition: Namespace.ID
    let onTap: (Asset) -> Void

    static func == (lhs: GridCells, rhs: GridCells) -> Bool {
        lhs.model === rhs.model && lhs.columnCount == rhs.columnCount
            && lhs.spacing == rhs.spacing && lhs.transition == rhs.transition
    }

    var body: some View {
        // One continuous grid across months, like Photos (no section breaks).
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(1, columnCount)),
                  spacing: spacing) {
            ForEach(model.months) { month in
                cells(for: month)
            }
        }
    }

    @ViewBuilder
    private func cells(for month: TimelineMonth) -> some View {
        if month.isLoaded {
            ForEach(month.assets) { asset in
                Button { onTap(asset) } label: {
                    ThumbnailCell(asset: asset, loader: model.loader, images: model.images)
                }
                .buttonStyle(.plain)
                .id(asset.id)
                #if os(iOS)
                .matchedTransitionSource(id: asset.id, in: transition)
                #endif
                .onAppear {
                    model.assetAppeared(asset.id)
                    model.monthAppeared(month.id)
                }
                .onDisappear { model.assetDisappeared(asset.id) }
            }
        } else {
            ForEach(0..<month.bucket.count, id: \.self) { _ in
                PlaceholderCell()
                    .onAppear { model.monthAppeared(month.id) }
            }
        }
    }
}

// MARK: - Previews

#Preview("Library") {
    let mock = MockImmichService.preview
    return NavigationStack {
        LibraryGridView(model: LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil)),
                        headerStyle: .largeTitle)
    }
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
