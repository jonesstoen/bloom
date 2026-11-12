import ImmichKit
import SwiftUI

/// The Library tab: every photo in one continuous square grid, like the Photos app's library.
/// Oldest at the top, opening scrolled to the newest at the bottom.
///
/// Months appear right away with placeholder cells sized from the server's counts and load as
/// they scroll into view. Visible cells drive the prefetcher, which loads thumbnails ahead.
public struct LibraryGridView: View {
    @State private var model: LibraryGridModel
    @State private var selection: LibrarySelectionModel
    @State private var viewerItem: ViewerItem?
    @State private var scrollSync: Task<Void, Never>?
    @State private var transitionSourceID: String?
    @State private var viewerScrollTarget: String?
    @State private var densityRequest: DensityRequest?
    /// Years / Months / All (the Library tab only), when no `chrome` shares it with the tab bar.
    @State private var localScale: LibraryScale = .all
    /// Set by a year card: the month Months opens at.
    @State private var monthsScrollTarget: String?
    /// Sort, filter and view options, remembered between launches (the Library tab only).
    @AppStorage("library.sortsByDateAdded") private var sortsByDateAdded = false
    @AppStorage("library.favoritesOnly") private var favoritesOnly = false
    @AppStorage("library.aspectRatioGrid") private var aspectRatioGrid = false
    @AppStorage("library.columns") private var storedColumns = GridDensity.five.rawValue
    @Namespace private var photoTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let title: String
    private let headerStyle: HeaderStyle
    private let accessory: AnyView?
    /// Shared with the tab bar, which then shows the Years / Months / All switcher (iOS 26.1+).
    private let chrome: LibraryChrome?
    private let scrollToNewestTrigger: Int
    private let allowsTrash: Bool
    private let allowsRestore: Bool
    private let onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)?
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
    ///   - scrollToNewestTrigger: changing it scrolls to the newest photos (the tab was tapped again).
    ///   - chrome: state shared with the tab bar, so the Years / Months / All switcher can sit in it.
    public init(model: LibraryGridModel, title: String = tr("Library"), headerStyle: HeaderStyle = .navigationBar,
                accessory: AnyView? = nil, chrome: LibraryChrome? = nil, scrollToNewestTrigger: Int = 0,
                allowsTrash: Bool = false, allowsRestore: Bool = false,
                onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)? = nil, onSelect: @escaping (Asset) -> Void = { _ in }) {
        _model = State(initialValue: model)
        _selection = State(initialValue: LibrarySelectionModel(library: model, onRestore: onRestore))
        self.allowsTrash = allowsTrash
        self.allowsRestore = allowsRestore
        self.onRestore = onRestore
        self.title = title
        self.headerStyle = headerStyle
        self.accessory = accessory
        self.chrome = chrome
        self.scrollToNewestTrigger = scrollToNewestTrigger
        self.onSelect = onSelect
    }

    public init(service: any ImmichService, title: String = tr("Library"), headerStyle: HeaderStyle = .navigationBar, allowsTrash: Bool = false, allowsRestore: Bool = false,
                onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)? = nil, onSelect: @escaping (Asset) -> Void = { _ in }) {
        self.init(model: LibraryGridModel(service: service), title: title, headerStyle: headerStyle, allowsTrash: allowsTrash, allowsRestore: allowsRestore, onRestore: onRestore, onSelect: onSelect)
    }

    private var usesLargeTitle: Bool {
        #if os(iOS)
        headerStyle == .largeTitle
        #else
        false
        #endif
    }

    private var scale: LibraryScale {
        get { chrome?.scale ?? localScale }
        nonmutating set {
            if let chrome { chrome.scale = newValue } else { localScale = newValue }
        }
    }

    private var scaleBinding: Binding<LibraryScale> {
        Binding(get: { scale }, set: { scale = $0 })
    }

    /// iOS 26.1+ with a chrome: the tab bar shows the switcher (`tabViewBottomAccessory`), so the
    /// grid doesn't float its own above it.
    private var switcherInTabBar: Bool {
        #if os(iOS)
        if #available(iOS 26.1, *) { return chrome != nil && usesLargeTitle }
        #endif
        return false
    }

    /// The switcher may show: photos loaded and the selection toolbar isn't using the bottom.
    private var switcherAvailable: Bool {
        usesLargeTitle && model.phase == .loaded && !model.isEmpty && !selection.isSelecting
    }

    private var canMoveToTrash: Bool { allowsTrash && model.options.isTrashed != true }
    private var canRestore: Bool { allowsRestore && model.options.isTrashed == true }
    private var mutationBlocked: Bool { selection.isBusy || selection.pendingTrashAssets != nil || selection.pendingRestoreAssets != nil || model.isMutating }

    public var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(canRestore && mutationBlocked)
            .toolbar(usesLargeTitle ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                if canRestore && selection.isSelecting {
                    ToolbarItem(placement: .principal) { LibrarySelectionCount(selection: selection) }
                }
                if !usesLargeTitle {
                    ToolbarItem(placement: .topBarTrailing) {
                        if canRestore {
                            if selection.isSelecting { LibrarySelectionCancelButton(selection: selection) }
                            else {
                                Button(tr("Select")) { selection.start() }
                                    .disabled(model.phase != .loaded || model.isEmpty || mutationBlocked)
                            }
                        } else { optionsMenu }
                    }
                }
            }
            .overlay(alignment: .top) {
                // Months and Years have no title, like Photos: their month and year titles head
                // the content, which runs up under the status bar.
                if usesLargeTitle && scale == .all {
                    LibraryLargeHeader(title: title, model: model, selection: selection, scale: scale,
                                       mutationBlocked: mutationBlocked, accessory: accessory,
                                       onSelect: { scale = .all; selection.start() }) { optionsMenu }
                        .transition(.opacity)
                } else if usesLargeTitle {
                    StatusBarFade().transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if (usesLargeTitle || canRestore) && (selection.isSelecting || (model.phase == .loaded && !model.isEmpty)) {
                    Group {
                        if selection.isSelecting {
                            LibrarySelectionToolbar(selection: selection, allowsTrash: canMoveToTrash, allowsRestore: canRestore)
                        } else if usesLargeTitle && !switcherInTabBar {
                            LibraryScaleSwitcher(scale: scaleBinding).disabled(mutationBlocked)
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
            .onChange(of: switcherAvailable, initial: true) { _, available in chrome?.isAvailable = available }
            .onChange(of: mutationBlocked, initial: true) { _, blocked in chrome?.isBlocked = blocked }
            .onAppear { chrome?.newestFirst = model.newestFirst }
            .onChange(of: model.density) { _, density in
                if usesLargeTitle { storedColumns = density.rawValue }
            }
            .onChange(of: scrollToNewestTrigger) { _, _ in
                // The grid scrolls to the newest photos itself; this goes back to All.
                if scale != .all { withAnimation(.snappy(duration: 0.25)) { scale = .all } }
            }
            .onChange(of: scale) { old, _ in
                // A year card's month applies to that one visit to Months only.
                if old == .months { monthsScrollTarget = nil }
            }
            .task(id: usesLargeTitle ? menuOptions : model.options) {
                if usesLargeTitle && menuOptions != model.options { await model.setOptions(menuOptions) }
            }
            #endif
            .task {
                if usesLargeTitle, let stored = GridDensity(rawValue: storedColumns) { model.density = stored }
                // Resolve saved sort/filter choices before a fast disk restore can expose
                // the default library partition. The separate task still handles later changes.
                if usesLargeTitle && menuOptions != model.options { await model.setOptions(menuOptions) }
                if model.phase == .idle || model.needsMutationRefresh { await model.load() }
                // The Library tab: load every month in the background once the newest ones are
                // on screen, so Years and Months open instantly later.
                if usesLargeTitle && model.phase == .loaded {
                    try? await Task.sleep(for: .seconds(1.5))
                    if !Task.isCancelled { await model.loadAllMonths() }
                }
            }
            .modifier(LibrarySelectionPresentation(selection: selection))
            .onDisappear {
                model.stopPrefetching()
                if selection.isPreparingShare { selection.cancelSharePreparation() }
            }
            #if os(iOS)
            .fullScreenCover(item: $viewerItem) { item in
                if reduceMotion || transitionSourceID == nil {
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
        let trashAction: (@MainActor (Asset) async throws -> Void)?
        if canMoveToTrash { trashAction = { asset in try await moveToTrash(asset) } }
        else { trashAction = nil }
        let restoreAction: (@MainActor (Asset) async throws -> Void)?
        if canRestore { restoreAction = { asset in try await restore(asset) } }
        else { restoreAction = nil }
        return AssetViewer(assets: item.assets, selectedID: item.selectedID,
                    service: model.service, loader: model.loader, thumbnails: model.images, onMoveToTrash: trashAction, onRestore: restoreAction, onSelection: { id in
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
        })
    }

    private func restore(_ asset: Asset) async throws {
        scrollSync?.cancel()
        scrollSync = nil
        viewerScrollTarget = nil
        let result = try await model.restoreFromTrash([asset], perform: onRestore)
        guard result.confirmedIDs.contains(asset.id) else { throw ImmichServiceError.invalidResponse }
        if transitionSourceID == asset.id { transitionSourceID = nil }
    }

    private func moveToTrash(_ asset: Asset) async throws {
        scrollSync?.cancel()
        scrollSync = nil
        viewerScrollTarget = nil
        let result = try await model.moveToTrash([asset])
        guard result.confirmedIDs.contains(asset.id) else { throw ImmichServiceError.invalidResponse }
        // The removed transition source must not trigger another scroll after dismissal.
        if transitionSourceID == asset.id { transitionSourceID = nil }
    }

    private func open(_ asset: Asset) {
        // Start downloading the preview now; the viewer's page joins this request when it appears.
        let loader = model.loader
        Task { _ = try? await loader.data(for: ImageKey(assetID: asset.id, size: .preview)) }
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
                Label(tr("Can't Load Library"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(tr("Try Again")) { Task { await model.load() } }
            }
        case .loaded where model.isEmpty:
            ContentUnavailableView(
                tr("No Photos or Videos"),
                systemImage: "photo.on.rectangle",
                description: Text(tr("Photos and videos you upload to Immich appear here."))
            )
        case .loaded:
            if usesLargeTitle {
                // The grid stays alive (hidden) under Years and Months: rebuilding 10 000+ cells
                // made returning to All slow, and it keeps its scroll position.
                ZStack {
                    grid
                        .opacity(scale == .all ? 1 : 0)
                        .allowsHitTesting(scale == .all)
                        .accessibilityHidden(scale != .all)
                    overview
                }
            } else {
                grid
            }
        }
    }

    @ViewBuilder
    private var overview: some View {
        switch scale {
        case .all: EmptyView()
        case .months:
            // A year card's month, or else the month you were looking at in All, like Photos.
            // Decided here, as Months is built: set later (onChange), Months had already
            // opened at the newest months.
            MonthsOverview(model: model, scrollTarget: monthsScrollTarget ?? model.visibleCenterID.flatMap(model.monthID(ofAsset:)),
                           topMargin: 8) { asset in
                model.pendingScrollAssetID = asset.id
                withAnimation(.snappy(duration: 0.25)) { scale = .all }
            }
        case .years:
            YearsOverview(model: model, topMargin: 8) { _, coverMonth in
                monthsScrollTarget = coverMonth
                withAnimation(.snappy(duration: 0.25)) { scale = .months }
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        LibraryGridScroll(model: model, selection: selection, chrome: chrome, usesLargeTitle: usesLargeTitle,
                          fillsCells: !(usesLargeTitle && aspectRatioGrid), mutationBlocked: mutationBlocked,
                          viewerScrollTarget: viewerScrollTarget, scrollToNewestTrigger: scrollToNewestTrigger,
                          densityRequest: densityRequest, transition: photoTransition, onTap: open)
    }

    // MARK: Options

    private var optionsMenu: some View {
        LibraryOptionsMenu(showsSortAndFilter: usesLargeTitle, sortsByDateAdded: $sortsByDateAdded,
                           favoritesOnly: $favoritesOnly, aspectRatioGrid: $aspectRatioGrid,
                           density: Binding(get: { model.density },
                                            set: { if !mutationBlocked { densityRequest = DensityRequest(density: $0) } }))
            .disabled(mutationBlocked)
    }

    /// The timeline options for the current menu choices (the Library tab only).
    private var menuOptions: TimelineOptions {
        var options = model.options
        options.sortsByDateAdded = sortsByDateAdded
        options.isFavorite = favoritesOnly ? true : nil
        return options
    }
}

private struct ViewerItem: Identifiable {
    let id = UUID()
    let assets: [Asset]
    let selectedID: String
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

/// A soft blur behind the status bar for Months and Years, which have no header: the content
/// scrolls up under it, like Photos.
private struct StatusBarFade: View {
    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .mask(LinearGradient(colors: [.black, .black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
            // Grows up over the status bar from a few points below it.
            .frame(height: 10)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
