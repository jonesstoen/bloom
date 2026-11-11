import ImmichKit
import SwiftUI

/// Full-screen media pager, like viewing a photo in Photos.
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
    @Environment(\.dismiss) private var dismiss

    public init(assets: [Asset], selectedID: String, service: any ImmichService,
                loader: ImageLoader? = nil, onSelection: @escaping (String) -> Void = { _ in }) {
        self.assets = assets
        self.service = service
        self.loader = loader ?? ImageLoader(service: service)
        self.onSelection = onSelection
        self.initialID = selectedID
        _selectedID = State(initialValue: selectedID)
    }

    private var currentAsset: Asset? {
        let id = selectedID ?? initialID
        return assets.first { $0.id == id }
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
            if let asset = currentAsset { page(asset) }
            HStack {
                Button("Previous", systemImage: "chevron.left") { step(-1) }
                    .disabled(assets.first?.id == currentAsset?.id)
                Button("Next", systemImage: "chevron.right") { step(1) }
                    .disabled(assets.last?.id == currentAsset?.id)
            }.padding()
        }
        #endif
    }

    private func page(_ asset: Asset) -> some View {
        ViewerPage(asset: asset, service: service, loader: loader,
                   isActive: (selectedID ?? initialID) == asset.id,
                   showsInfo: $showsInfo) {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        }
    }

    private func step(_ delta: Int) {
        guard let index = assets.firstIndex(where: { $0.id == (selectedID ?? initialID) }),
              assets.indices.contains(index + delta) else { return }
        selectedID = assets[index + delta].id
    }

    // MARK: Bars

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close viewer")
            Spacer()
            if let asset = currentAsset {
                VStack(spacing: 1) {
                    Text(asset.localDateTime.formatted(Self.dateStyle)).font(.headline)
                    Text(asset.localDateTime.formatted(Self.timeStyle)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
        .background {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    private var bottomBar: some View {
        HStack {
            if currentAsset?.isFavorite == true {
                Image(systemName: "heart.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Favorite")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
            Spacer()
            Button { showsInfo = true } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Photo information")
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private static let dateStyle = Date.FormatStyle(calendar: Asset.localCalendar, timeZone: .gmt).day().month(.wide).year()
    private static let timeStyle = Date.FormatStyle(calendar: Asset.localCalendar, timeZone: .gmt).hour().minute()
}

/// One item in the pager. Loads its preview and full details when it is built, so the
/// neighbours the lazy pager builds ahead are ready before you swipe to them.
private struct ViewerPage: View {
    @State private var model: ViewerAssetModel
    let isActive: Bool
    @Binding var showsInfo: Bool
    let onTap: () -> Void

    init(asset: Asset, service: any ImmichService, loader: ImageLoader, isActive: Bool,
         showsInfo: Binding<Bool>, onTap: @escaping () -> Void) {
        _model = State(initialValue: ViewerAssetModel(asset: asset, service: service, loader: loader))
        self.isActive = isActive
        _showsInfo = showsInfo
        self.onTap = onTap
    }

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
        .sheet(isPresented: Binding(get: { isActive && showsInfo }, set: { showsInfo = $0 })) {
            AssetInfoView(asset: model.asset)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
        }
    }
}

#Preview("Viewer") {
    AssetViewer(assets: MockLibrary.standard.assets, selectedID: MockLibrary.standard.assets[0].id, service: MockImmichService.preview)
}

#Preview("Viewer page") {
    let mock = MockImmichService.preview
    ViewerPage(asset: MockLibrary.standard.assets[0], service: mock, loader: ImageLoader(service: mock, disk: nil),
               isActive: true, showsInfo: .constant(false), onTap: {})
}
