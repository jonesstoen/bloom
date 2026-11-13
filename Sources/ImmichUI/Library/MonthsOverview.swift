import ImmichKit
import SwiftUI

/// Months like the Photos app: a title per month ("Oct 2026") above a mosaic of its days,
/// one rounded tile per day with the date in the corner, the first one large.
/// Tapping a day opens All centred on that photo.
///
/// Laid out exactly (`MonthsLayout`): only the months near the screen are built, and opening
/// at a month scrolls straight to its position once, with nothing to correct afterwards.
///
/// It stays alive while hidden (so switching levels can zoom between them) and jumps to
/// `scrollTarget` each time it becomes active.
struct MonthsOverview: View {
    let model: LibraryGridModel
    /// The month to open at (its title at the top); `nil` keeps the position.
    var scrollTarget: String?
    /// Months is the level on screen.
    var isActive = true
    let topMargin: CGFloat
    let onSelect: (Asset) -> Void
    @ScaledMetric(relativeTo: .title2) private var titleHeight: CGFloat = 30
    @State private var position = ScrollPosition()
    @State private var window = MonthsWindow()
    @State private var metrics = MonthsMetrics()

    var body: some View {
        if model.allMonthsLoaded {
            mosaic
        } else {
            // Every month is loaded before showing the mosaic, so no month changes height
            // while you look at it.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await model.loadAllMonths() }
        }
    }

    private var mosaic: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - 2 * MonthMosaic.margin)
            let layout = MonthsLayout(
                months: model.months.map { .init(id: $0.id, plan: model.monthPlan(ofMonth: $0.id), isLoaded: $0.isLoaded,
                                         title: Self.title(for: $0.bucket)) },
                width: width, titleHeight: titleHeight)
            ScrollView {
                MonthRows(layout: layout, window: window, width: width, titleHeight: titleHeight,
                          loader: model.loader, onSelect: onSelect)
                    .frame(width: geometry.size.width, height: layout.contentHeight, alignment: .topLeading)
            }
            .contentMargins(.top, topMargin, for: .scrollContent)
            .defaultScrollAnchor(model.newestFirst ? .top : .bottom, for: .initialOffset)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
                let first = metrics.geometry == nil
                metrics.geometry = geometry
                metrics.layout = layout
                let top = geometry.contentOffset.y
                if first && isActive {
                    open(layout, geometry: geometry)
                    return
                }
                window.update(layout.visible(top: top, bottom: top + geometry.visibleRect.height,
                                             margin: geometry.visibleRect.height))
            }
            .onChange(of: isActive) { _, active in
                if active, let layout = metrics.layout, let geometry = metrics.geometry {
                    open(layout, geometry: geometry)
                }
            }
        }
    }

    /// Jumps to the target month in one exact scroll (or keeps the position).
    private func open(_ layout: MonthsLayout, geometry: ScrollGeometry) {
        let frame = geometry.visibleRect.height
        var top = geometry.contentOffset.y
        if let scrollTarget, let index = layout.index(of: scrollTarget) {
            // `scrollTo(y:)` measures from below the top margin (as in the All grid); the scroll
            // view clamps at the end of the content.
            let y = layout.offsets[index]
            top = min(y - geometry.contentInsets.top,
                      geometry.contentSize.height + geometry.contentInsets.bottom - frame)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(y: y) }
        }
        window.update(layout.visible(top: top, bottom: top + frame, margin: frame))
    }

    /// "Oct 2026", like the month titles in Photos.
    static func title(for bucket: TimeBucket, locale: Locale = Localization.locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: Asset.localCalendar, timeZone: .gmt)
        style = style.month(.abbreviated).year()
        return bucket.startDate.formatted(style)
    }
}

/// The last layout and scroll geometry, for jumping when Months becomes active. Not observed:
/// it changes on every scroll frame.
private final class MonthsMetrics {
    var geometry: ScrollGeometry?
    var layout: MonthsLayout?
}

/// The months currently built. Observed only by `MonthRows`, so scrolling doesn't re-render
/// `MonthsOverview` (and recompute the layout).
@MainActor
@Observable

private final class MonthsWindow {
    private(set) var range: Range<Int> = 0..<0

    func update(_ new: Range<Int>) {
        if new != range { range = new }
    }
}

/// The months in `window`, each placed at its exact offset.
private struct MonthRows: View {
    let layout: MonthsLayout
    let window: MonthsWindow
    let width: CGFloat
    let titleHeight: CGFloat
    let loader: ImageLoader
    let onSelect: (Asset) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(window.range.clamped(to: layout.months.indices), id: \.self) { index in
                let month = layout.months[index]
                VStack(alignment: .leading, spacing: MonthsLayout.titleSpacing) {
                    Text(month.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .frame(height: titleHeight, alignment: .bottomLeading)
                        .accessibilityAddTraits(.isHeader)
                    MonthMosaic(plan: month.plan, isLoaded: month.isLoaded, width: width, loader: loader, onSelect: onSelect)
                }
                .frame(height: layout.heights[index], alignment: .topLeading)
                .padding(.horizontal, MonthMosaic.margin)
                .offset(y: layout.offsets[index])
                .id(month.id)
            }
        }
    }
}

/// One month's highlights: a row of up to three days, a wide featured day above a row of
/// three, or a large featured square with two small days beside it (left or right) above a
/// row of three, like the Months view in Photos.
struct MonthMosaic: View {
    let plan: MonthHighlights.Plan
    let isLoaded: Bool
    let width: CGFloat
    let loader: ImageLoader
    let onSelect: (Asset) -> Void

    static let margin: CGFloat = 12
    static let spacing: CGFloat = 5

    private var cell: CGFloat { max(0, (width - 2 * Self.spacing) / 3) }
    private var big: CGFloat { 2 * cell + Self.spacing }

    /// The mosaic's exact height, matching `body` (which is framed to it), so `MonthsLayout`
    /// knows where every month is without building it.
    static func height(plan: MonthHighlights.Plan, isLoaded: Bool, width: CGFloat) -> CGFloat {
        let s = spacing
        let cell = max(0, (width - 2 * s) / 3)
        guard isLoaded else { return cell }
        let count = plan.tiles.count
        switch plan.layout {
        case .row:
            switch count {
            case 0: return 0
            case 1: return width * 0.66
            case 2: return (width - s) / 2
            default: return cell
            }
        case .wideTop:
            return width * 0.66 + (count > 1 ? s + cell : 0)
        case .feature:
            return 2 * cell + s + (count > 3 ? s + cell : 0)
        }
    }

    var body: some View {
        let s = Self.spacing
        let tiles = plan.tiles
        VStack(alignment: .leading, spacing: s) {
            if !isLoaded {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary)
                    .frame(width: width, height: cell)
            } else {
                switch plan.layout {
                case .row:
                    switch tiles.count {
                    case 0: EmptyView()
                    case 1: tile(tiles[0], width: width, height: width * 0.66, size: .preview)
                    case 2:
                        HStack(spacing: s) {
                            ForEach(tiles) { tile($0, width: (width - s) / 2, height: (width - s) / 2, size: .preview) }
                        }
                    default: row(tiles[...])
                    }
                case .wideTop:
                    tile(tiles[0], width: width, height: width * 0.66, size: .preview)
                    if tiles.count > 1 { row(tiles.dropFirst().prefix(3)) }
                case .feature(let featuredOnLeft):
                    HStack(alignment: .top, spacing: s) {
                        if featuredOnLeft { tile(tiles[0], width: big, height: big, size: .preview) }
                        VStack(spacing: s) {
                            ForEach(tiles.dropFirst().prefix(2)) { tile($0, width: cell, height: cell, size: .thumbnail) }
                        }
                        if !featuredOnLeft { tile(tiles[0], width: big, height: big, size: .preview) }
                    }
                    if tiles.count > 3 { row(tiles.dropFirst(3).prefix(3)) }
                }
            }
        }
        .frame(width: width, height: Self.height(plan: plan, isLoaded: isLoaded, width: width), alignment: .topLeading)
    }

    private func row(_ slice: ArraySlice<LibraryGridModel.DayTile>) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(slice) { tile($0, width: cell, height: cell, size: .thumbnail) }
        }
    }

    private func tile(_ tile: LibraryGridModel.DayTile, width: CGFloat, height: CGFloat, size: ImageSize) -> some View {
        Button { onSelect(tile.cover) } label: {
            CoverImage(asset: tile.cover, loader: loader, size: size)
                .frame(width: width, height: height)
                .overlay(alignment: .topLeading) {
                    Text("\(tile.day).")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityLabel(for: tile.cover))
    }

    /// "8 October 2026": the tile's date, so a day reads on its own.
    static func accessibilityLabel(for cover: Asset, locale: Locale = Localization.locale) -> String {
        cover.localDateTime.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale,
                                                       calendar: Asset.localCalendar, timeZone: .gmt))
    }
}

#Preview("Months") {
    let mock = MockImmichService.preview
    let model = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
    return MonthsOverview(model: model, topMargin: 0) { _ in }
        .task { await model.load() }
}
