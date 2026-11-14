import Foundation

/// The one place an upload's result is written into the index, whether the app was open or iOS
/// relaunched it in the background to deliver the result.
///
/// It applies the rules of `BackupUploader` (the same `classify`, the same states): a success records the
/// server ID of the resource and, once every resource of the item is on the server and nothing is left to
/// join, marks it backed up; a failure that retrying can fix, or that isn't the item's fault, leaves it
/// queued; a refusal fails it with the server's message. The job's record, the entry's change and the
/// save happen before the body file is deleted, and a result is applied once per attempt.
public actor BackupResultRecorder {
    private let index: BackupIndex
    private let staging: BackupStaging

    public init(index: BackupIndex, staging: BackupStaging) {
        self.index = index
        self.staging = staging
    }

    /// Applies `outcome` of `job`. Ignored when the job's attempt was recorded before or the entry no longer
    /// has the checksum the job was staged for (the asset changed and the scanner has taken it over).
    /// The body file is deleted only after the index was saved successfully, and only when no remaining
    /// job names the same file; so a failed save, a repeated delivery whose first record hasn't been
    /// saved yet, or two records at once never delete a body whose result isn't on disk. Even an ignored
    /// record saves first for that reason.
    public func record(_ job: UploadJob, _ outcome: UploadOutcome) async {
        let claimed = await index.complete(
            attempt: job.attempt, if: { stored, entry in entry.checksums[stored.resource] == stored.checksum },
            { stored, entry in Self.apply(outcome, of: stored, to: &entry) })
        let name = claimed?.bodyFileName ?? job.bodyFileName
        // The body stays when the index couldn't be saved: the result is only in memory then, and
        // cleanup of unreferenced files removes it later.
        guard (try? await index.saveIfChanged()) != nil else { return }
        guard await !index.jobs.contains(where: { $0.bodyFileName == name }),
              let body = staging.url(forBodyNamed: name) else { return }
        staging.remove(body)
    }

    private static func apply(_ outcome: UploadOutcome, of job: UploadJob, to entry: inout BackupEntry) {
        switch outcome {
        case let .uploaded(result):
            entry.serverIDs[job.resource] = result.id
            // Not before the other half is on the server and joined (`needsLink` is cleared by the link).
            guard case .pending = entry.state, !entry.needsLink,
                  entry.checksums.keys.allSatisfy({ entry.serverIDs[$0] != nil }),
                  let main = BackupUploader.mainType(of: Set(entry.checksums.keys)),
                  let serverID = entry.serverIDs[main] else { return }
            entry.state = .backedUp(serverAssetID: serverID)
        case let .failed(failure):
            // Only an item still waiting is moved: one the user or the server has since taken elsewhere
            // (deleted on the server) stays where it is.
            guard case .pending = entry.state else { return }
            switch BackupUploader.classify(failure.error, cancelled: false) {
            case let .failed(reason):
                entry.state = .failed(reason: reason)
            case .cancelled, .stop, .retry:
                entry.state = .pending(reason: .needsUpload)
            case .outOfSpace:
                entry.state = .failed(reason: BackupUploader.notEnoughSpaceReason)
            }
        }
    }
}
