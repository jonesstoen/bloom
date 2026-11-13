import Foundation
import ImmichKit
import Observation

/// Keeps an original on disk until the system share sheet has actually closed.
@MainActor @Observable
final class ViewerShareModel {
    private let service: any ImmichService
    private let downloader: OriginalFileDownloader
    @ObservationIgnored private var preparedDirectory: URL?
    @ObservationIgnored private var preparationTask: Task<PreparedShare, Error>?
    @ObservationIgnored private var preparationID: UUID?

    private(set) var isPreparing = false
    private(set) var isBusy = false
    var sharedFiles: PreparedShare?
    var failed = false

    init(service: any ImmichService, downloader: OriginalFileDownloader = .live) {
        self.service = service
        self.downloader = downloader
    }

    func prepare(asset: Asset) async {
        guard !isBusy, !Task.isCancelled else { return }
        let id = UUID()
        preparationID = id
        isPreparing = true
        isBusy = true
        failed = false
        let service = service
        let downloader = downloader
        let task = Task {
            try await SelectionShareFiles.prepare(
                assets: [asset], service: service, downloader: downloader, progress: { _ in }
            )
        }
        preparationTask = task
        defer {
            // A cancelled downloader may finish after a new attempt has already started.
            if preparationID == id {
                preparationID = nil
                preparationTask = nil
                isPreparing = false
                isBusy = preparedDirectory != nil
            }
        }
        do {
            guard let prepared = try await SelectionShareFiles.awaitPreparation(task) else { return }
            guard preparationID == id else {
                SelectionShareFiles.remove(prepared.directory)
                return
            }
            preparedDirectory = prepared.directory
            sharedFiles = prepared
        } catch {
            if preparationID == id { failed = true }
        }
    }

    func cancelPreparation() {
        preparationID = nil
        preparationTask?.cancel()
        preparationTask = nil
        isPreparing = false
        isBusy = preparedDirectory != nil
    }

    func finishSharing() {
        sharedFiles = nil
        if let preparedDirectory {
            SelectionShareFiles.remove(preparedDirectory)
            self.preparedDirectory = nil
        }
        isBusy = isPreparing
    }

    deinit {
        preparationTask?.cancel()
        if let preparedDirectory {
            try? FileManager.default.removeItem(at: preparedDirectory)
        }
    }
}
