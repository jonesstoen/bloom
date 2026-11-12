import Foundation
import ImmichKit
import Observation

/// Captures an explicit confirmation target before starting a single trash request.
@MainActor @Observable
public final class ViewerTrashModel {
    public private(set) var pendingAsset: Asset?
    public private(set) var isBusy = false
    public private(set) var error: String?
    @ObservationIgnored private let action: (@MainActor (Asset) async throws -> Void)?

    public init(action: (@MainActor (Asset) async throws -> Void)? = nil) {
        self.action = action
    }

    public func request(_ asset: Asset) {
        guard action != nil, !asset.isTrashed, !isBusy, pendingAsset == nil else { return }
        error = nil
        pendingAsset = asset
    }

    public func cancelConfirmation() {
        guard !isBusy else { return }
        pendingAsset = nil
    }

    public func dismissError() { error = nil }

    public func confirm() async -> Bool {
        guard !isBusy, let asset = pendingAsset, let action else { return false }
        pendingAsset = nil
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await action(asset)
            return true
        } catch let policyError as TrashError {
            error = policyError.localizedDescription
        } catch {
            self.error = tr("Couldn't move this item to Trash. Please try again.")
        }
        return false
    }
}
