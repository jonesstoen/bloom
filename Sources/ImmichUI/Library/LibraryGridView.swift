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
    /// Follows the fingers while pinching (never animated), relative to the last density switch.
    @State private var liveScale: CGFloat = 1
    /// Bridges a density switch: the new layout starts at the old cell size and springs to 1.
    @State private var settleScale: CGFloat = 1
    /// Magnification at which the current density was reached during this pinch.
    @State private var pinchBaseline: CGFloat = 1
    /// Latest scroll geometry, kept outside observation so scrolling doesn't re-render the view.
    @State private var scrollMetrics = ScrollMetrics()
    /// Years / Months / All (the Library tab only), when no `chrome` shares it with the tab bar.
    @State private var localScale: LibraryScale = .all
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
        _scrollPosition = State(initialValue: ScrollPosition(edge: model.newestFirst ? .top : .bottom))
        self.scrollToNewestTrigger = scrollToNewestTrigger
        self.onSelect = onSelect
    }

    public init(service: any ImmichService, title: String = tr("Library"), headerStyle: HeaderStyle = .navigationBar, allowsTrash: Bool = false, allowsRestore: Bool = false,
                onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)? = nil, onSelect: @escaping (Asset) -> Void = { _ in }) {
        self.init(model: LibraryGridModel(service: service), title: title, headerStyle: headerStyle, allowsTrash: allowsTrash, allowsRestore: allowsRestore, onRestore: onRestore, onSelect: onSelect)
    }

    private static let spacing: CGFloat = 1.5
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
                        } else { densityMenu }
                    }
                }
            }
            .overlay(alignment: .top) {
                if usesLargeTitle { largeHeader }
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
            .onChange(of: scale) { old, new in
                // From All to Months: open Months at the month you were looking at, like Photos.
                if old == .all && new == .months {
                    monthsScrollTarget = model.visibleCenterID.flatMap(model.monthID(ofAsset:))
                }
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
                    service: model.service, loader: model.loader, onMoveToTrash: trashAction, onRestore: restoreAction, onSelection: { id in
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
                    MonthsOverview(model: model, scrollTarget: monthsScrollTarget, topMargin: 96) { asset in
                        model.pendingScrollAssetID = asset.id
                        withAnimation(.snappy(duration: 0.25)) { scale = .all }
                    }
                    .ignoresSafeArea(edges: .top)
                case .years:
                    YearsOverview(model: model, topMargin: 96) { _, coverMonth in
                        monthsScrollTarget = coverMonth
                        withAnimation(.snappy(duration: 0.25)) { scale = .months }
                    }
                    .ignoresSafeArea(edges: .top)
                }
    }


    // MARK: Header

    /// The grid options menu. In the Library tab it has Photos' sort, filter and view options.
    private var densityMenu: some View {
        Menu {
            if usesLargeTitle {
                Picker(tr("Sort"), selection: $sortsByDateAdded) {
                    Text(tr("Sort by Recently Added")).tag(true)
                    Text(tr("Sort by Date Captured")).tag(false)
                }
                .pickerStyle(.inline)
                Menu {
                    Picker(tr("Filter"), selection: $favoritesOnly) {
                        Label(tr("All Items"), systemImage: "photo.on.rectangle").tag(false)
                        Label(tr("Favorites"), systemImage: "heart").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(tr("Filter"), systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            Menu {
                Toggle(isOn: $aspectRatioGrid) {
                    Label(tr("Aspect Ratio Grid"), systemImage: "rectangle.grid.3x2")
                }
                Picker(tr("Columns"), selection: Binding(get: { model.density }, set: { changeDensity($0) })) {
                    ForEach(GridDensity.allCases, id: \.rawValue) { density in
                        Text(tr("%lld Columns", Int64(density.rawValue))).tag(density)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(tr("View Options"), systemImage: "eye")
            }
        } label: {
            Label(tr("Grid options"), systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .disabled(mutationBlocked)
    }

    private var isFiltered: Bool { usesLargeTitle && favoritesOnly }

    /// The timeline options for the current menu choices (the Library tab only).
    private var menuOptions: TimelineOptions {
        var options = model.options
        options.sortsByDateAdded = sortsByDateAdded
        options.isFavorite = favoritesOnly ? true : nil
        return options
    }

    /// Large title and subtitle over a soft blur, with glass buttons on the right, like Photos.
    private var largeHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                // Its own view: the date range changes while scrolling, and reading it here
                // would re-render this whole view (header, menus, scroll view) each time.
                if selection.isSelecting {
                    LibrarySelectionCount(selection: selection)
                } else {
                    LibraryHeaderSubtitle(model: model, scale: scale)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            if selection.isSelecting {
                LibrarySelectionCancelButton(selection: selection)
            } else {
                HStack(spacing: 10) {
                    Button(tr("Select")) {
                        scale = .all
                        selection.start()
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .photosGlass(in: Capsule())
                    .disabled(model.phase != .loaded || model.isEmpty || mutationBlocked)
                    densityMenu
                        .labelStyle(.iconOnly)
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                        .photosGlass(in: Circle())
                    if let accessory { accessory }
                }
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
        GeometryReader { container in
            let layout = gridLayout(width: container.size.width)
            ScrollView {
                VStack(spacing: 0) {
                    GridCells(model: model, selection: selection, window: gridWindow, layout: layout,
                              fillsCells: !(usesLargeTitle && aspectRatioGrid),
                              transition: photoTransition, onTap: open)
                        .equatable()
                    footer
                }
            }
            .contentMargins(.top, usesLargeTitle ? 96 : 0, for: .scrollContent)
            .ignoresSafeArea(edges: usesLargeTitle ? .top : [])
            // Only for the first position; every later scroll is computed from the exact layout.
            .defaultScrollAnchor(model.newestFirst ? .top : .bottom, for: .initialOffset)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
                scrollGeometryChanged(geometry)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { scrollMetrics.userScrolled = true }
            }
            .refreshable {
                guard !mutationBlocked else { return }
                await model.load()
            }
            #if os(iOS)
            // Not clipped: the grid continues behind the tab bar and the Years/Months/All switcher,
            // like Photos (clipping cut it off above the tab bar).
            .scaleEffect(liveScale * settleScale, anchor: .center)
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in pinchChanged(value) }
                    .onEnded { _ in pinchEnded() }
            )
            #endif
            .onChange(of: viewerScrollTarget) { _, id in
                if let id, let index = model.gridIndex(ofAsset: id) { scroll(toCell: index, anchor: 0.5) }
            }
            // Shown again later (e.g. after Months): treat the next layout as a first layout.
            .onDisappear { scrollMetrics.geometry = nil }
            .onChange(of: model.pendingScrollMonthID) { _, _ in scrollToPendingMonth() }
            .onChange(of: model.pendingScrollAssetID) { _, _ in scrollToPendingMonth() }
            .onChange(of: model.gridShift) { _, shift in keepInPlace(shift) }
            .onChange(of: scrollToNewestTrigger) { _, _ in scrollToNewest() }
        }
        .ignoresSafeArea(edges: usesLargeTitle ? .top : [])
    }

    /// Where the scroll view is; every programmatic scroll sets an exact y (see `GridLayout`).
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    /// The rows of cells currently built (only those near the screen).
    @State private var gridWindow = GridWindow()

    private func gridLayout(width: Double, columns: Int? = nil) -> GridLayout {
        GridLayout(width: width, spacing: Self.spacing, columns: columns ?? model.columnCount,
                   itemCount: model.gridItemCount)
    }

    /// Every scroll frame: which rows to build, which cells are on screen, and the first open.
    private func scrollGeometryChanged(_ geometry: ScrollGeometry) {
        let firstLayout = scrollMetrics.geometry == nil
        scrollMetrics.geometry = geometry
        scrollMetrics.pendingOffset = nil
        let layout = gridLayout(width: geometry.containerSize.width)
        buildRows(layout, contentOffset: geometry.contentOffset.y, frameHeight: geometry.visibleRect.height)
        reportScreen(layout, geometry: geometry)
        if firstLayout && !scrollMetrics.didOpen && model.pendingScrollAssetID == nil && model.pendingScrollMonthID == nil {
            scrollMetrics.didOpen = true
            openAtNewest()
        }
        // A pending jump from Months runs once the grid has laid out.
        if firstLayout { scrollToPendingMonth() }
    }

    /// Builds the rows around the part of the content that is (or is about to be) on screen.
    private func buildRows(_ layout: GridLayout, contentOffset: Double, frameHeight: Double) {
        let rows = layout.renderRows(visibleTop: contentOffset, visibleBottom: contentOffset + frameHeight,
                                     margin: 4, chunk: 4)
        if gridWindow.rows != rows { gridWindow.rows = rows }
    }

    /// The cells on screen (between the large title and the tab bar): the header's date range and
    /// whether the tab bar shows the Years / Months / All switcher.
    private func reportScreen(_ layout: GridLayout, geometry: ScrollGeometry) {
        guard let range = layout.screenRange(top: geometry.contentOffset.y + geometry.contentInsets.top,
                                             height: geometry.containerSize.height) else { return }
        model.screenRangeChanged(range)
        guard let chrome else { return }
        let away = LibraryChrome.isAway(visible: range, itemCount: model.gridItemCount,
                                        columns: model.columnCount, newestFirst: model.newestFirst)
        if chrome.isAwayFromNewest != away { chrome.isAwayFromNewest = away }
    }

    /// Scrolls so cell `index` sits at `anchor` of the visible area (0 top, 0.5 middle, 1 bottom).
    /// The rows there are built first, so they are on screen when the scroll lands.
    private func scroll(toCell index: Int, anchor: Double, animation: Animation? = nil) {
        guard let geometry = scrollMetrics.geometry else { return }
        let layout = gridLayout(width: geometry.containerSize.width)
        let y = layout.scrollY(toShow: index, anchor: anchor, visibleHeight: geometry.containerSize.height)
        scroll(toY: y, layout: layout, geometry: geometry, animation: animation)
    }

    private func scroll(toY y: Double, layout: GridLayout, geometry: ScrollGeometry, animation: Animation? = nil) {
        if animation == nil {
            buildRows(layout, contentOffset: y - geometry.contentInsets.top, frameHeight: geometry.visibleRect.height)
        }
        if let animation {
            withAnimation(animation) { scrollPosition.scrollTo(y: y) }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollPosition.scrollTo(y: y) }
        }
    }

    /// Opens at the newest photos, and again once their months have loaded (real counts can differ
    /// from the server's bucket counts), unless the user has started scrolling.
    private func openAtNewest() {
        let count = model.gridItemCount
        guard count > 0 else { return }
        scroll(toCell: model.newestFirst ? 0 : count - 1, anchor: model.newestFirst ? 0 : 1)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard scrollMetrics.geometry != nil, !scrollMetrics.userScrolled, model.gridItemCount > 0 else { return }
            scroll(toCell: model.newestFirst ? 0 : model.gridItemCount - 1, anchor: model.newestFirst ? 0 : 1)
        }
    }

    /// The Library tab was tapped again: back to All and the newest photos, like Photos.
    private func scrollToNewest() {
        if scale != .all { withAnimation(.snappy(duration: 0.25)) { scale = .all } }
        let count = model.gridItemCount
        guard count > 0 else { return }
        // On the next run loop turn, after iOS has started its own scroll to the top, so this
        // scroll replaces it.
        Task { @MainActor in
            await Task.yield()
            scroll(toCell: model.newestFirst ? 0 : count - 1, anchor: model.newestFirst ? 0 : 1,
                   animation: .smooth(duration: 0.45))
        }
    }

    /// Months loaded with a slightly different number of items than their placeholders moved
    /// the photo in the middle of the screen to another cell: scroll so it stays where it was.
    private func keepInPlace(_ shift: LibraryGridModel.GridShift?) {
        guard let shift, let geometry = scrollMetrics.geometry, liveScale == 1, settleScale == 1 else { return }
        let layout = gridLayout(width: geometry.containerSize.width)
        // Where the photo was on screen, from the layout before the change.
        let screenY = Double(layout.origin(of: shift.oldIndex).y) - geometry.contentOffset.y
        guard screenY > -layout.cell, screenY < geometry.visibleRect.height else { return }
        let offset = Double(layout.origin(of: shift.newIndex).y) - screenY
        scroll(toY: offset + geometry.contentInsets.top, layout: layout, geometry: geometry)
    }

    /// Opened from Months: a day centres that photo, a month card shows the month at the top.
    private func scrollToPendingMonth() {
        guard scrollMetrics.geometry != nil else { return }
        if let assetID = model.pendingScrollAssetID {
            model.pendingScrollAssetID = nil
            if let index = model.gridIndex(ofAsset: assetID) { scroll(toCell: index, anchor: 0.5) }
            model.assetShownInViewer(assetID)
            return
        }
        guard let monthID = model.pendingScrollMonthID, let index = model.firstGridIndex(ofMonth: monthID) else { return }
        model.pendingScrollMonthID = nil
        scroll(toCell: index, anchor: 0)
        model.monthAppeared(monthID)
    }

    /// Follows the fingers like Photos: the grid scales live, and as soon as the pinch passes a
    /// step it switches columns around the asset in the middle of the screen. One pinch can step
    /// through several densities.
    private func pinchChanged(_ value: MagnifyGesture.Value) {
        guard !mutationBlocked else { return }
        let relative = value.magnification / pinchBaseline
        let next = model.density.pinched(by: relative)
        if next != model.density {
            pinchBaseline = value.magnification
            switchDensity(to: next, fromVisualScale: liveScale)
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
        guard !mutationBlocked else { return }
        switchDensity(to: density, fromVisualScale: 1)
    }

    /// Switches columns around the photo in the middle of the screen. The layout is exact, so the
    /// new column count and the scroll that keeps that photo in place go in one transaction and
    /// land exactly (measured on the simulator). The new layout is shown scaled to the size the old
    /// cells had on screen and springs to its real size: one continuous motion.
    private func switchDensity(to density: GridDensity, fromVisualScale visual: CGFloat) {
        guard density != model.density else { return }
        let ratio = CGFloat(density.rawValue) / CGFloat(model.density.rawValue)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        guard let geometry = scrollMetrics.geometry else {
            withTransaction(transaction) { model.density = density }
            return
        }
        let width = geometry.containerSize.width
        // A fast pinch can switch again before the grid reports its new offset; then the offset
        // this view scrolled to last time is the current one.
        let currentOffset = scrollMetrics.pendingOffset ?? geometry.contentOffset.y
        let anchor = GridPinchAnchor.anchor(
            offset: currentOffset, focalX: width / 2, focalY: geometry.visibleRect.height / 2,
            width: width, spacing: Self.spacing, from: model.density.rawValue, to: density.rawValue,
            itemCount: model.gridItemCount)
        let newLayout = gridLayout(width: width, columns: density.rawValue)
        withTransaction(transaction) {
            model.density = density
            if let anchor {
                scrollMetrics.pendingOffset = anchor.offset
                scroll(toY: anchor.offset + geometry.contentInsets.top, layout: newLayout, geometry: geometry)
            }
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

/// Placeholder cells of one unloaded month, identified by month and position without
/// allocating an array per month.
struct PlaceholderSlots: RandomAccessCollection {
    struct Slot: Identifiable, Hashable {
        let monthID: String
        let index: Int
        var id: Slot { self }
    }

    let monthID: String
    let count: Int
    var startIndex: Int { 0 }
    var endIndex: Int { count }
    subscript(position: Int) -> Slot { Slot(monthID: monthID, index: position) }
}

/// The Library header's subtitle: the dates on screen in All, the year range in Years.
private struct LibraryHeaderSubtitle: View {
    let model: LibraryGridModel
    let scale: LibraryScale

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .contentTransition(.numericText())
            .animation(.default, value: text)
    }

    private var text: String {
        switch scale {
        case .all where model.options.isFavorite == true: tr("Favorites")
        // Grouped by upload date, the month on screen says when photos were added, not taken.
        case .all where model.options.sortsByDateAdded: tr("Recently Added")
        case .all: model.visibleDateRangeTitle ?? model.visibleMonthTitle ?? model.footerText
        case .months: model.footerText
        case .years:
            if let first = model.years.first?.year, let last = model.years.last?.year, first != last {
                "\(min(first, last))–\(max(first, last))"
            } else {
                model.footerText
            }
        }
    }
}

/// The rows of the grid that have cells built. Observed only by `GridCells`, so moving the window
/// while scrolling doesn't re-render the Library view around it.
@MainActor
@Observable
private final class GridWindow {
    var rows: Range<Int> = 0..<0
}

private final class ScrollMetrics {
    var geometry: ScrollGeometry?
    /// Offset of the last density switch until the grid reports geometry for the new layout.
    var pendingOffset: Double?
    /// The grid has been opened at the newest photos once.
    var didOpen = false
    /// The user has touched the grid (then it is never scrolled for them on open).
    var userScrolled = false
}

private struct ViewerItem: Identifiable {
    let id = UUID()
    let assets: [Asset]
    let selectedID: String
}

/// The cells of the grid: only the rows in `window`, each placed at its exact position in a frame
/// as tall as the whole grid (see `GridLayout`). Split out and `Equatable` so that state changes in
/// the parent (pinch scale on every gesture frame, the viewer's current photo) don't rebuild it;
/// it updates by itself when the window moves or months load (Observation).
private struct GridCells: View, Equatable {
    let model: LibraryGridModel
    let selection: LibrarySelectionModel
    let window: GridWindow
    let layout: GridLayout
    let fillsCells: Bool
    let transition: Namespace.ID
    let onTap: (Asset) -> Void

    static func == (lhs: GridCells, rhs: GridCells) -> Bool {
        lhs.model === rhs.model && lhs.selection === rhs.selection && lhs.window === rhs.window
            && lhs.layout == rhs.layout && lhs.fillsCells == rhs.fillsCells && lhs.transition == rhs.transition
    }

    var body: some View {
        let cell = layout.cell
        ZStack(alignment: .topLeading) {
            // IDs must be unique across the whole grid: the asset id, or the placeholder slot of an
            // unloaded month (plain indices would repeat and confuse identity and transitions).
            ForEach(layout.items(inRows: window.rows).map { index in
                WindowCell(index: index, id: model.gridItemID(atGridIndex: index) ?? AnyHashable(index))
            }) { item in
                let origin = layout.origin(of: item.index)
                content(item)
                    .frame(width: cell, height: cell)
                    .offset(x: origin.x, y: origin.y)
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func content(_ item: WindowCell) -> some View {
        if let asset = model.gridAsset(atGridIndex: item.index) {
            LibrarySelectableCell(asset: asset, model: model, selection: selection,
                                  fillsCell: fillsCells, onOpen: onTap)
            #if os(iOS)
            .matchedTransitionSource(id: asset.id, in: transition)
            #endif
            .onAppear {
                model.assetAppeared(asset.id)
                if let month = model.monthID(ofAsset: asset.id) { model.monthAppeared(month) }
            }
            .onDisappear { model.assetDisappeared(asset.id) }
        } else {
            PlaceholderCell()
                .onAppear {
                    if let month = model.gridMonthID(atGridIndex: item.index) { model.monthAppeared(month) }
                }
        }
    }
}

/// A built cell: its grid index and its identity (asset id or placeholder slot).
private struct WindowCell: Identifiable {
    let index: Int
    let id: AnyHashable
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
