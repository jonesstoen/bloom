import Foundation
import ImmichKit
import Observation

/// Selection survives grid layout changes because it follows loaded asset identities.
@MainActor @Observable
public final class LibrarySelectionModel {
    public private(set) var isSelecting = false
    public private(set) var selectedIDs: Set<String> = []
    public private(set) var selectedAssets: [Asset] = []
    public private(set) var isBusy = false
    public private(set) var isPreparingShare = false
    public private(set) var completedCount = 0
    public private(set) var totalCount = 0
    public private(set) var error: String?
    public private(set) var sharedFiles: PreparedShare?
    public private(set) var pendingTrashAssets: [Asset]?
    public private(set) var pendingRestoreAssets: [Asset]?
    public var selectedCount: Int { selectedIDs.count }
    /// For "Add to Album": the service of the library the photos come from.
    var service: any ImmichService { library.service }
    private var hasPendingConfirmation: Bool { pendingTrashAssets != nil || pendingRestoreAssets != nil }

    @ObservationIgnored private let library: LibraryGridModel
    @ObservationIgnored private let downloader: OriginalFileDownloader
    @ObservationIgnored private let onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)?
    @ObservationIgnored private var shareTask: Task<PreparedShare, any Error>?
    @ObservationIgnored private var preparedDirectory: URL?
    /// A failed follow-up GET leaves the server's flag unknown, even if the snapshot matches.
    @ObservationIgnored private var uncertainFavoriteIDs: Set<String> = []

    public init(library: LibraryGridModel, downloader: OriginalFileDownloader = .live,
                onRestore: (@MainActor ([Asset]) async throws -> RestoreResult)? = nil) {
        self.library = library
        self.downloader = downloader
        self.onRestore = onRestore
    }

    deinit {
        shareTask?.cancel()
        if let preparedDirectory { SelectionShareFiles.remove(preparedDirectory) }
    }

    public func start() {
        guard !isBusy, !hasPendingConfirmation else { return }
        isSelecting = true
        error = nil
    }

    public func cancel() {
        guard !isBusy, !hasPendingConfirmation else { return }
        isSelecting = false
        selectedIDs = []
        selectedAssets = []
        error = nil
        completedCount = 0
        totalCount = 0
    }

    public func toggle(_ asset: Asset) {
        guard isSelecting, !isBusy, !hasPendingConfirmation,
              let index = library.gridIndex(ofAsset: asset.id),
              let loaded = library.gridAsset(atGridIndex: index) else { return }
        if selectedIDs.remove(loaded.id) != nil {
            selectedAssets.removeAll { $0.id == loaded.id }
        } else {
            selectedIDs.insert(loaded.id)
            selectedAssets.append(loaded)
        }
    }

    public func dismissError() { error = nil }

    /// Capture the exact selection; no service operation occurs until confirmation.
    public func requestTrash() {
        guard isSelecting, !isBusy, !hasPendingConfirmation, !library.isMutating,
              library.options.isTrashed != true, !selectedAssets.isEmpty,
              selectedAssets.allSatisfy({ !$0.isTrashed }) else { return }
        error = nil
        pendingTrashAssets = selectedAssets
    }

    public func cancelTrashConfirmation() {
        guard !isBusy else { return }
        pendingTrashAssets = nil
    }

    public func confirmTrash() async {
        guard !isBusy, let assets = pendingTrashAssets else { return }
        pendingTrashAssets = nil
        isBusy = true
        error = nil
        completedCount = 0
        totalCount = assets.count
        defer { isBusy = false }
        do {
            let result = try await library.moveToTrash(assets)
            let confirmed = Set(result.confirmedIDs)
            selectedAssets = assets.filter { !confirmed.contains($0.id) }
            selectedIDs = Set(selectedAssets.map(\.id))
            completedCount = confirmed.count
            if !selectedAssets.isEmpty { reportTrashFailure(selectedAssets.count) }
        } catch {
            // Keep all unconfirmed identities for an explicit, newly confirmed retry.
            selectedAssets = assets
            selectedIDs = Set(assets.map(\.id))
            if let error = error as? TrashError { self.error = error.localizedDescription }
            else { reportTrashFailure(assets.count) }
        }
    }

    private func reportTrashFailure(_ count: Int) {
        error = tr("Couldn't move %@ items to Trash. Please try again.",
                   count.formatted(.number.locale(Localization.locale)))
    }

    public func requestRestore() {
        guard isSelecting, !isBusy, !hasPendingConfirmation, !library.isMutating,
              library.options.isTrashed == true, !selectedAssets.isEmpty,
              selectedAssets.allSatisfy(\.isTrashed) else { return }
        error = nil
        pendingRestoreAssets = selectedAssets
    }

    public func cancelRestoreConfirmation() {
        guard !isBusy else { return }
        pendingRestoreAssets = nil
    }

    public func confirmRestore() async {
        guard !isBusy, let assets = pendingRestoreAssets else { return }
        pendingRestoreAssets = nil
        isBusy = true
        error = nil
        completedCount = 0
        totalCount = assets.count
        defer { isBusy = false }
        do {
            let result = try await library.restoreFromTrash(assets, perform: onRestore)
            let confirmed = Set(result.confirmedIDs)
            selectedAssets = assets.filter { !confirmed.contains($0.id) }
            selectedIDs = Set(selectedAssets.map(\.id))
            completedCount = confirmed.count
            if !selectedAssets.isEmpty { reportRestoreFailure(selectedAssets.count) }
        } catch {
            selectedAssets = assets
            selectedIDs = Set(assets.map(\.id))
            reportRestoreFailure(assets.count)
        }
    }

    private func reportRestoreFailure(_ count: Int) {
        error = tr("Couldn't restore %@ items. Please try again.",
                   count.formatted(.number.locale(Localization.locale)))
    }

    /// One explicit, idempotent target for the whole batch, including mixed selections.
    public func setFavorites(_ target: Bool) async {
        guard isSelecting, !isBusy, !hasPendingConfirmation, !selectedAssets.isEmpty else { return }
        isBusy = true
        error = nil
        completedCount = 0
        let assets = selectedAssets
        totalCount = assets.count
        var confirmed: [Asset] = []
        var failures: [Asset] = []
        for selected in assets {
            let asset = library.gridIndex(ofAsset: selected.id)
                .flatMap(library.gridAsset(atGridIndex:)) ?? selected
            if asset.isFavorite == target && !uncertainFavoriteIDs.contains(asset.id) {
                confirmed.append(asset)
            } else {
                do {
                    let updated = try await library.service.setFavorite(assetID: asset.id, isFavorite: target)
                    guard updated.id == asset.id, updated.isFavorite == target else {
                        throw ImmichServiceError.invalidResponse
                    }
                    // Detail responses may omit timeline metadata; merge only the confirmed flag.
                    var merged = asset
                    merged.isFavorite = updated.isFavorite
                    confirmed.append(merged)
                    uncertainFavoriteIDs.remove(asset.id)
                } catch {
                    // PUT may have succeeded before its follow-up GET failed. Retry the same target.
                    failures.append(asset)
                    uncertainFavoriteIDs.insert(asset.id)
                }
            }
            completedCount += 1
        }
        library.applyFavoriteUpdates(confirmed)
        selectedAssets = failures
        selectedIDs = Set(failures.map(\.id))
        if !failures.isEmpty {
            error = tr("Couldn't update Favorites for %@ items. Please try again.",
                       failures.count.formatted(.number.locale(Localization.locale)))
        }
        isBusy = false
    }

    public func prepareShare() async {
        guard isSelecting, !isBusy, !hasPendingConfirmation, !selectedAssets.isEmpty else { return }
        isBusy = true
        isPreparingShare = true
        error = nil
        completedCount = 0
        totalCount = selectedAssets.count
        let assets = selectedAssets
        let service = library.service
        let downloader = downloader
        let task = Task {
            try await SelectionShareFiles.prepare(assets: assets, service: service, downloader: downloader) { [weak self] count in
                await self?.updateShareProgress(count)
            }
        }
        shareTask = task
        do {
            let prepared = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            // Cancellation can race with the worker returning its completed batch.
            if Task.isCancelled || task.isCancelled {
                SelectionShareFiles.remove(prepared.directory)
            } else {
                preparedDirectory = prepared.directory
                sharedFiles = prepared
            }
        } catch {
            if !Task.isCancelled && !task.isCancelled && !(error is CancellationError) {
                self.error = tr("Couldn't prepare these items for sharing. Please try again.")
            }
        }
        shareTask = nil
        isPreparingShare = false
        isBusy = sharedFiles != nil
    }

    private func updateShareProgress(_ count: Int) { completedCount = count }

    public func cancelSharePreparation() {
        guard isPreparingShare else { return }
        shareTask?.cancel()
    }

    public func finishSharing() {
        guard !isPreparingShare else { return }
        if let sharedFiles { SelectionShareFiles.remove(sharedFiles.directory) }
        preparedDirectory = nil
        sharedFiles = nil
        isBusy = false
    }
}
