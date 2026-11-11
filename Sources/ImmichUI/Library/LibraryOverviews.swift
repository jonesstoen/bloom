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

/// Months as large cards with a cover photo, like the Months view in Photos.
/// Tapping a month opens All scrolled to it.
struct MonthsOverview: View {
    let model: LibraryGridModel
    var scrollTarget: String?
    let topMargin: CGFloat
    let onSelect: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.months) { month in
                        Button { onSelect(month.id) } label: {
                            OverviewCard(
                                title: LibraryGridModel.monthTitle(for: month.bucket),
                                subtitle: "\(month.bucket.count.formatted()) items",
                                cover: model.coverAsset(ofMonth: month.id),
                                loader: model.loader,
                                height: 230,
                                titleFont: .title2.weight(.bold)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(month.id)
                        .task { await model.loadMonth(month.id) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 90)
            }
            .contentMargins(.top, topMargin, for: .scrollContent)
            .defaultScrollAnchor(model.newestFirst ? .top : .bottom, for: .initialOffset)
            .onAppear {
                if let scrollTarget { proxy.scrollTo(scrollTarget, anchor: .center) }
            }
        }
    }
}

/// Years as large cards, like the Years view in Photos. Tapping a year opens Months at that year.
struct YearsOverview: View {
    let model: LibraryGridModel
    let topMargin: CGFloat
    let onSelect: (LibraryGridModel.YearGroup) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(model.years) { year in
                    // The cover comes from the most recent month of the year.
                    let coverMonth = model.newestFirst ? year.monthIDs.first : year.monthIDs.last
                    Button { onSelect(year) } label: {
                        OverviewCard(
                            title: "\(year.year)",
                            subtitle: "\(year.count.formatted()) items",
                            cover: coverMonth.flatMap(model.coverAsset(ofMonth:)),
                            loader: model.loader,
                            height: 300,
                            titleFont: .system(size: 40, weight: .bold)
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
}

/// A rounded card with a cover photo and a title in its top-left corner.
private struct OverviewCard: View {
    let title: String
    let subtitle: String
    let cover: Asset?
    let loader: ImageLoader
    let height: CGFloat
    let titleFont: Font
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(titleFont)
                    Text(subtitle).font(.subheadline.weight(.semibold)).opacity(0.85)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 6)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(subtitle)")
            .accessibilityAddTraits(.isButton)
            .task(id: cover?.id) {
                guard let cover,
                      let data = try? await loader.data(for: ImageKey(assetID: cover.id, size: .preview)),
                      !Task.isCancelled else { return }
                let decoded = await ThumbnailDecoder.decode(data, maxPixelSize: 1000)
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { image = decoded } }
            }
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
    return YearsOverview(model: model, topMargin: 0) { _ in }
        .task { await model.load() }
}

#Preview("Scale switcher") {
    let _ = MockImmichService.preview
    LibraryScaleSwitcher(scale: .constant(.all)).padding().background(.gray)
}
