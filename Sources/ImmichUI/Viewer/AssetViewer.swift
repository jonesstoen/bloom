import ImmichKit
import SwiftUI

/// Full-screen media pager, laid out like viewing a photo in the iOS 26 Photos app:
/// a glass back button and a glass title capsule (place, day and time) at the top,
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
    /// Position of each asset, built once: the bars look up the current item on every swipe.
    private let indexByID: [String: Int]
    @State private var selectedID: String?
    @State private var chromeVisible = true
    @State private var showsInfo = false
    @State private var shareActive = false
    @State private var showsAccessibleMenu = false
    @State private var trashConfirmationSubmitted = false
    @State private var trash: ViewerTrashModel
    private let allowsTrash: Bool
    private let allowsRestore: Bool
    @State private var store: ViewerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(assets: [Asset], selectedID: String, service: any ImmichService,
                loader: ImageLoader? = nil,
                onMoveToTrash: (@MainActor (Asset) async throws -> Void)? = nil,
                onRestore: (@MainActor (Asset) async throws -> Void)? = nil, onSelection: @escaping (String) -> Void = { _ in }) {
        let loader = loader ?? ImageLoader(service: service)
        self.assets = assets
        self.service = service
        self.loader = loader
        self.onSelection = onSelection
        self.allowsTrash = onMoveToTrash != nil
        self.allowsRestore = onRestore != nil
        _trash = State(initialValue: ViewerTrashModel(mode: onRestore != nil ? .restore : .trash, action: onRestore ?? onMoveToTrash))
        self.initialID = selectedID
        self.indexByID = Dictionary(assets.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        _selectedID = State(initialValue: selectedID)
        _store = State(initialValue: ViewerStore(service: service, loader: loader))
    }

    private var trashInteractionBlocked: Bool { trash.pendingAsset != nil || trash.isBusy }

    private var currentID: String { selectedID ?? initialID }

    private var currentIndex: Int? { indexByID[currentID] }

    private var currentModel: ViewerAssetModel? {
        currentIndex.map { store.model(for: assets[$0]) }
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager.disabled(trashInteractionBlocked)
        }
        .overlay(alignment: .top) {
            if chromeVisible { topBar.transition(.opacity).disabled(trashInteractionBlocked) }
        }
        .overlay(alignment: .bottom) {
            if chromeVisible { bottomBar.transition(.opacity).disabled(trashInteractionBlocked) }
        }
        .overlay {
            if trash.isBusy {
                ProgressView(allowsRestore ? tr("Restoring…") : tr("Moving to Trash…"))
                    .padding(24)
                    .photosGlass(in: RoundedRectangle(cornerRadius: 20), interactive: false)
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(!chromeVisible)
        .interactiveDismissDisabled(trashInteractionBlocked)
        #endif
        .onChange(of: selectedID, initial: true) { _, id in
            showsInfo = false
            store.stopLivePhotos()
            if let id { onSelection(id) }
        }
        .onChange(of: showsInfo) { _, shown in
            if shown { currentModel?.stopLivePhotoPlayback() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.stopLivePhotos() }
        }
        .onDisappear { store.stopLivePhotos() }
        .confirmationDialog(allowsRestore ? tr("Restore this item?") : tr("Move to Recently Deleted?"), isPresented: Binding(
            get: { trash.pendingAsset != nil },
            set: { if !$0 && !trashConfirmationSubmitted { trash.cancelConfirmation() } }
        ), titleVisibility: .visible) {
            Button(allowsRestore ? tr("Restore") : tr("Move to Trash"), role: allowsRestore ? nil : .destructive) {
                trashConfirmationSubmitted = true
                Task {
                    let succeeded = await trash.confirm()
                    trashConfirmationSubmitted = false
                    if succeeded { dismiss() }
                }
            }
            Button(tr("Cancel"), role: .cancel) { trash.cancelConfirmation() }
        } message: {
            Text(allowsRestore ? tr("These items will return to your library.") : tr("You can recover these items from Recently Deleted in Immich until your server removes them."))
        }
        .alert(allowsRestore ? tr("Couldn't Restore") : tr("Couldn't Move to Trash"), isPresented: Binding(
            get: { trash.error != nil },
            set: { if !$0 { trash.dismissError() } }
        )) {
            Button(tr("OK"), role: .cancel) { trash.dismissError() }
        } message: {
            if let error = trash.error { Text(error) }
        }
        .confirmationDialog(tr("More"), isPresented: $showsAccessibleMenu, titleVisibility: .hidden) {
            if let model = currentModel { menuActions(model) }
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
            .scrollDisabled(trashInteractionBlocked)
            .allowsHitTesting(!trashInteractionBlocked)
            .ignoresSafeArea()
            .onAppear { proxy.scrollTo(initialID) }
        }
        #else
        VStack {
            if let index = currentIndex { page(assets[index]) }
            HStack {
                Button(tr("Previous"), systemImage: "chevron.left") { step(-1) }
                    .disabled(assets.first?.id == currentID)
                Button(tr("Next"), systemImage: "chevron.right") { step(1) }
                    .disabled(assets.last?.id == currentID)
            }.padding()
        }
        #endif
    }

    private func page(_ asset: Asset) -> some View {
        ViewerPage(model: store.model(for: asset), isActive: currentID == asset.id,
                   livePlaybackAllowed: scenePhase == .active && !showsInfo && !showsAccessibleMenu && !trashInteractionBlocked) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        }
    }

    private func step(_ delta: Int) {
        guard let index = currentIndex, assets.indices.contains(index + delta) else { return }
        selectedID = assets[index + delta].id
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                GlassIconButton(systemImage: "chevron.left", label: tr("Close viewer")) {
                    store.stopLivePhotos()
                    dismiss()
                }
                Spacer(minLength: 8)
                if let model = currentModel { titleCapsule(model) }
                Spacer(minLength: 8)
                if let model = currentModel { moreMenu(model) }
                else { Color.clear.frame(width: 48, height: 48) }
            }
            if let model = currentModel, model.asset.isLivePhoto && !model.asset.isVideo {
                livePhotoBadge(model).padding(.leading, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func livePhotoBadge(_ model: ViewerAssetModel) -> some View {
        #if os(iOS)
        Button { toggleLivePhoto(model) } label: {
            Label(tr("Live Photo"), systemImage: model.isLivePhotoPlaying ? "livephoto.play" : "livephoto")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .photosGlass(in: Capsule())
        .disabled(model.isLivePhotoZoomed || model.isLoading || scenePhase != .active || showsInfo)
        .accessibilityLabel(model.isLivePhotoPlaying ? tr("Stop Live Photo") : tr("Play Live Photo"))
        #else
        Label(tr("Live Photo"), systemImage: "livephoto")
            .font(.caption.weight(.semibold))
            .padding(8)
            .photosGlass(in: Capsule(), interactive: false)
        #endif
    }

    @ViewBuilder
    private func menuActions(_ model: ViewerAssetModel) -> some View {
        Button(tr("Photo information"), systemImage: "info.circle") { showsInfo = true }
        if !allowsRestore && !model.asset.isTrashed {
            Button(model.asset.isFavorite ? tr("Remove from Favorites") : tr("Add to Favorites"),
                   systemImage: model.asset.isFavorite ? "heart.slash" : "heart") {
                model.stopLivePhotoPlayback()
                Task { await model.toggleFavorite() }
            }
        }
        #if os(iOS)
        if model.asset.isLivePhoto && !model.asset.isVideo {
            Button(model.isLivePhotoPlaying ? tr("Stop Live Photo") : tr("Play Live Photo"),
                   systemImage: model.isLivePhotoPlaying ? "stop.fill" : "livephoto.play") {
                toggleLivePhoto(model)
            }
            .disabled(model.isLivePhotoZoomed || model.isLoading)
        }
        #endif
    }

    private func moreMenu(_ model: ViewerAssetModel) -> some View {
        Menu { menuActions(model) } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .photosGlass(in: Circle())
        .accessibilityLabel(tr("More"))
        .simultaneousGesture(TapGesture().onEnded { model.stopLivePhotoPlayback() })
        .accessibilityAction {
            model.stopLivePhotoPlayback()
            showsAccessibleMenu = true
        }
    }

    private func toggleLivePhoto(_ model: ViewerAssetModel) {
        if model.isLivePhotoPlaying {
            model.stopLivePhotoPlayback()
        } else {
            Task {
                if model.playback == nil { await model.load() }
                guard currentID == model.asset.id, scenePhase == .active, !showsInfo, !trashInteractionBlocked else { return }
                model.startLivePhotoPlayback()
            }
        }
    }

    private func titleCapsule(_ model: ViewerAssetModel) -> some View {
        let date = model.asset.localDateTime
        let title = model.placeTitle ?? date.formatted(Self.dayStyle)
        let subtitle = model.placeTitle == nil
            ? date.formatted(Self.timeStyle)
            : "\(ViewerDateText.day(of: date))  \(date.formatted(Self.timeStyle))"
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
            ThumbnailStrip(assets: ThumbnailStrip.window(of: assets, around: currentIndex ?? 0),
                           selectedID: currentID, loader: loader) { id in
                selectedID = id
            }
            #endif
            HStack {
                if let model = currentModel {
                    ShareAssetButton(asset: model.asset, service: service, onPrepare: model.stopLivePhotoPlayback,
                                     onBusyChanged: { shareActive = $0 })
                } else {
                    Color.clear.frame(width: 48, height: 48)
                }
                Spacer()
                if let model = currentModel {
                    HStack(spacing: 4) {
                        if !allowsRestore && !model.asset.isTrashed {
                            capsuleButton(model.asset.isFavorite ? "heart.fill" : "heart",
                                          label: model.asset.isFavorite ? tr("Remove from Favorites") : tr("Add to Favorites")) {
                                Task { await model.toggleFavorite() }
                            }
                            .sensoryFeedback(.impact(weight: .light), trigger: model.asset.isFavorite)
                        }
                        capsuleButton("info.circle", label: tr("Photo information")) { showsInfo = true }
                    }
                    .padding(.horizontal, 6)
                    .photosGlass(in: Capsule())
                }
                Spacer()
                if allowsRestore, let model = currentModel, model.asset.isTrashed {
                    capsuleButton("arrow.uturn.backward", label: tr("Restore")) {
                        store.stopLivePhotos()
                        trash.request(model.asset)
                    }
                    .photosGlass(in: Circle())
                    .disabled(shareActive)
                } else if allowsTrash, let model = currentModel, !model.asset.isTrashed {
                    capsuleButton("trash", label: tr("Move to Trash")) {
                        store.stopLivePhotos()
                        trash.request(model.asset)
                    }
                    .photosGlass(in: Circle())
                    .disabled(shareActive)
                } else {
                    Color.clear.frame(width: 48, height: 48)
                }
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

    private static let dayStyle = Date.FormatStyle(locale: Localization.locale, calendar: Asset.localCalendar, timeZone: .gmt).day().month(.wide).year()
    private static let timeStyle = Date.FormatStyle(locale: Localization.locale, calendar: Asset.localCalendar, timeZone: .gmt).hour().minute()
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

    func stopLivePhotos() {
        for model in models.values { model.stopLivePhotoPlayback() }
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
    var livePlaybackAllowed = true
    let onTap: () -> Void
    @State private var playbackAllowed = false

    var body: some View {
        ZStack {
            if model.asset.isVideo, let request = model.playback {
                VideoPlaybackView(request: request, isActive: isActive && livePlaybackAllowed)
            } else if let image = model.image {
                #if os(iOS)
                ZoomableImage(image: image, isActive: isActive, onSingleTap: onTap,
                              livePhotoEnabled: livePlaybackAllowed && model.asset.isLivePhoto && model.playback != nil,
                              onLivePhotoHold: { held in
                                  if held && playbackAllowed { model.startLivePhotoPlayback() }
                                  else { model.stopLivePhotoPlayback() }
                              }, onZoomChanged: model.setLivePhotoZoomed)
                    .overlay {
                        if isActive, livePlaybackAllowed, model.isLivePhotoPlaying, let request = model.playback {
                            let generation = model.livePhotoPlaybackGeneration
                            LivePhotoPlaybackView(request: request) { failed in
                                model.finishLivePhotoPlayback(generation: generation, failed: failed)
                            }
                            .id(generation)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(model.asset.isVideo ? tr("Video preview") : tr("Photo"))
                #else
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .onTapGesture(perform: onTap)
                #endif
            } else if let error = model.error {
                VStack(spacing: 12) {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    Button(tr("Try Again")) { Task { await model.load() } }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let error = model.livePhotoPlaybackError, isActive {
                VStack(spacing: 8) {
                    Text(error).font(.callout).multilineTextAlignment(.center)
                    Button(tr("Try Again")) { retryLivePhoto() }
                }
                .padding()
                .photosGlass(in: RoundedRectangle(cornerRadius: 16), interactive: false)
                .padding(.horizontal, 32)
                .padding(.bottom, 180)
            }
        }
        .onAppear { playbackAllowed = isActive && livePlaybackAllowed }
        .onChange(of: livePlaybackAllowed) { _, allowed in
            playbackAllowed = isActive && allowed
            if !allowed { model.stopLivePhotoPlayback() }
        }
        .onChange(of: isActive) { _, active in
            playbackAllowed = active && livePlaybackAllowed
            if !active {
                model.stopLivePhotoPlayback()
                model.setLivePhotoZoomed(false)
            }
        }
        .onDisappear {
            playbackAllowed = false
            model.stopLivePhotoPlayback()
            model.setLivePhotoZoomed(false)
        }
        .task { if !model.isLoaded { await model.load() } }
    }

    private func retryLivePhoto() {
        Task {
            if model.playback == nil { await model.load() }
            guard playbackAllowed else { return }
            #if os(iOS)
            model.startLivePhotoPlayback()
            #endif
        }
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

#Preview("Viewer with Trash") {
    AssetViewer(assets: MockLibrary.standard.assets, selectedID: MockLibrary.standard.assets[0].id,
                service: MockImmichService.preview, onMoveToTrash: { _ in })
}

#Preview("Viewer with Restore") {
    let assets = MockLibrary.standard.assets.prefix(3).map { item in
        var asset = item
        asset.isTrashed = true
        return asset
    }
    AssetViewer(assets: assets, selectedID: assets[0].id,
                service: MockImmichService(assets: assets), onRestore: { _ in })
}
