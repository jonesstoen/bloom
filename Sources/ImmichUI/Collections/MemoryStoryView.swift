import ImmichKit
import SwiftUI

/// Manual tap-through memories. The year snapshot stays fixed until this presentation closes.
public struct MemoryStoryView: View {
    @State private var model: MemoryStoryModel
    @State private var openViewer: StoryViewerSelection?
    @State private var isVisible = false
    private let service: any ImmichService
    private let loader: ImageLoader
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(years: [MemoryStoryYear], startingYear: Int? = nil,
                service: any ImmichService, loader: ImageLoader? = nil) {
        _model = State(initialValue: MemoryStoryModel(years: years, startingYear: startingYear))
        self.service = service
        self.loader = loader ?? ImageLoader(service: service)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if model.isFinished {
                ending
            } else if let asset = model.currentAsset {
                StoryMedia(asset: asset, service: service, loader: loader,
                           isActive: isVisible && scenePhase == .active && openViewer == nil,
                           canGoPrevious: model.canGoPrevious,
                           previous: model.previous, next: model.next)
                    .id(asset.id)
                footer(asset: asset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        #if os(iOS)
        .fullScreenCover(item: $openViewer) { selection in
            AssetViewer(assets: selection.assets, selectedID: selection.selectedID,
                        service: service, loader: loader)
        }
        #else
        .sheet(item: $openViewer) { selection in
            AssetViewer(assets: selection.assets, selectedID: selection.selectedID,
                        service: service, loader: loader)
                .frame(minWidth: 700, minHeight: 500)
        }
        #endif
    }

    private var header: some View {
        VStack(spacing: 14) {
            if let year = model.currentYear {
                progress(count: year.assets.count)
            }
            HStack {
                Menu {
                    ForEach(model.years) { year in
                        Button { model.selectYear(year.year) } label: {
                            if year.year == model.currentYear?.year {
                                Label(String(year.year), systemImage: "checkmark")
                            } else {
                                Text(String(year.year))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(model.currentYear.map { String($0.year) } ?? tr("Memories"))
                            .font(.title2.weight(.bold))
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .photosGlass(in: Capsule())
                }
                .disabled(model.years.isEmpty)
                .accessibilityLabel(tr("Choose year"))
                .accessibilityValue(model.currentYear.map { String($0.year) } ?? tr("Memories"))
                Spacer(minLength: 8)
                GlassIconButton(systemImage: "xmark", label: tr("Close viewer")) { dismiss() }
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
    }

    private func progress(count: Int) -> some View {
        // A bounded moving window keeps long memory years legible and cheap to render.
        let start = min(max(0, model.assetIndex - 5), max(0, count - 12))
        let end = min(count, start + 12)
        return HStack(spacing: 4) {
            ForEach(start..<end, id: \.self) { index in
                Capsule()
                    .fill(index <= model.assetIndex ? Color.white : Color.white.opacity(0.3))
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private func footer(asset: Asset) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(asset.localDateTime.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Localization.locale,
                                     calendar: Asset.localCalendar, timeZone: .gmt)))
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Text(tr("%lld of %lld", Int64(model.assetIndex + 1), Int64(model.currentYear?.assets.count ?? 0)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: 12) { viewerButton; navigationButtons }
            } else {
                HStack(spacing: 12) {
                    previousButton
                    Spacer(minLength: 0)
                    viewerButton
                    Spacer(minLength: 0)
                    nextButton
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var viewerButton: some View {
        Button {
            guard let year = model.currentYear, let asset = model.currentAsset else { return }
            openViewer = StoryViewerSelection(assets: year.assets, selectedID: asset.id)
        } label: {
            Label(tr("Open in Photo Viewer"), systemImage: "photo")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .photosGlass(in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var navigationButtons: some View {
        HStack(spacing: 24) { previousButton; nextButton }
    }

    private var previousButton: some View {
        GlassIconButton(systemImage: "chevron.left", label: tr("Previous item"), action: model.previous)
            .disabled(!model.canGoPrevious)
            .opacity(model.canGoPrevious ? 1 : 0.4)
    }

    private var nextButton: some View {
        GlassIconButton(systemImage: "chevron.right", label: tr("Next item"), action: model.next)
    }

    private var ending: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles").font(.largeTitle).accessibilityHidden(true)
            Text(tr("End of memories")).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            if let first = model.years.first {
                Button { model.selectYear(first.year) } label: {
                    Label(tr("Play Again"), systemImage: "arrow.counterclockwise")
                        .padding(16).photosGlass(in: Capsule())
                }
                .buttonStyle(.plain)
                previousButton
            }
            Spacer(minLength: 0)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StoryViewerSelection: Identifiable {
    let id = UUID()
    let assets: [Asset]
    let selectedID: String
}

/// Only the current item owns a model/player; leaving this page cancels its loading task.
private struct StoryMedia: View {
    @State private var model: ViewerAssetModel
    let isActive: Bool
    let canGoPrevious: Bool
    let previous: () -> Void
    let next: () -> Void

    init(asset: Asset, service: any ImmichService, loader: ImageLoader, isActive: Bool,
         canGoPrevious: Bool, previous: @escaping () -> Void, next: @escaping () -> Void) {
        _model = State(initialValue: ViewerAssetModel(asset: asset, service: service, loader: loader))
        self.isActive = isActive
        self.canGoPrevious = canGoPrevious
        self.previous = previous
        self.next = next
    }

    var body: some View {
        ZStack {
            if model.asset.isVideo, let request = model.playback {
                VideoPlaybackView(request: request, isActive: isActive)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tr("Video preview"))
            } else if let image = model.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .accessibilityLabel(tr("Photo"))
            } else if model.error == nil {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            HStack(spacing: 0) {
                Button(action: previous) { Color.clear.contentShape(Rectangle()) }
                    .disabled(!canGoPrevious)
                Button(action: next) { Color.clear.contentShape(Rectangle()) }
            }
            .buttonStyle(.plain)
            // Explicit footer controls provide labels and predictable VoiceOver order.
            .accessibilityHidden(true)
        }
        .overlay {
            if let error = model.error {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center)
                    Button(tr("Try Again")) { reload += 1 }
                        .buttonStyle(.borderedProminent)
                }
                .padding(20)
                .photosGlass(in: RoundedRectangle(cornerRadius: 20), interactive: false)
                .padding(24)
            }
        }
        .clipped()
        .task(id: reload) { await model.load() }
    }

    @State private var reload = 0
}

#Preview("Memory story") {
    let mock = MockImmichService.preview
    MemoryStoryView(years: MemoryStoryModel.groupedYears(from: MockLibrary.standard.memories), service: mock)
}

#Preview("Empty memory story") {
    MemoryStoryView(years: [], service: MockImmichService.preview)
}

#Preview("Memory story large text") {
    MemoryStoryView(years: MemoryStoryModel.groupedYears(from: MockLibrary.standard.memories),
                    service: MockImmichService.preview)
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Story media") {
    let mock = MockImmichService.preview
    StoryMedia(asset: MockLibrary.standard.assets[0], service: mock, loader: ImageLoader(service: mock, disk: nil),
               isActive: false, canGoPrevious: false, previous: {}, next: {})
}
