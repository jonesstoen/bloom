import ImmichKit
import SwiftUI

/// Full-screen media pager. The caller can append lazily loaded months while it is open.
public struct AssetViewer: View {
    let assets: [Asset]
    let service: any ImmichService
    let loader: ImageLoader
    let onSelection: (String) -> Void
    @State private var selectedID: String
    @Environment(\.dismiss) private var dismiss

    public init(assets: [Asset], selectedID: String, service: any ImmichService,
                loader: ImageLoader? = nil, onSelection: @escaping (String) -> Void = { _ in }) {
        self.assets = assets
        self.service = service
        self.loader = loader ?? ImageLoader(service: service)
        self.onSelection = onSelection
        _selectedID = State(initialValue: selectedID)
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            #if os(iOS)
            TabView(selection: $selectedID) {
                ForEach(assets) { asset in
                    page(asset).tag(asset.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            #else
            VStack {
                if let asset = assets.first(where: { $0.id == selectedID }) { page(asset) }
                HStack {
                    Button("Previous", systemImage: "chevron.left") { step(-1) }
                        .disabled(assets.first?.id == selectedID)
                    Button("Next", systemImage: "chevron.right") { step(1) }
                        .disabled(assets.last?.id == selectedID)
                }.padding()
            }
            #endif
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(12).background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Close viewer")
            .padding()
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedID, initial: true) { _, id in onSelection(id) }
    }

    private func page(_ asset: Asset) -> some View {
        ViewerPage(asset: asset, service: service, loader: loader, isActive: selectedID == asset.id)
    }

    private func step(_ delta: Int) {
        guard let index = assets.firstIndex(where: { $0.id == selectedID }), assets.indices.contains(index + delta) else { return }
        selectedID = assets[index + delta].id
    }
}

private struct ViewerPage: View {
    @State private var model: ViewerAssetModel
    @State private var zoom = 1.0
    @State private var showsInfo = false
    @Environment(\.dismiss) private var dismiss
    let isActive: Bool

    init(asset: Asset, service: any ImmichService, loader: ImageLoader, isActive: Bool) {
        _model = State(initialValue: ViewerAssetModel(asset: asset, service: service, loader: loader))
        self.isActive = isActive
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    if model.asset.isVideo, let request = model.playback, isActive {
                        VideoPlaybackView(request: request)
                    } else if let image = model.image {
                        ScrollView([.horizontal, .vertical]) {
                            Image(decorative: image, scale: 1).resizable().scaledToFit()
                                .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                        }
                        .scrollDisabled(zoom == 1)
                        .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = zoom == 1 ? 2.5 : 1 } }
                        .accessibilityLabel(model.asset.isVideo ? "Video preview" : "Photo")
                        .accessibilityAction(named: zoom == 1 ? "Zoom in" : "Zoom out") { zoom = zoom == 1 ? 2.5 : 1 }
                    } else if model.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture().onEnded { value in
                    if ViewerGesture.shouldDismiss(x: value.translation.width, y: value.translation.height, zoom: zoom) {
                        dismiss()
                    }
                })
            }
            if let error = model.error {
                Text(error).font(.caption)
                Button("Try Again") { Task { await model.load() } }
            }
            HStack {
                Text(model.asset.localDateTime.formatted(Date.FormatStyle(calendar: Asset.localCalendar, timeZone: .gmt).day().month().year()))
                    .font(.subheadline)
                Spacer()
                Button { showsInfo = true } label: { Image(systemName: "info.circle").font(.title2) }
                    .accessibilityLabel("Photo information")
            }.padding()
        }
        .task(id: isActive) { if isActive && model.image == nil { await model.load() } }
        .onChange(of: isActive) { _, active in if !active { zoom = 1; showsInfo = false } }
        .sheet(isPresented: $showsInfo) {
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
    ViewerPage(asset: MockLibrary.standard.assets[0], service: mock, loader: ImageLoader(service: mock, disk: nil), isActive: true)
}
