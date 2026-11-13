import ImmichKit
import SwiftUI

/// Full-screen media pager, laid out like viewing a photo in the iOS 26 Photos app:
/// a glass back button and a glass title capsule (place, day and time) at the top,
/// a thumbnail strip and a toolbar (share, favorite, info) at the bottom.
///
/// On iOS: swipe left and right between items (a lazy paging scroll view, so it handles
/// thousands of items), pinch or double-tap to zoom, tap to hide or show the bars, and swipe
/// down to close. A vertical recognizer complements the grid's zoom presentation transition.
/// Videos start playing when their page becomes current.
public struct AssetViewer: View {
    let assets: [Asset]
    let service: any ImmichService
    let loader: ImageLoader
    let onSelection: (String) -> Void
    /// The photo on screen once paging has come to rest (or after a jump from the strip).
    let onSettle: (String) -> Void
    private let initialID: String
    /// Position of each asset, built once: the bars look up the current item on every swipe.
    private let indexByID: [String: Int]
    @State private var selectedID: String?
    /// The pages the pager builds (see `ViewerPageWindow`).
    @State private var pageWindow: Range<Int>
    @State private var chromeVisible = true
    /// Where the bottom bar starts, measured, so video controls can sit just above it.
    @State private var chromeLayout = ViewerChromeLayout()
    @State private var showsInfo = false
    @State private var shareActive = false
    @State private var dismissMotion = ViewerDismissMotion()
    @State private var showsAccessibleMenu = false
    @State private var trash: ViewerTrashModel
    private let allowsTrash: Bool
    private let allowsRestore: Bool
    @State private var store: ViewerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.allowsLibraryChanges) private var allowsChanges
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(assets: [Asset], selectedID: String, service: any ImmichService,
                loader: ImageLoader? = nil, thumbnails: ThumbnailImageCache? = nil,
                onMoveToTrash: (@MainActor (Asset) async throws -> Void)? = nil,
                onRestore: (@MainActor (Asset) async throws -> Void)? = nil, onSelection: @escaping (String) -> Void = { _ in }, onSettle: @escaping (String) -> Void = { _ in }) {
        let loader = loader ?? ImageLoader(service: service)
        self.assets = assets
        self.service = service
        self.loader = loader
        self.onSelection = onSelection
        self.onSettle = onSettle
        self.allowsTrash = onMoveToTrash != nil
        self.allowsRestore = onRestore != nil
        _trash = State(initialValue: ViewerTrashModel(mode: onRestore != nil ? .restore : .trash, action: onRestore ?? onMoveToTrash))
        self.initialID = selectedID
        self.indexByID = Dictionary(assets.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        _selectedID = State(initialValue: selectedID)
        _pageWindow = State(initialValue: ViewerPageWindow.around(indexByID[selectedID] ?? 0, count: assets.count))
        let store = ViewerStore(service: service, loader: loader, thumbnails: thumbnails)
        store.updateSelection(index: indexByID[selectedID] ?? 0, assets: assets)
        _store = State(initialValue: store)
    }

    private var trashInteractionBlocked: Bool { trash.pendingAsset != nil || trash.isBusy }

    private var dismissInteractionBlocked: Bool {
        trashInteractionBlocked || trash.error != nil
            || showsAccessibleMenu || currentIndex == nil
    }

    private var currentPhotoIsZoomed: Bool { currentModel?.isLivePhotoZoomed == true }

    private var currentID: String { selectedID ?? initialID }

    private var currentIndex: Int? { indexByID[currentID] }

    private var currentModel: ViewerAssetModel? {
        currentIndex.map { store.model(for: assets[$0]) }
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            mediaAndInformation
        }
        .overlay(alignment: .top) {
            if chromeVisible && !showsInfo {
                topBar.transition(.opacity).disabled(trashInteractionBlocked)
                    .modifier(ViewerDismissChromeOpacity(motion: dismissMotion))
            }
        }
        .overlay(alignment: .bottom) {
            if chromeVisible {
                bottomBar.transition(.opacity).disabled(trashInteractionBlocked)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { chromeLayout.bottomBarTop = $0 }
                    .modifier(ViewerDismissChromeOpacity(motion: dismissMotion))
            }
        }
        .overlay {
            if trash.isBusy {
                ProgressView(allowsRestore ? tr("Restoring…") : tr("Moving to Trash…"))
                    .padding(24)
                    .photosGlass(in: RoundedRectangle(cornerRadius: 20), interactive: false)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: neighboursMayLoad, initial: true) { _, mayLoad in
            if store.neighboursMayLoad != mayLoad { store.neighboursMayLoad = mayLoad }
        }
        #if os(iOS)
        .statusBarHidden(!chromeVisible)
        .interactiveDismissDisabled(trashInteractionBlocked || showsInfo)
        .onChange(of: dismissInteractionBlocked) { _, blocked in
            if blocked { resetDismissDrag() }
        }
        .onChange(of: currentPhotoIsZoomed) { _, zoomed in
            if zoomed { resetDismissDrag() }
        }
        #endif
        .onChange(of: selectedID, initial: true) { _, id in
            resetDismissDrag()
            showsInfo = false
            store.stopLivePhotos()
            if let id, let index = indexByID[id] {
                store.updateSelection(index: index, assets: assets)
                onSelection(id)
            }
        }
        .onChange(of: showsInfo) { _, shown in
            if shown { currentModel?.stopLivePhotoPlayback() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.stopLivePhotos() }
        }
        .onDisappear { store.stopLivePhotos() }
        .confirmedAction(allowsRestore ? tr("Restore this item?") : tr("Move to Recently Deleted?"),
                         isPending: trash.pendingAsset != nil,
                         actionTitle: allowsRestore ? tr("Restore") : tr("Move to Trash"),
                         role: allowsRestore ? nil : .destructive,
                         message: allowsRestore ? tr("These items will return to your library.") : tr("You can recover these items from Recently Deleted in Immich until your server removes them."),
                         onCancel: { trash.cancelConfirmation() }) {
            if await trash.confirm() { dismiss() }
        }
        .errorAlert(allowsRestore ? tr("Couldn't Restore") : tr("Couldn't Move to Trash"),
                    message: trash.error, onDismiss: { trash.dismissError() })
        .confirmationDialog(tr("More"), isPresented: $showsAccessibleMenu, titleVisibility: .hidden) {
            if let model = currentModel { menuActions(model) }
        }
    }

    private var mediaAndInformation: some View {
        GeometryReader { geometry in
            let height = showsInfo ? geometry.size.height * 0.38 : geometry.size.height
            VStack(spacing: 0) {
                pager(height: height)
                    .frame(height: height)
                    .clipped()
                    .disabled(trashInteractionBlocked)
                    .modifier(ViewerDismissTransform(motion: dismissMotion))
                    .environment(\.viewerBottomBarTop, !showsInfo && chromeVisible && chromeLayout.bottomBarTop > 0 ? chromeLayout.bottomBarTop : nil)
                    .environment(\.viewerVideoPlayback, ViewerVideoPlayback { playing in
                        guard !showsInfo, chromeVisible == playing else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { chromeVisible = !playing }
                    })
                if showsInfo, let model = currentModel {
                    AssetInfoView(asset: model.asset, onClose: { setInformation(false) })
                        .padding(.bottom, chromeLayout.bottomBarTop > 0 ? max(70, geometry.frame(in: .global).maxY - chromeLayout.bottomBarTop) : 90)
                        .background(Color(white: 0.06))
                }
            }
        }
        .ignoresSafeArea()
    }

    private func setInformation(_ shown: Bool) {
        guard !trashInteractionBlocked, trash.error == nil, !showsAccessibleMenu else { return }
        resetDismissDrag()
        if shown { store.stopLivePhotos() }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            showsInfo = shown
            chromeVisible = true
        }
    }

    // MARK: Pager

    @ViewBuilder
    private func pager(height: CGFloat) -> some View {
        #if os(iOS)
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(assets[pageWindow.clamped(to: assets.indices)]) { asset in
                        page(asset)
                            .containerRelativeFrame(.horizontal)
                            // The vertical relative frame includes safe-area space in a reduced pager.
                            .frame(height: height)
                            .id(asset.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedID)
            .onScrollPhaseChange { _, phase in
                // Move the window once paging has settled, never mid-swipe.
                guard phase == .idle else { return }
                recentrePageWindow()
                onSettle(currentID)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(trashInteractionBlocked)
            .allowsHitTesting(!trashInteractionBlocked)
            .onAppear { proxy.scrollTo(initialID) }
            .gesture(ViewerDismissGesture(isZoomed: currentPhotoIsZoomed,
                                          blocked: dismissInteractionBlocked,
                                          allowsUp: true,
                                          onChanged: updateDismissDrag,
                                          onEnded: endDismissDrag,
                                          onCancelled: resetDismissDrag))
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

    private func updateDismissDrag(_ translation: CGSize) {
        guard !dismissInteractionBlocked, !currentPhotoIsZoomed, !showsInfo else { return }
        if translation.height > 0, dismissMotion.offset == 0 { store.stopLivePhotos() }
        dismissMotion.offset = max(0, translation.height)
    }

    private func endDismissDrag(_ translation: CGSize) {
        let action = ViewerGesture.verticalAction(x: translation.width, y: translation.height,
                                                  isZoomed: currentPhotoIsZoomed,
                                                  blocked: dismissInteractionBlocked, infoShown: showsInfo)
        switch action {
        case .openInfo: setInformation(true)
        case .closeInfo: setInformation(false)
        case .dismiss:
            store.stopLivePhotos()
            dismiss()
        case .none: resetDismissDrag()
        }
    }

    private func resetDismissDrag() {
        guard dismissMotion.offset != 0 else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            dismissMotion.offset = 0
        }
    }

    private func page(_ asset: Asset) -> some View {
        ViewerPage(model: store.model(for: asset), store: store, isActive: currentID == asset.id,
                   livePlaybackAllowed: scenePhase == .active && !showsInfo && !showsAccessibleMenu && !trashInteractionBlocked) {
            if showsInfo { setInformation(false) }
            else { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { chromeVisible.toggle() } }
        }
    }

    /// Other pages load their previews once the current one has its own (or failed), so the
    /// photo on screen gets the whole connection first. (When the viewer opens, the lazy pager
    /// briefly builds the window's first page before it scrolls to the photo.) Published through
    /// the store, which pages observe themselves: values passed from here don't reach pages
    /// already built.
    private var neighboursMayLoad: Bool {
        guard let model = currentModel else { return true }
        return model.image != nil || model.error != nil
    }

    private func recentrePageWindow() {
        guard let index = currentIndex,
              let window = ViewerPageWindow.recentred(pageWindow, index: index, count: assets.count) else { return }
        pageWindow = window
    }

    /// Jumps to `id` (the thumbnail strip), building its page first if it is outside the window.
    private func select(_ id: String) {
        if let index = indexByID[id] { store.updateSelection(index: index, assets: assets) }
        if let index = indexByID[id], let window = ViewerPageWindow.recentred(pageWindow, index: index, count: assets.count) {
            pageWindow = window
        }
        selectedID = id
        onSettle(id)
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
        Button(tr("Photo information"), systemImage: "info.circle") { setInformation(true) }
        if allowsChanges && !allowsRestore && !model.asset.isTrashed {
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
            if !showsInfo {
                ThumbnailStrip(assets: ThumbnailStrip.window(of: assets, around: currentIndex ?? 0),
                           selectedID: currentID, loader: loader) { id in
                    select(id)
                }
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
                        if allowsChanges && !allowsRestore && !model.asset.isTrashed {
                            capsuleButton(model.asset.isFavorite ? "heart.fill" : "heart",
                                          label: model.asset.isFavorite ? tr("Remove from Favorites") : tr("Add to Favorites")) {
                                Task { await model.toggleFavorite() }
                            }
                            .sensoryFeedback(.impact(weight: .light), trigger: model.asset.isFavorite)
                        }
                        capsuleButton(showsInfo ? "info.circle.fill" : "info.circle", label: showsInfo ? tr("Close information") : tr("Photo information")) {
                            setInformation(!showsInfo)
                        }
                        .accessibilityAddTraits(showsInfo ? .isSelected : [])
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

#Preview("Viewer") {
    AssetViewer(assets: MockLibrary.standard.assets, selectedID: MockLibrary.standard.assets[0].id, service: MockImmichService.preview)
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
