import Foundation
import ImmichKit

/// Writes from the grid: favorites, moving to trash and restoring from Recently Deleted.
///
/// The rule throughout: a write the server confirmed is shown at once and never undone locally,
/// even if the view that started it is gone. A write whose outcome is unknown (a failed or
/// partial response, which can follow an accepted write) keeps the current presentation but
/// marks it as unreliable (`needsFreshTrashLoad`): it is neither saved to disk nor reused until
/// a fresh server load replaces it. The disk snapshot is cleared before every trash or restore
/// request, so a force quit right after the server accepted it cannot bring old photos back.
extension LibraryGridModel {
    /// Applies confirmed favorite changes once, keeping all other timeline state.
    func applyFavoriteUpdates(_ assets: [Asset]) {
        guard !assets.isEmpty else { return }
        for asset in assets { edits.favoriteOverrides[asset.id] = asset.isFavorite }
        apply(months)
        scheduleSnapshotSave()
    }

    /// Moves assets to Immich's trash (never deletes permanently). Only confirmed IDs disappear
    /// from the grid; uncertain results still invalidate old snapshots.
    public func moveToTrash(_ assets: [Asset]) async throws -> TrashResult {
        guard !isMutating else { throw ImmichServiceError.invalidResponse }
        guard !assets.isEmpty, options.isTrashed != true, !assets.contains(where: \.isTrashed) else {
            return TrashResult(confirmedIDs: [], failedIDs: [])
        }
        isTrashing = true
        defer { isTrashing = false }
        // Drop callbacks of loads started before the write. Cancelling a task alone does not
        // stop a service response or an already enqueued actor call from completing later.
        loadGeneration += 1
        loadingMonths = []
        snapshotSave?.cancel()
        if let snapshotStore {
            // New saves are blocked by isTrashing; queued ones keep the previous revision.
            snapshotRevision = await snapshotStore.clearAll()
        }
        let ids = Self.uniqueIDs(assets)
        do {
            let result = try await service.moveToTrash(assetIDs: ids)
            try LocalLibraryEdits.validate(confirmed: result.confirmedIDs, failed: result.failedIDs, requested: Set(ids))
            // No Task.isCancelled check: a confirmed write must reach the grid and the cache
            // even if the viewer that started it has disappeared.
            await applyTrashOutcome(confirmedIDs: Set(result.confirmedIDs), uncertain: !result.failedIDs.isEmpty)
            return result
        } catch {
            await applyTrashOutcome(confirmedIDs: [], uncertain: true)
            throw error
        }
    }

    private func applyTrashOutcome(confirmedIDs: Set<String>, uncertain: Bool) async {
        edits.trashedIDs.formUnion(confirmedIDs)
        needsFreshTrashLoad = needsFreshTrashLoad || uncertain
        apply(months)
        let replacement = Timeline(service: service, options: options)
        timeline = replacement
        didAttemptRestore = true
        let generation = loadGeneration
        let snapshot = months
        trashRevision += 1
        if !needsFreshTrashLoad {
            // The current, already filtered sort/filter can seed the new timeline. Every other
            // one was discarded because it may contain the same IDs.
            _ = await replacement.restore(snapshot)
            guard isCurrent(replacement, generation) else { return }
            scheduleSnapshotSave()
        }
    }

    /// Restores the confirmed selection from Recently Deleted. The root passes its main-library
    /// action as `perform`, so both views share one write and one busy period.
    public func restoreFromTrash(
        _ assets: [Asset],
        perform: (@MainActor ([Asset]) async throws -> RestoreResult)? = nil
    ) async throws -> RestoreResult {
        guard !isMutating else { throw ImmichServiceError.invalidResponse }
        guard options.isTrashed == true, !assets.isEmpty, assets.allSatisfy(\.isTrashed) else {
            return RestoreResult(confirmedIDs: [], failedIDs: [])
        }
        isRestoring = true
        defer {
            isRestoring = false
            restoreRevision += 1
            if !needsFreshTrashLoad { scheduleSnapshotSave() }
        }
        let previouslyUncertain = needsFreshTrashLoad
        await prepareRestore()
        var seen: Set<String> = []
        let targets = assets.filter { seen.insert($0.id).inserted }
        do {
            let result: RestoreResult
            if let perform {
                result = try await perform(targets)
            } else {
                result = try await service.restoreAssets(assetIDs: targets.map(\.id))
            }
            try LocalLibraryEdits.validate(confirmed: result.confirmedIDs, failed: result.failedIDs,
                                           requested: Set(targets.map(\.id)))
            // Cancellation cannot undo an acknowledged write: keep every confirmed removal.
            edits.restoredIDs.formUnion(result.confirmedIDs)
            needsFreshTrashLoad = previouslyUncertain || !result.failedIDs.isEmpty
            apply(months)
            if !needsFreshTrashLoad {
                // A fully known outcome can seed the timeline; anything else is shown only.
                _ = await timeline.restore(months)
            }
            return result
        } catch {
            needsFreshTrashLoad = true
            throw error
        }
    }

    /// Restores assets, then reloads the current library while still busy. (Capture dates
    /// alone cannot put restored photos back into Recently Added order.)
    public func restoreToLibrary(_ assets: [Asset]) async throws -> RestoreResult {
        guard !isMutating else { throw ImmichServiceError.invalidResponse }
        guard options.isTrashed != true, !assets.isEmpty, assets.allSatisfy(\.isTrashed) else {
            return RestoreResult(confirmedIDs: [], failedIDs: [])
        }
        isRestoring = true
        defer {
            isRestoring = false
            restoreRevision += 1
            if !needsFreshTrashLoad { scheduleSnapshotSave() }
        }
        await prepareRestore()
        let ids = Self.uniqueIDs(assets)
        do {
            let result = try await service.restoreAssets(assetIDs: ids)
            try LocalLibraryEdits.validate(confirmed: result.confirmedIDs, failed: result.failedIDs, requested: Set(ids))
            edits.trashedIDs.subtract(result.confirmedIDs)
            // load() swallows its own failures, so a confirmed result is never lost because
            // the follow-up read failed or was cancelled.
            await load(reconcilingTrash: false, restoring: true)
            return result
        } catch {
            // Keep the old grid only until fresh buckets replace it; never save it.
            await load(reconcilingTrash: false, restoring: true)
            throw error
        }
    }

    private func prepareRestore() async {
        loadGeneration += 1
        loadingMonths = []
        snapshotSave?.cancel()
        timeline = Timeline(service: service, options: options)
        didAttemptRestore = true
        needsFreshTrashLoad = true
        if let snapshotStore {
            // Clears every saved sort/filter, and queued saves keep their old revision.
            snapshotRevision = await snapshotStore.clearAll()
        }
    }

    private static func uniqueIDs(_ assets: [Asset]) -> [String] {
        var seen: Set<String> = []
        return assets.map(\.id).filter { seen.insert($0).inserted }
    }
}
