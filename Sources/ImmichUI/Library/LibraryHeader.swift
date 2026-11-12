import ImmichKit
import SwiftUI

/// Large title and subtitle over a soft blur, with glass buttons on the right, like Photos'
/// Library tab.
struct LibraryLargeHeader<Options: View>: View {
    let title: String
    let model: LibraryGridModel
    let selection: LibrarySelectionModel
    let scale: LibraryScale
    let mutationBlocked: Bool
    let accessory: AnyView?
    /// Tapping Select (switches to All first).
    let onSelect: () -> Void
    @ViewBuilder let options: () -> Options

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                // Its own view: the date range changes while scrolling, and reading it here
                // would re-render the header, menus and scroll view each time.
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
                    Button(tr("Select"), action: onSelect)
                        .font(.subheadline.weight(.semibold))
                        // "Marker" in Norwegian wrapped onto two lines in the narrow capsule.
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .photosGlass(in: Capsule())
                        .disabled(model.phase != .loaded || model.isEmpty || mutationBlocked)
                    options()
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
}

/// The grid options menu. In the Library tab it has Photos' sort, filter and view options;
/// elsewhere only the view options.
struct LibraryOptionsMenu: View {
    /// Shows sort and filter (the Library tab).
    let showsSortAndFilter: Bool
    @Binding var sortsByDateAdded: Bool
    @Binding var favoritesOnly: Bool
    @Binding var aspectRatioGrid: Bool
    @Binding var density: GridDensity

    var body: some View {
        Menu {
            if showsSortAndFilter {
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
                Picker(tr("Columns"), selection: $density) {
                    ForEach(GridDensity.allCases, id: \.rawValue) { density in
                        Text(tr("%lld Columns", Int64(density.rawValue))).tag(density)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(tr("View Options"), systemImage: "eye")
            }
        } label: {
            let filtered = showsSortAndFilter && favoritesOnly
            Label(tr("Grid options"), systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
    }
}

/// The Library header's subtitle: the dates on screen in All, the year range in Years.
struct LibraryHeaderSubtitle: View {
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
