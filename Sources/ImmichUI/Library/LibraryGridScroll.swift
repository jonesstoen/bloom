import ImmichKit
import OSLog
import SwiftUI

// TEMPORARY pinch diagnostics (positions and column counts only). Remove once the jump is found.
private let pinchLog = Logger(subsystem: "Bloom", category: "pinch")

/// Asks the grid to switch columns (from the options menu). A new `id` makes a repeated choice
/// a new request.
struct DensityRequest: Equatable {
    let density: GridDensity
    let id = UUID()
}

/// The Library grid's scroll view: builds only the rows near the screen, does every programmatic
/// scroll (open at newest, jumps from Months, staying in place while months load, following the
/// viewer) and the pinch between column counts.
///
/// All positions come from `GridLayout`, which is exact for uniform square cells, so a scroll to
/// a y lands on the cell it was computed for. See HANDOFF's grid pitfalls for the measurements
/// behind `ScrollGeometry` and `ScrollPosition.scrollTo(y:)`.
struct LibraryGridScroll: View {
    let model: LibraryGridModel
    let selection: LibrarySelectionModel
    let chrome: LibraryChrome?
    /// The Library tab's grid: content runs under a 96 pt large title.
    let usesLargeTitle: Bool
    let fillsCells: Bool
    let mutationBlocked: Bool
    /// The photo the viewer shows: its cell is kept on screen behind the viewer.
    let viewerScrollTarget: String?
    /// Changes when the Library tab is tapped again: scroll to the newest photos.
    let scrollToNewestTrigger: Int
    let densityRequest: DensityRequest?
    let transition: Namespace.ID
    let onTap: (Asset) -> Void

    static let spacing: CGFloat = 1.5

    /// Where the scroll view is; every programmatic scroll sets an exact y.
    @State private var scrollPosition: ScrollPosition
    /// The rows of cells currently built (only those near the screen).
    @State private var gridWindow = GridWindow()
    /// Latest scroll geometry, kept outside observation so scrolling doesn't re-render the view.
    @State private var scrollMetrics = ScrollMetrics()
    /// The pinch's visual scale, read only by `PinchScaleEffect` so a pinch frame doesn't
    /// re-render the view.
    @State private var pinch = PinchScale()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: LibraryGridModel, selection: LibrarySelectionModel, chrome: LibraryChrome?, usesLargeTitle: Bool,
         fillsCells: Bool, mutationBlocked: Bool, viewerScrollTarget: String?, scrollToNewestTrigger: Int,
         densityRequest: DensityRequest?, transition: Namespace.ID, onTap: @escaping (Asset) -> Void) {
        self.model = model
        self.selection = selection
        self.chrome = chrome
        self.usesLargeTitle = usesLargeTitle
        self.fillsCells = fillsCells
        self.mutationBlocked = mutationBlocked
        self.viewerScrollTarget = viewerScrollTarget
        self.scrollToNewestTrigger = scrollToNewestTrigger
        self.densityRequest = densityRequest
        self.transition = transition
        self.onTap = onTap
        _scrollPosition = State(initialValue: ScrollPosition(edge: model.newestFirst ? .top : .bottom))
    }

    var body: some View {
        GeometryReader { container in
            let layout = gridLayout(width: container.size.width)
            ScrollView {
                VStack(spacing: 0) {
                    GridCells(model: model, selection: selection, window: gridWindow, layout: layout,
                              fillsCells: fillsCells, transition: transition, onTap: onTap)
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
            .onScrollPhaseChange { old, phase in
                if scrollMetrics.logging {
                    pinchLog.notice("phase \(String(describing: old), privacy: .public) -> \(String(describing: phase), privacy: .public) pinching=\(scrollMetrics.isPinching)")
                }
                guard phase == .interacting, !scrollMetrics.isPinching else { return }
                scrollMetrics.userScrolled = true
                // The finger takes over: what the scroll view reports is where it is.
                scrollMetrics.pendingOffset = nil
            }
            .refreshable {
                guard !mutationBlocked else { return }
                await model.load()
            }
            #if os(iOS)
            // Not clipped: the grid continues behind the tab bar and the Years/Months/All switcher,
            // like Photos (clipping cut it off above the tab bar).
            .modifier(PinchScaleEffect(pinch: pinch))
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
            .onDisappear {
                scrollMetrics.geometry = nil
                scrollMetrics.pendingOffset = nil
            }
            .onChange(of: model.pendingScrollMonthID) { _, _ in scrollToPendingMonth() }
            .onChange(of: model.pendingScrollAssetID) { _, _ in scrollToPendingMonth() }
            .onChange(of: model.gridShift) { _, shift in keepInPlace(shift) }
            .onChange(of: scrollToNewestTrigger) { _, _ in scrollToNewest() }
            .onChange(of: densityRequest) { _, request in
                if let request, !mutationBlocked { switchDensity(to: request.density, fromVisualScale: 1) }
            }
        }
        .ignoresSafeArea(edges: usesLargeTitle ? .top : [])
    }

    private var footer: some View {
        Text(model.footerText)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private func gridLayout(width: Double, columns: Int? = nil) -> GridLayout {
        GridLayout(width: width, spacing: Self.spacing, columns: columns ?? model.columnCount,
                   itemCount: model.gridItemCount)
    }

    // MARK: Following the scroll

    /// Every scroll frame: which rows to build, which cells are on screen, and the first open.
    private func scrollGeometryChanged(_ geometry: ScrollGeometry) {
        let firstLayout = scrollMetrics.geometry == nil
        scrollMetrics.geometry = geometry
        let pendingBefore = scrollMetrics.pendingOffset
        let offset = scrollMetrics.resolve(geometry)
        if scrollMetrics.logging {
            pinchLog.notice("geom cols=\(model.columnCount) contentH=\(Int(geometry.contentSize.height)) reported=\(Int(geometry.contentOffset.y)) pending=\(pendingBefore.map { Int($0) } ?? -1) used=\(Int(offset)) items=\(model.gridItemCount)")
        }
        let layout = gridLayout(width: geometry.containerSize.width)
        buildRows(layout, contentOffset: offset, frameHeight: geometry.visibleRect.height)
        reportScreen(layout, geometry: geometry, offset: offset)
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
    private func reportScreen(_ layout: GridLayout, geometry: ScrollGeometry, offset: Double) {
        guard let range = layout.screenRange(top: offset + geometry.contentInsets.top,
                                             height: geometry.containerSize.height) else { return }
        model.screenRangeChanged(range)
        guard let chrome else { return }
        let away = LibraryChrome.isAway(visible: range, itemCount: model.gridItemCount,
                                        columns: model.columnCount, newestFirst: model.newestFirst)
        if chrome.isAwayFromNewest != away { chrome.isAwayFromNewest = away }
    }

    // MARK: Programmatic scrolling

    /// Scrolls so cell `index` sits at `anchor` of the visible area (0 top, 0.5 middle, 1 bottom).
    /// The rows there are built first, so they are on screen when the scroll lands.
    private func scroll(toCell index: Int, anchor: Double, animation: Animation? = nil) {
        guard let geometry = scrollMetrics.geometry else { return }
        let layout = gridLayout(width: geometry.containerSize.width)
        let y = layout.scrollY(toShow: index, anchor: anchor, visibleHeight: geometry.containerSize.height)
        scroll(toY: y, layout: layout, geometry: geometry, animation: animation)
    }

    private func scroll(toY y: Double, layout: GridLayout, geometry: ScrollGeometry, animation: Animation? = nil) {
        if let animation {
            scrollMetrics.pendingOffset = nil
            withAnimation(animation) { scrollPosition.scrollTo(y: y) }
        } else {
            // `scrollTo(y:)` measures from below the top inset; the scroll view reports
            // `contentOffset`, which is y − insetTop once it lands.
            scrollMetrics.setPending(y - geometry.contentInsets.top)
            buildRows(layout, contentOffset: y - geometry.contentInsets.top, frameHeight: geometry.visibleRect.height)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollPosition.scrollTo(y: y) }
        }
    }

    private var newestCell: (index: Int, anchor: Double)? {
        let count = model.gridItemCount
        guard count > 0 else { return nil }
        return model.newestFirst ? (0, 0) : (count - 1, 1)
    }

    /// Opens at the newest photos, and again once their months have loaded (real counts can differ
    /// from the server's bucket counts), unless the user has started scrolling.
    private func openAtNewest() {
        guard let newest = newestCell else { return }
        scroll(toCell: newest.index, anchor: newest.anchor)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard scrollMetrics.geometry != nil, !scrollMetrics.userScrolled, let newest = newestCell else { return }
            scroll(toCell: newest.index, anchor: newest.anchor)
        }
    }

    /// The Library tab was tapped again: back to the newest photos, like Photos.
    private func scrollToNewest() {
        guard let newest = newestCell else { return }
        // On the next run loop turn, after iOS has started its own scroll to the top, so this
        // scroll replaces it.
        Task { @MainActor in
            await Task.yield()
            scroll(toCell: newest.index, anchor: newest.anchor, animation: .smooth(duration: 0.45))
        }
    }

    /// Months loaded with a slightly different number of items than their placeholders moved
    /// the photo in the middle of the screen to another cell: scroll so it stays where it was.
    private func keepInPlace(_ shift: LibraryGridModel.GridShift?) {
        guard let shift, let geometry = scrollMetrics.geometry, pinch.liveScale == 1, pinch.settleScale == 1 else { return }
        let layout = gridLayout(width: geometry.containerSize.width)
        // Where the photo was on screen, from the layout before the change.
        let screenY = Double(layout.origin(of: shift.oldIndex).y) - scrollMetrics.offset(geometry)
        guard screenY > -layout.cell, screenY < geometry.visibleRect.height else { return }
        let offset = Double(layout.origin(of: shift.newIndex).y) - screenY
        if scrollMetrics.logging {
            pinchLog.notice("keepInPlace old=\(shift.oldIndex) new=\(shift.newIndex) to=\(Int(offset))")
        }
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

    // MARK: Pinch

    /// Follows the fingers like Photos: the grid scales live, and as soon as the pinch passes a
    /// step it switches columns around the asset in the middle of the screen. One pinch can step
    /// through several densities.
    private func pinchChanged(_ value: MagnifyGesture.Value) {
        guard !mutationBlocked else { return }
        if !scrollMetrics.isPinching { pinchLog.notice("pinch start cols=\(model.columnCount)") }
        scrollMetrics.isPinching = true
        scrollMetrics.logUntil = Date().addingTimeInterval(2)
        let relative = value.magnification / pinch.baseline
        let next = model.density.pinched(by: relative)
        if next != model.density {
            pinch.baseline = value.magnification
            switchDensity(to: next, fromVisualScale: pinch.liveScale)
        } else {
            // Rubber-band at the ends (3 or 7 columns): the grid only gives a little.
            let atLimit = (relative > 1 && model.density == .three) || (relative < 1 && model.density == .seven)
            let resistance: CGFloat = atLimit ? 0.15 : 0.6
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { pinch.liveScale = 1 + (relative - 1) * resistance }
        }
    }

    private func pinchEnded() {
        scrollMetrics.isPinching = false
        scrollMetrics.logUntil = Date().addingTimeInterval(2)
        pinchLog.notice("pinch end cols=\(model.columnCount)")
        pinch.baseline = 1
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { pinch.liveScale = 1 }
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
        // A fast pinch can switch again before the last switch's scroll has landed; then its
        // target is the current offset (see `PendingScroll`).
        let currentOffset = scrollMetrics.offset(geometry)
        let anchor = GridPinchAnchor.anchor(
            offset: currentOffset, focalX: width / 2, focalY: geometry.visibleRect.height / 2,
            width: width, spacing: Self.spacing, from: model.density.rawValue, to: density.rawValue,
            itemCount: model.gridItemCount)
        let newLayout = gridLayout(width: width, columns: density.rawValue)
        pinchLog.notice("switch \(model.columnCount)->\(density.rawValue) reported=\(Int(geometry.contentOffset.y)) pending=\(scrollMetrics.pendingOffset.map { Int($0) } ?? -1) used=\(Int(currentOffset)) anchorIndex=\(anchor?.index ?? -1) of \(model.gridItemCount) to=\(anchor.map { Int($0.offset) } ?? -1)")
        withTransaction(transaction) {
            model.density = density
            if let anchor {
                scroll(toY: anchor.offset + geometry.contentInsets.top, layout: newLayout, geometry: geometry)
            }
            pinch.liveScale = 1
            pinch.settleScale = reduceMotion ? 1 : visual * ratio * pinch.settleScale
        }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0)) { pinch.settleScale = 1 }
    }
}

/// The rows of the grid that have cells built. Observed only by `GridCells`, so moving the window
/// while scrolling doesn't re-render the views around it.
@MainActor
@Observable
private final class GridWindow {
    var rows: Range<Int> = 0..<0
}

/// The pinch's visual scale. Changes on every gesture frame, so only `PinchScaleEffect` reads it.
@MainActor
@Observable
private final class PinchScale {
    /// Follows the fingers while pinching (never animated), relative to the last density switch.
    var liveScale: CGFloat = 1
    /// Bridges a density switch: the new layout starts at the old cell size and springs to 1.
    var settleScale: CGFloat = 1
    /// Magnification at which the current density was reached during this pinch.
    @ObservationIgnored var baseline: CGFloat = 1
}

/// Scales the grid with the pinch. Its own view, so each gesture frame updates only this.
private struct PinchScaleEffect: ViewModifier {
    let pinch: PinchScale

    func body(content: Content) -> some View {
        content.scaleEffect(pinch.liveScale * pinch.settleScale, anchor: .center)
    }
}

private final class ScrollMetrics {
    var geometry: ScrollGeometry?
    /// The `contentOffset.y` a programmatic scroll aims at, until the scroll view reports it.
    var pendingOffset: Double?
    /// Reports since `pendingOffset` was set that didn't match it.
    private var staleReports = 0
    /// A pinch is in progress (its fingers can make the scroll view report interaction).
    var isPinching = false
    /// TEMPORARY: log scroll reports until this time (around pinches).
    var logUntil = Date.distantPast
    var logging: Bool { isPinching || Date() < logUntil }
    /// The grid has been opened at the newest photos once.
    var didOpen = false
    /// The user has touched the grid (then it is never scrolled for them on open).
    var userScrolled = false

    func setPending(_ offset: Double) {
        pendingOffset = offset
        staleReports = 0
    }

    /// The offset the grid is really at for a new report: the pending target while the report
    /// still has the old layout's offset. Two such reports in a row mean the scroll isn't going
    /// to land (something else moved it), and the report wins.
    func resolve(_ geometry: ScrollGeometry) -> Double {
        let resolution = resolution(geometry)
        if resolution.pending == nil || staleReports >= 2 {
            pendingOffset = nil
            return geometry.contentOffset.y
        }
        staleReports += 1
        return resolution.offset
    }

    /// The current offset without consuming a report.
    func offset(_ geometry: ScrollGeometry) -> Double {
        resolution(geometry).offset
    }

    private func resolution(_ geometry: ScrollGeometry) -> PendingScroll.Resolution {
        PendingScroll.resolve(pending: pendingOffset, reportedOffset: geometry.contentOffset.y,
                              contentHeight: geometry.contentSize.height, frameHeight: geometry.visibleRect.height,
                              insetTop: geometry.contentInsets.top, insetBottom: geometry.contentInsets.bottom)
    }
}

/// The cells of the grid: only the rows in `window`, each placed at its exact position in a frame
/// as tall as the whole grid (see `GridLayout`). Split out and `Equatable` so that state changes
/// around it (pinch scale on every gesture frame, the viewer's current photo) don't rebuild it;
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
