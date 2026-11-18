import ImmichKit
import SwiftUI

/// Collections → Other → Hidden: the photos the owner hid (Immich's Archive), behind the device
/// lock. Locked, it shows only a placeholder; the photos exist in the view tree only while unlocked.
///
/// It locks again (`HiddenAlbumLock.lock()`) when
/// - the grid is removed from the screen by leaving Hidden (back button, another tab). Opening a
///   photo is not leaving: the viewer is a cover over the grid, and the check skips it anyway
///   (`LibraryGridModel.isViewerOpen`);
/// - the app goes inactive or to the background. This removes the grid, and the viewer with it,
///   before the app switcher takes its snapshot.
public struct HiddenCollectionView: View {
    private let lock: HiddenAlbumLock
    private let service: any ImmichService
    private let loader: ImageLoader?
    private let onUnhide: @MainActor () -> Void
    @AppStorage(HiddenAlbumLock.requiresAuthenticationKey) private var requiresAuthentication = true
    @Environment(\.scenePhase) private var scenePhase

    /// - Parameter onUnhide: called after photos were unhidden, so the main Library can reload.
    public init(lock: HiddenAlbumLock, service: any ImmichService, loader: ImageLoader? = nil,
                onUnhide: @escaping @MainActor () -> Void = {}) {
        self.lock = lock
        self.service = service
        self.loader = loader
        self.onUnhide = onUnhide
    }

    public var body: some View {
        Group {
            if lock.isUnlocked {
                HiddenGrid(lock: lock, service: service, loader: loader, onUnhide: onUnhide)
            } else {
                locked
            }
        }
        // Prompts as the screen opens. A failure or cancel leaves the placeholder with its button.
        .task { await unlock() }
        // Back from the background: prompt again. (The prompt itself only goes active → inactive →
        // active, so this doesn't repeat after a cancel.)
        .onChange(of: scenePhase) { old, new in
            if old == .background, new == .active, !lock.isUnlocked { Task { await unlock() } }
        }
    }

    private func unlock() async {
        await lock.unlock(requiresAuthentication: requiresAuthentication)
    }

    private var locked: some View {
        ContentUnavailableView {
            Label(tr("Hidden"), systemImage: "eye.slash")
        } actions: {
            Button(tr("Unlock Hidden")) { Task { await unlock() } }
        }
        .navigationTitle(tr("Hidden"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The unlocked content: the archive grid with selection (Unhide), a footer and the relocking.
private struct HiddenGrid: View {
    let lock: HiddenAlbumLock
    let onUnhide: @MainActor () -> Void
    @State private var model: LibraryGridModel
    /// Unhidden photos the main Library has been told about.
    @State private var reported: Set<String> = []
    @Environment(\.scenePhase) private var scenePhase

    init(lock: HiddenAlbumLock, service: any ImmichService, loader: ImageLoader?, onUnhide: @escaping @MainActor () -> Void) {
        self.lock = lock
        self.onUnhide = onUnhide
        _model = State(initialValue: LibraryGridModel(
            service: service, options: TimelineOptions(visibility: .archive, newestFirst: false), loader: loader))
    }

    var body: some View {
        LibraryGridView(model: model, title: tr("Hidden"), allowsSelection: true,
                        emptyMessage: tr("Photos you hide appear here."))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text(tr("In Immich on the web, these photos are in Archive."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
            // An unhide (selection or viewer) ends with the model's write period; the confirmed
            // photos are then in `edits.unhiddenIDs`.
            .onChange(of: model.isMutating) { old, new in
                guard old, !new else { return }
                let fresh = model.edits.unhiddenIDs.subtracting(reported)
                guard !fresh.isEmpty else { return }
                reported.formUnion(fresh)
                onUnhide()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { lock.lock() }
            }
            .onDisappear {
                if !model.isViewerOpen { lock.lock() }
            }
    }
}

#Preview("Hidden") {
    NavigationStack {
        HiddenCollectionView(lock: HiddenAlbumLock(authenticator: PreviewAuthenticator()), service: MockImmichService.preview)
    }
}

/// Lets the preview open without a system prompt.
private struct PreviewAuthenticator: DeviceAuthenticator {
    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { true }
}
