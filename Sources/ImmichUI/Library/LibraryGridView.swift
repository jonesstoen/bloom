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
        ScrollViewReader { proxy in
        ScrollView {
            GridCells(model: model, selection: selection, columnCount: model.columnCount, spacing: Self.spacing,
                      fillsCells: !(usesLargeTitle && aspectRatioGrid),
                      transition: photoTransition, onTap: open)
                .equatable()
            footer
        }
        .contentMargins(.top, usesLargeTitle ? 96 : 0, for: .scrollContent)
        .ignoresSafeArea(edges: usesLargeTitle ? .top : [])
        // Only for the first position: anchoring on later size changes (e.g. a new column count)
        // fights the scroll to the pinch anchor and can leave the screen on unrendered rows.
        .defaultScrollAnchor(model.newestFirst ? .top : .bottom, for: .initialOffset)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
            let firstLayout = scrollMetrics.geometry == nil
            scrollMetrics.geometry = geometry
            scrollMetrics.pendingOffset = nil
            if firstLayout && !scrollMetrics.didOpen && model.pendingScrollAssetID == nil && model.pendingScrollMonthID == nil {
                scrollMetrics.didOpen = true
                openAtNewest(proxy)
            }
            // A pending jump from Months runs once the grid has laid out; before that the
            // initial bottom anchor would override it.
            if firstLayout { scrollToPendingMonth(proxy) }
        }
        // The cells actually on screen (at least half visible, between the large title and the
        // tab bar). Not computed from the scroll offset: LazyVGrid estimates the height of rows it
        // hasn't built, so after a pinch the offset pointed at photos months away.
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.5) { ids in
            screenCellsChanged(ids)
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
                .onChanged { value in pinchChanged(value, proxy: proxy) }
                .onEnded { _ in pinchEnded() }
        )
        #endif
        .onChange(of: viewerScrollTarget) { _, id in
            if let id { proxy.scrollTo(id, anchor: .center) }
        }
        .onAppear { densityProxy = proxy }
        // Shown again later (e.g. after Months): treat the next layout as a first layout.
        .onDisappear { scrollMetrics.geometry = nil }
        .onChange(of: model.pendingScrollMonthID) { _, _ in scrollToPendingMonth(proxy) }
        .onChange(of: model.pendingScrollAssetID) { _, _ in scrollToPendingMonth(proxy) }
        .onChange(of: model.gridShift) { _, shift in keepInPlace(shift, proxy: proxy) }
        .onChange(of: scrollToNewestTrigger) { _, _ in scrollToNewest(proxy) }
        }
    }

    @State private var densityProxy: ScrollViewProxy?
    /// Re-checks that a pinch's anchor photo ended up on screen (see `confirmAnchor`).
    @State private var anchorCheck: Task<Void, Never>?

    /// The loaded cells on screen changed: the header's date range, and whether the tab bar shows
    /// the Years / Months / All switcher. Only placeholders on screen: keep both as they were.
    private func screenCellsChanged(_ ids: [String]) {
        guard let range = model.gridRange(ofVisible: ids) else { return }
        scrollMetrics.visibleRange = range
        model.screenRangeChanged(range)
        guard let chrome else { return }
        let away = LibraryChrome.isAway(visible: range, itemCount: model.gridItemCount,
                                        columns: model.columnCount, newestFirst: model.newestFirst)
        if chrome.isAwayFromNewest != away { chrome.isAwayFromNewest = away }
    }

    /// Opens at the newest photos. `defaultScrollAnchor` alone left a real 13 000-photo library
    /// in May 2024 on an iPhone, so the grid also scrolls to its newest cell explicitly.
    private func openAtNewest(_ proxy: ScrollViewProxy) {
        let count = model.gridItemCount
        guard count > 0, let target = model.gridItemID(atGridIndex: model.newestFirst ? 0 : count - 1) else { return }
        proxy.scrollTo(target, anchor: model.newestFirst ? .top : .bottom)
        Task { @MainActor in
            // Again once the newest months have loaded (their cells replace placeholders).
            try? await Task.sleep(for: .milliseconds(400))
            guard scrollMetrics.geometry != nil, let last = model.gridItemID(
                atGridIndex: model.newestFirst ? 0 : model.gridItemCount - 1) else { return }
            if !scrollMetrics.userScrolled { proxy.scrollTo(last, anchor: model.newestFirst ? .top : .bottom) }
        }
    }

    /// The Library tab was tapped again: back to All and the newest photos, like Photos.
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        if scale != .all { withAnimation(.snappy(duration: 0.25)) { scale = .all } }
        guard let target = model.gridItemID(atGridIndex: model.newestFirst ? 0 : model.gridItemCount - 1) else { return }
        // On the next run loop turn, after iOS has started its own scroll to the top, so this
        // scroll replaces it.
        Task { @MainActor in
            await Task.yield()
            withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo(target, anchor: model.newestFirst ? .top : .bottom) }
        }
    }

    /// Months loaded with a slightly different number of items than their placeholders moved
    /// the photo in the middle of the screen to another cell: scroll so it stays where it was.
    private func keepInPlace(_ shift: LibraryGridModel.GridShift?, proxy: ScrollViewProxy) {
        guard let shift, let geometry = scrollMetrics.geometry, liveScale == 1, settleScale == 1 else { return }
        let columns = model.columnCount
        let width = geometry.containerSize.width
        let cell = GridPinchAnchor.cellSize(width: width, spacing: Self.spacing, columns: columns)
        // Where the photo was on screen, from the layout before the change.
        let itemTop = Double(shift.oldIndex / columns) * (cell + Self.spacing) - geometry.contentOffset.y
        guard itemTop > -cell, itemTop < geometry.visibleRect.height else { return }
        let y = GridPinchAnchor.unitAnchorY(itemTop: itemTop, itemHeight: cell, insetTop: geometry.contentInsets.top,
                                            visibleHeight: geometry.containerSize.height)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(shift.anchorID, anchor: UnitPoint(x: 0.5, y: y)) }
    }

    /// Opened from a month card: show that month at the top of the grid.
    private func scrollToPendingMonth(_ proxy: ScrollViewProxy) {
        if let assetID = model.pendingScrollAssetID {
            // Opened from a day in Months: centre that photo, like Photos.
            model.pendingScrollAssetID = nil
            proxy.scrollTo(assetID, anchor: .center)
            model.assetShownInViewer(assetID)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                proxy.scrollTo(assetID, anchor: .center)
            }
            return
        }
        guard let monthID = model.pendingScrollMonthID, let target = model.firstGridID(ofMonth: monthID) else { return }
        model.pendingScrollMonthID = nil
        // After this layout pass, so the freshly shown grid has its content size.
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(target, anchor: .top)
            model.monthAppeared(monthID)
        }
    }

    /// Follows the fingers like Photos: the grid scales live, and as soon as the pinch passes a
    /// step it switches columns around the asset in the middle of the screen. One pinch can step
    /// through several densities.
    private func pinchChanged(_ value: MagnifyGesture.Value, proxy: ScrollViewProxy) {
        guard !mutationBlocked else { return }
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
        guard !mutationBlocked else { return }
        guard let proxy = densityProxy else { model.density = density; return }
        switchDensity(to: density, proxy: proxy, fromVisualScale: 1)
    }

    /// Switches columns without animating the grid's layout (relayouting thousands of cells in an
    /// animation is what made everything reload). Instead the new layout is shown scaled to the
    /// size the old cells had on screen and springs to its real size: one continuous motion.
    private func switchDensity(to density: GridDensity, proxy: ScrollViewProxy, fromVisualScale visual: CGFloat) {
        guard density != model.density else { return }
        let ratio = CGFloat(density.rawValue) / CGFloat(model.density.rawValue)
        // The photo to keep in place: exact maths when the layout is measured, else the middle of
        // the cells actually on screen (within half a row).
        let exact = exactAnchor(for: density)
        if exact == nil { scrollMetrics.pendingOffset = nil }
        // Kept in the middle of the screen: the photo is checked against the cells on screen, but
        // its exact position on screen can't be (LazyVGrid's offsets are estimates after a jump).
        let target = exact ?? centreAnchor()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.density = density
            // Scrolled in the same transaction as the new column count: SwiftUI applies it after
            // the relayout, so the photo in the middle of the screen doesn't move.
            if let target { proxy.scrollTo(target.id, anchor: target.anchor) }
            liveScale = 1
            settleScale = reduceMotion ? 1 : visual * ratio * settleScale
        }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0)) { settleScale = 1 }
        if let target { confirmAnchor(target, proxy: proxy) }
    }

    /// The middle of the cells SwiftUI reports on screen.
    private func centreAnchor() -> PinchTarget? {
        guard let visible = scrollMetrics.visibleRange else {
            return model.visibleCenterID.flatMap { id in
                model.gridIndex(ofAsset: id).map { PinchTarget(id: id, anchor: .center, index: $0) }
            }
        }
        let index = GridPinchAnchor.centerIndex(of: visible, columns: model.columnCount, itemCount: model.gridItemCount)
        return model.gridItemID(atGridIndex: index).map { PinchTarget(id: $0, anchor: .center, index: index) }
    }

    /// `scrollTo` in the relayout lands on LazyVGrid's estimated row positions, which after a jump
    /// can be weeks away (measured on the simulator). Once the new layout has been built around
    /// where it landed, scroll to the photo again (now on measured rows, so it lands where it
    /// should), and keep trying a few times while it still isn't on screen.
    private func confirmAnchor(_ target: PinchTarget, proxy: ScrollViewProxy) {
        anchorCheck?.cancel()
        anchorCheck = Task { @MainActor in
            for attempt in 0..<4 {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                if attempt > 0, scrollMetrics.visibleRange?.contains(target.index) == true { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(target.id, anchor: target.anchor) }
            }
        }
    }

    /// The cell at the centre of the scroll view (the point the pinch scale is anchored on), from
    /// the offset maths. Only used when that cell is among the cells SwiftUI reports on screen:
    /// after a jump LazyVGrid's offsets are estimates and the maths points weeks away.
    private func exactAnchor(for density: GridDensity) -> PinchTarget? {
        guard let geometry = scrollMetrics.geometry else { return nil }
        // A fast pinch can switch again before the grid reports its new offset; then the offset
        // this view scrolled to last time is the current one (a stale offset jumped to 2021).
        let currentOffset = scrollMetrics.pendingOffset ?? geometry.contentOffset.y
        let width = geometry.containerSize.width
        guard let result = GridPinchAnchor.anchor(
            offset: currentOffset, focalX: width / 2, focalY: geometry.visibleRect.height / 2,
            width: width, spacing: Self.spacing, from: model.density.rawValue, to: density.rawValue,
            itemCount: model.gridItemCount
        ), GridPinchAnchor.isOnScreen(index: result.index, visible: scrollMetrics.visibleRange),
              let id = model.gridItemID(atGridIndex: result.index) else { return nil }
        scrollMetrics.pendingOffset = result.offset
        return PinchTarget(id: id, anchor: .center, index: result.index)
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

/// The photo a density switch keeps in place, and where.
private struct PinchTarget {
    let id: AnyHashable
    let anchor: UnitPoint
    let index: Int
}

private final class ScrollMetrics {
    var geometry: ScrollGeometry?
    /// Offset of the last density switch until the grid reports geometry for the new layout.
    var pendingOffset: Double?
    /// Grid indices of the loaded cells SwiftUI last reported on screen.
    var visibleRange: ClosedRange<Int>?
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

/// The cells of the grid, split out and `Equatable` so that state changes in the parent
/// (pinch scale on every gesture frame, the viewer's current photo) don't rebuild 10 000+
/// cells. It still updates by itself when the model's months load (Observation).
private struct GridCells: View, Equatable {
    let model: LibraryGridModel
    let selection: LibrarySelectionModel
    let columnCount: Int
    let spacing: CGFloat
    let fillsCells: Bool
    let transition: Namespace.ID
    let onTap: (Asset) -> Void

    static func == (lhs: GridCells, rhs: GridCells) -> Bool {
        lhs.model === rhs.model && lhs.selection === rhs.selection && lhs.columnCount == rhs.columnCount
            && lhs.spacing == rhs.spacing && lhs.fillsCells == rhs.fillsCells && lhs.transition == rhs.transition
    }

    var body: some View {
        // One continuous grid across months, like Photos (no section breaks).
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(1, columnCount)),
                  spacing: spacing) {
            ForEach(model.months) { month in
                cells(for: month)
            }
        }
        // Lets the scroll view report which cells are on screen (the header's date range).
        .scrollTargetLayout()
    }

    @ViewBuilder
    private func cells(for month: TimelineMonth) -> some View {
        if month.isLoaded {
            ForEach(month.assets) { asset in
                LibrarySelectableCell(asset: asset, model: model, selection: selection,
                                      fillsCell: fillsCells, onOpen: onTap)
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
            // IDs must be unique across the whole grid: plain 0..<count would repeat in every
            // unloaded month, which LazyVGrid can't lay out (it rendered black).
            ForEach(PlaceholderSlots(monthID: month.id, count: month.bucket.count)) { slot in
                PlaceholderCell()
                    .id(slot)
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
