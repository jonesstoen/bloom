import ImmichKit
import SwiftUI

/// The Library's zoom levels, like the Years / Months / All switcher in Photos.
public enum LibraryScale: String, CaseIterable, Identifiable, Sendable {
    case years, months, all
    public var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .years: "Years"
        case .months: "Months"
        case .all: "All"
        }
    }
}

/// The floating glass switcher at the bottom of the Library.
struct LibraryScaleSwitcher: View {
    @Binding var scale: LibraryScale
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LibraryScale.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { scale = option }
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background {
                            if scale == option {
                                Capsule().fill(.primary.opacity(0.14))
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(scale == option ? .isSelected : [])
            }
        }
        .padding(4)
        .photosGlass(in: Capsule())
    }
}

/// Months like the Photos app: a title per month ("Oct 2026") above a mosaic of its days,
/// one rounded tile per day with the date in the corner, the first one large.
/// Tapping a day opens All centred on that photo.
struct MonthsOverview: View {
    let model: LibraryGridModel
    var scrollTarget: String?
    let topMargin: CGFloat
    let onSelect: (Asset) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - 2 * MonthMosaic.margin)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(model.months) { month in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(MonthsOverview.title(for: month.bucket))
                                    .font(.title2.weight(.bold))
                                    .accessibilityAddTraits(.isHeader)
                                MonthMosaic(tiles: model.dayTiles(ofMonth: month.id), isLoaded: month.isLoaded,
                                            width: width, loader: model.loader, onSelect: onSelect)
                            }
                            .padding(.horizontal, MonthMosaic.margin)
                            .id(month.id)
                            .task { await model.loadMonth(month.id) }
                        }
                    }
                    .padding(.bottom, 90)
                }
                .contentMargins(.top, topMargin, for: .scrollContent)
                .defaultScrollAnchor(model.newestFirst ? .top : .bottom, for: .initialOffset)
                .onAppear {
                    guard let scrollTarget else { return }
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(scrollTarget, anchor: .top)
                    }
                }
            }
        }
    }

    /// "Oct 2026", like the month titles in Photos.
    static func title(for bucket: TimeBucket, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: Asset.localCalendar, timeZone: .gmt)
        style = style.month(.abbreviated).year()
        return bucket.startDate.formatted(style)
    }
}

/// The day tiles of one month: 1 day fills the width, 2 or 3 share a row, and from 4 days the
/// first is a large square with two small ones beside it, then rows of three.
struct MonthMosaic: View {
    let tiles: [LibraryGridModel.DayTile]
    let isLoaded: Bool
    let width: CGFloat
    let loader: ImageLoader
    let onSelect: (Asset) -> Void

    static let margin: CGFloat = 12
    static let spacing: CGFloat = 5

    private var cell: CGFloat { max(0, (width - 2 * Self.spacing) / 3) }

    var body: some View {
        let s = Self.spacing
        VStack(alignment: .leading, spacing: s) {
            if !isLoaded {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary)
                    .frame(width: width, height: cell)
            } else {
                switch tiles.count {
                case 0:
                    EmptyView()
                case 1:
                    tile(tiles[0], width: width, height: width * 0.66, size: .preview)
                case 2:
                    HStack(spacing: s) {
                        ForEach(tiles) { tile($0, width: (width - s) / 2, height: (width - s) / 2, size: .preview) }
                    }
                case 3:
                    row(tiles[...])
                default:
                    HStack(alignment: .top, spacing: s) {
                        tile(tiles[0], width: 2 * cell + s, height: 2 * cell + s, size: .preview)
                        VStack(spacing: s) {
                            tile(tiles[1], width: cell, height: cell, size: .thumbnail)
                            tile(tiles[2], width: cell, height: cell, size: .thumbnail)
                        }
                    }
                    ForEach(Array(stride(from: 3, to: tiles.count, by: 3)), id: \.self) { start in
                        row(tiles[start..<min(start + 3, tiles.count)])
                    }
                }
            }
        }
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
        .accessibilityLabel("Day \(tile.day)")
    }
}

/// Years as large cards, like the Years view in Photos: the year and the month of its cover.
/// Tapping a year opens Months at the month of that photo.
struct YearsOverview: View {
    let model: LibraryGridModel
    let topMargin: CGFloat
    let onSelect: (LibraryGridModel.YearGroup, String?) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(model.years) { year in
                    // The cover comes from the most recent month of the year.
                    let coverMonth = model.newestFirst ? year.monthIDs.first : year.monthIDs.last
                    let cover = coverMonth.flatMap(model.coverAsset(ofMonth:))
                    Button { onSelect(year, coverMonth) } label: {
                        OverviewCard(
                            title: "\(year.year)",
                            subtitle: cover.map { $0.localDateTime.formatted(YearsOverview.monthStyle) },
                            cover: cover,
                            loader: model.loader,
                            height: 400
                        )
                    }
                    .buttonStyle(.plain)
                    .task { if let coverMonth { await model.loadMonth(coverMonth) } }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 90)
        }
        .contentMargins(.top, topMargin, for: .scrollContent)
        .defaultScrollAnchor(model.newestFirst ? .top : .bottom, for: .initialOffset)
    }

    static let monthStyle = Date.FormatStyle(calendar: Asset.localCalendar, timeZone: .gmt).month(.wide)
}

/// A photo filling its frame, loaded through the shared image loader.
private struct CoverImage: View {
    let asset: Asset?
    let loader: ImageLoader
    var size: ImageSize = .preview
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: asset?.id) {
                guard let asset,
                      let data = try? await loader.data(for: ImageKey(assetID: asset.id, size: size)),
                      !Task.isCancelled else { return }
                let decoded = await ThumbnailDecoder.decode(data, maxPixelSize: size == .preview ? 1000 : 400)
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { image = decoded } }
            }
    }
}

/// A rounded card with a cover photo and a title in its top-left corner.
private struct OverviewCard: View {
    let title: String
    let subtitle: String?
    let cover: Asset?
    let loader: ImageLoader
    let height: CGFloat

    var body: some View {
        CoverImage(asset: cover, loader: loader)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 30, weight: .bold))
                    if let subtitle { Text(subtitle).font(.headline).opacity(0.9) }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 6)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(.isButton)
    }
}

#Preview("Months") {
    let mock = MockImmichService.preview
    let model = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
    return MonthsOverview(model: model, topMargin: 0) { _ in }
        .task { await model.load() }
}

#Preview("Years") {
    let mock = MockImmichService.preview
    let model = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
    return YearsOverview(model: model, topMargin: 0) { _, _ in }
        .task { await model.load() }
}

#Preview("Scale switcher") {
    let _ = MockImmichService.preview
    LibraryScaleSwitcher(scale: .constant(.all)).padding().background(.gray)
}
