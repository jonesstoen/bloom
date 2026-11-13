import ImmichKit
import SwiftUI

/// Capture the whole sequence at opening so refreshes cannot change story positions.
struct MemoryStorySelection: Identifiable {
    let id = UUID()
    let years: [MemoryStoryYear]
    let startingYear: Int
}

/// A tall memory card with its cover photo, title and year, like Photos' Memories row.
struct MemoryCard: View {
    let year: MemoryStoryYear
    let loader: ImageLoader
    /// Fixed 300 × 380 in the Collections row; `nil` fills the width (Memories list) at that ratio.
    var width: CGFloat? = 300
    var animatesPreview = false
    @State private var preview = MemoryCardPreviewModel()
    @State private var isVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct PreviewTaskID: Equatable {
        let assetIDs: [String]
        let canAnimate: Bool
    }

    private var candidateIDs: [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for asset in year.assets where seen.insert(asset.id).inserted {
            ids.append(asset.id)
            if ids.count == 6 { break }
        }
        return ids
    }

    private var canAnimate: Bool {
        animatesPreview && isVisible && scenePhase == .active && !reduceMotion
    }

    var body: some View {
        Rectangle().fill(.quaternary)
            .aspectRatio(300.0 / 380.0, contentMode: .fit)
            .frame(width: width)
            .overlay {
                ZStack {
                    if let image = preview.image {
                        MemoryCoverMotion(image: image, isActive: canAnimate && preview.canAdvance,
                                          zoomsIn: preview.revision.isMultiple(of: 2))
                            .id(preview.assetID)
                            .transition(.opacity)
                    }
                }
                .animation(canAnimate ? .easeInOut(duration: 0.7) : nil, value: preview.revision)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(year.year)).font(.title2.weight(.bold))
                    Text(tr("%lld items", Int64(year.assets.count)))
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("%@, %lld items", String(year.year), Int64(year.assets.count)))
            .onScrollVisibilityChange { isVisible = $0 }
            .onDisappear { isVisible = false }
            .task(id: PreviewTaskID(assetIDs: candidateIDs, canAnimate: canAnimate)) {
                await preview.prepare(assetIDs: candidateIDs, loader: loader)
                guard canAnimate, preview.canAdvance else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    await preview.advance(loader: loader)
                }
            }
    }
}

/// All memories, like Photos' Memories screen: one large card per year, newest first. Tapping a
/// card plays that year's story.
struct MemoriesView: View {
    let years: [MemoryStoryYear]
    let service: any ImmichService
    let loader: ImageLoader
    @State private var openYear: MemoryStorySelection?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(years) { year in
                    Button { openYear = MemoryStorySelection(years: years, startingYear: year.year) } label: {
                        MemoryCard(year: year, loader: loader, width: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .overlay {
            if years.isEmpty {
                ContentUnavailableView(tr("No Memories"), systemImage: "sparkles.rectangle.stack",
                                       description: Text(tr("Photos from this day in earlier years appear here.")))
            }
        }
        .navigationTitle(tr("Memories"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(item: $openYear) { selection in
            MemoryStoryView(years: selection.years, startingYear: selection.startingYear, service: service, loader: loader)
        }
        #else
        .sheet(item: $openYear) { selection in
            MemoryStoryView(years: selection.years, startingYear: selection.startingYear, service: service, loader: loader)
                .frame(minWidth: 700, minHeight: 500)
        }
        #endif
    }
}

#Preview("Memories") {
    let mock = MockImmichService.preview
    NavigationStack {
        MemoriesView(years: MemoryStoryModel.groupedYears(from: MockLibrary.standard.memories),
                     service: mock, loader: ImageLoader(service: mock, disk: nil))
    }
}
