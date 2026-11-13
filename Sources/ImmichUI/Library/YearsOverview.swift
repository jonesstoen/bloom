import ImmichKit
import SwiftUI

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
                    // The cover is the featured photo of one of the year's best months.
                    let coverMonth = model.coverMonthID(ofYear: year)
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

    static let monthStyle = Date.FormatStyle(locale: Localization.locale, calendar: Asset.localCalendar, timeZone: .gmt).month(.wide)
}

/// A rounded card with a cover photo and a title in its top-left corner.
private struct OverviewCard: View {
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 30
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
                    Text(title).font(.system(size: titleSize, weight: .bold))
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

#Preview("Years") {
    let mock = MockImmichService.preview
    let model = LibraryGridModel(service: mock, loader: ImageLoader(service: mock, disk: nil))
    return YearsOverview(model: model, topMargin: 0) { _, _ in }
        .task { await model.load() }
}
