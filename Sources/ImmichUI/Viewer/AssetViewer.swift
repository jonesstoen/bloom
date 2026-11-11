import ImmichKit
import SwiftUI

/// Full-screen media pager, laid out like viewing a photo in the iOS 26 Photos app:
/// a glass back button and a glass title capsule (place, weekday and time) at the top,
/// a thumbnail strip and a toolbar (share, favorite, info) at the bottom.
///
/// On iOS: swipe left and right between items (a lazy paging scroll view, so it handles
/// thousands of items), pinch or double-tap to zoom, tap to hide or show the bars, and swipe
/// down to close (the interactive dismissal of the zoom transition the grid presents it with).
/// Videos start playing when their page becomes current.
public struct AssetViewer: View {
    let assets: [Asset]
    let service: any ImmichService
    let loader: ImageLoader
    let onSelection: (String) -> Void
    private let initialID: String
    @State private var selectedID: String?
    @State private var chromeVisible = true
    @State private var showsInfo = false
    @State private var store: ViewerStore
    @Environment(\.dismiss) private var dismiss

    public init(assets: [Asset], selectedID: String, service: any ImmichService,
                loader: ImageLoader? = nil, onSelection: @escaping (String) -> Void = { _ in }) {
        let loader = loader ?? ImageLoader(service: service)
        self.assets = assets
        self.service = service
        self.loader = loader
        self.onSelection = onSelection
        self.initialID = selectedID
        _selectedID = State(initialValue: selectedID)
        _store = State(initialValue: ViewerStore(service: service, loader: loader))
    }

    private var currentID: String { selectedID ?? initialID }

    private var currentModel: ViewerAssetModel? {
        assets.first { $0.id == currentID }.map(store.model(for:))
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
        }
        .overlay(alignment: .top) {
            if chromeVisible { topBar.transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            if chromeVisible { bottomBar.transition(.opacity) }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(!chromeVisible)
        #endif
        .onChange(of: selectedID, initial: true) { _, id in
            showsInfo = false
            if let id { onSelection(id) }
        }
        .sheet(isPresented: $showsInfo) {
            if let model = currentModel {
                AssetInfoView(asset: model.asset)
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    #endif
            }
        }
    }

    // MARK: Pager

    @ViewBuilder
    private var pager: some View {
        #if os(iOS)
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(assets) { asset in
                        page(asset)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(asset.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedID)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .onAppear { proxy.scrollTo(initialID) }
        }
        #else
        VStack {
            if let asset = assets.first(where: { $0.id == currentID }) { page(asset) }
            HStack {
                Button("Previous", systemImage: "chevron.left") { step(-1) }
                    .disabled(assets.first?.id == currentID)
                Button("Next", systemImage: "chevron.right") { step(1) }
                    .disabled(assets.last?.id == currentID)
            }.padding()
        }
        #endif
    }

    private func page(_ asset: Asset) -> some View {
        ViewerPage(model: store.model(for: asset), isActive: currentID == asset.id) {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        }
    }

    private func step(_ delta: Int) {
        guard let index = assets.firstIndex(where: { $0.id == currentID }),
              assets.indices.contains(index + delta) else { return }
        selectedID = assets[index + delta].id
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .center) {
            GlassIconButton(systemImage: "chevron.left", label: "Close viewer") { dismiss() }
            Spacer(minLength: 8)
            if let model = currentModel {
                titleCapsule(model)
            }
            Spacer(minLength: 8)
            // Balances the back button so the title stays centred.
            Color.clear.frame(width: 48, height: 48)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func titleCapsule(_ model: ViewerAssetModel) -> some View {
        let date = model.asset.localDateTime
        let title = model.placeTitle ?? date.formatted(Self.dayStyle)
        let subtitle = model.placeTitle == nil
            ? date.formatted(Self.timeStyle)
            : "\(date.formatted(Self.weekdayStyle))  \(date.formatted(Self.timeStyle))"
        return VStack(spacing: 0) {
            Text(title).font(.headline).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 7)
        .photosGlass(in: Capsule(), interactive: false)
        .accessibilityElement(children: .combine)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 14) {
            #if os(iOS)
            ThumbnailStrip(assets: assets, selectedID: currentID, loader: loader) { id in
                selectedID = id
            }
            #endif
            HStack {
                if let model = currentModel {
                    ShareAssetButton(asset: model.asset, service: service)
                } else {
                    Color.clear.frame(width: 48, height: 48)
                }
                Spacer()
                if let model = currentModel {
                    HStack(spacing: 4) {
                        capsuleButton(model.asset.isFavorite ? "heart.fill" : "heart",
                                      label: model.asset.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                            Task { await model.toggleFavorite() }
                        }
                        .sensoryFeedback(.impact(weight: .light), trigger: model.asset.isFavorite)
                        capsuleButton("info.circle", label: "Photo information") { showsInfo = true }
                    }
                    .padding(.horizontal, 6)
                    .photosGlass(in: Capsule())
                }
                Spacer()
                Color.clear.frame(width: 48, height: 48)
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 6)
    }

    private func capsuleButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private static let dayStyle = Date.FormatStyle(calendar: Asset.localCalendar, timeZone: .gmt).day().month(.wide).year()
    private static let weekdayStyle = Date.FormatStyle(calendar: Asset.localCalendar, timeZone: .gmt).weekday(.wide)
    private static let timeStyle = Date.FormatStyle(calendar: Asset.localCalendar, timeZone: .gmt).hour().minute()
}

/// Keeps one `ViewerAssetModel` per asset while the viewer is open, so the bars can read the
/// current page's loaded details (place, favorite) and swiping back doesn't reload.
@MainActor @Observable
final class ViewerStore {
    @ObservationIgnored private var models: [String: ViewerAssetModel] = [:]
    @ObservationIgnored private let service: any ImmichService
    @ObservationIgnored private let loader: ImageLoader

    init(service: any ImmichService, loader: ImageLoader) {
        self.service = service
        self.loader = loader
    }

    func model(for asset: Asset) -> ViewerAssetModel {
        if let model = models[asset.id] { return model }
        let model = ViewerAssetModel(asset: asset, service: service, loader: loader)
        models[asset.id] = model
        return model
    }
}

/// One item in the pager. Loads its preview and full details when it is built, so the
/// neighbours the lazy pager builds ahead are ready before you swipe to them.
private struct ViewerPage: View {
    let model: ViewerAssetModel
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        ZStack {
            if model.asset.isVideo, let request = model.playback {
                VideoPlaybackView(request: request, isActive: isActive)
            } else if let image = model.image {
                #if os(iOS)
                ZoomableImage(image: image, isActive: isActive, onSingleTap: onTap)
                    .accessibilityLabel(model.asset.isVideo ? "Video preview" : "Photo")
                #else
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .onTapGesture(perform: onTap)
                #endif
            } else if let error = model.error {
                VStack(spacing: 12) {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await model.load() } }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { if !model.isLoaded { await model.load() } }
    }
}

#Preview("Viewer") {
    AssetViewer(assets: MockLibrary.standard.assets, selectedID: MockLibrary.standard.assets[0].id, service: MockImmichService.preview)
}

#Preview("Viewer page") {
    let mock = MockImmichService.preview
    ViewerPage(model: ViewerAssetModel(asset: MockLibrary.standard.assets[0], service: mock, loader: ImageLoader(service: mock, disk: nil)),
               isActive: true, onTap: {})
}
