import Foundation

/// One staged upload: the multipart body of one resource of one device asset, waiting to be sent or
/// being sent. It is stored in the index from enqueue until its result is recorded, so a relaunch can
/// tell which body files and results still belong to something.
public struct UploadJob: Sendable, Codable, Equatable {
    public let assetID: String
    public let resource: DeviceResourceType
    /// Identifies this try. A result is recorded once per attempt; a later delivery of it changes nothing.
    public let attempt: UUID
    /// The name of the staged multipart body inside the staging folder (`BackupStaging.url(forBodyNamed:)`).
    /// A name, not a URL: the app container's path can change between launches. The file is deleted once
    /// the result is recorded.
    public let bodyFileName: String
    /// The SHA-1 (base64) of the resource's bytes, as the scanner recorded it. A result is applied only
    /// while the index entry still has this checksum for `resource`.
    public let checksum: String
    /// Whether the request was made with cellular access (the item's cellular switch was on when it was
    /// enqueued). Jobs stored before this existed decode as `true`.
    public let allowsCellular: Bool

    public init(
        assetID: String, resource: DeviceResourceType, attempt: UUID, bodyFileName: String, checksum: String,
        allowsCellular: Bool = true
    ) {
        self.assetID = assetID
        self.resource = resource
        self.attempt = attempt
        self.bodyFileName = bodyFileName
        self.checksum = checksum
        self.allowsCellular = allowsCellular
    }

    private enum CodingKeys: String, CodingKey {
        case assetID, resource, attempt, bodyFileName, checksum, allowsCellular
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try container.decode(String.self, forKey: .assetID)
        resource = try container.decode(DeviceResourceType.self, forKey: .resource)
        attempt = try container.decode(UUID.self, forKey: .attempt)
        bodyFileName = try container.decode(String.self, forKey: .bodyFileName)
        checksum = try container.decode(String.self, forKey: .checksum)
        allowsCellular = try container.decodeIfPresent(Bool.self, forKey: .allowsCellular) ?? true
    }
}

/// Why an upload did not complete, in the terms `BackupUploader.classify` decides retry, stop and fail by.
public enum UploadFailure: Sendable, Equatable {
    /// An HTTP status or transport problem, as `ImmichServiceError` names it.
    case service(ImmichServiceError)
    /// The server refused the file for a reason retrying won't fix (4xx other than 401, 403, 408, 429).
    case rejected(status: Int, message: String)
    /// The task was cancelled (switch turned off, sign-out).
    case cancelled
    /// The disk is full (`BackupStaging.isOutOfSpace`).
    case outOfSpace
    /// Anything else, as the text to show.
    case other(String)

    public init(_ error: Error) {
        if BackupStaging.isOutOfSpace(error) {
            self = .outOfSpace
            return
        }
        switch error {
        case let BackupUploadError.rejected(status, message):
            self = .rejected(status: status, message: message)
        case let error as ImmichServiceError:
            self = .service(error)
        case is CancellationError:
            self = .cancelled
        case let error as URLError:
            self = error.code == .cancelled
                ? .cancelled : .service(.network(error.localizedDescription, code: error.code))
        default:
            self = .other(error.localizedDescription)
        }
    }

    /// The error `BackupUploader.classify` takes.
    var error: Error {
        switch self {
        case let .service(error): error
        case let .rejected(status, message): BackupUploadError.rejected(status: status, message: message)
        case .cancelled: CancellationError()
        case .outOfSpace: BackupStagingError.notEnoughSpace
        case let .other(message): UploadFailureMessage(message: message)
        }
    }
}

private struct UploadFailureMessage: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// What came of an upload job.
public enum UploadOutcome: Sendable, Equatable {
    /// The server has the file: created (201) or already had it (200).
    case uploaded(AssetUploadResult)
    case failed(UploadFailure)
}

/// Where staged upload bodies go to be sent. The index, scanner, verdicts and UI don't depend on how:
/// a background `URLSession` implements it, and so could a PhotoKit upload extension. Results are not
/// returned from here; the implementation hands each one to `BackupResultRecorder`.
public protocol BackupTransport: Sendable {
    /// Starts sending the job's body file with `request` (the request without its body). The job is added to
    /// the index **and the index saved** before this returns: `BackupResultRecorder` drops results for jobs
    /// the index doesn't know, so a job that only existed in memory would lose its result after a crash.
    func enqueue(_ job: UploadJob, request: URLRequest) async throws
    /// The jobs started and not yet recorded. Waits for whatever the transport does first when it starts
    /// (`BackgroundSessionTransport` reconciles with iOS and cleans up the staging folder), so call it
    /// before staging anything for the account.
    func inFlight() async -> [UploadJob]
    /// Cancels everything in flight.
    func cancelAll() async
    /// Cancels the jobs in flight with these attempts; their items go back to the queue through the
    /// recorder's cancelled path. Others are left alone.
    func cancel(attempts: Set<UUID>) async
    /// An upload was seen redirected to another server: `enqueue` refuses with
    /// `BackupTransportError.redirectBlocked` until `clearRedirectBlock()`.
    var isRedirectBlocked: Bool { get }
    /// Lifts the redirect block. Only on the user's explicit Try Again (`BackupModel.retryAfterRedirect`):
    /// a passing check doesn't prove the uploads themselves aren't redirected.
    func clearRedirectBlock()
    /// The bytes sent so far of each upload in flight that has reported any, by job attempt. Cheap and
    /// synchronous: a screen polls it (a few times a second at most) to show progress.
    func uploadProgress() -> [UUID: UploadBytes]
}

extension BackupTransport {
    /// A transport that can't tell reports nothing; uploads then show without a fraction.
    public func uploadProgress() -> [UUID: UploadBytes] { [:] }
}

/// How much of one upload's body has been sent.
public struct UploadBytes: Sendable, Equatable {
    public let sent: Int64
    /// The body's size, or a negative number when the transport doesn't know it.
    public let expected: Int64

    public init(sent: Int64, expected: Int64) {
        self.sent = sent
        self.expected = expected
    }

    /// `sent / expected` in 0...1, nil while the size is unknown.
    public var fraction: Double? {
        guard expected > 0 else { return nil }
        return min(1, max(0, Double(sent) / Double(expected)))
    }
}

extension BackupTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .redirectBlocked:
            tr("An upload was redirected to another address. Uploads are paused until you tap Try Again on the Backup screen.")
        }
    }
}
