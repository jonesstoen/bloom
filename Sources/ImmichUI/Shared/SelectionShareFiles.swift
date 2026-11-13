import Foundation
import ImmichKit
import UniformTypeIdentifiers

/// Downloads an original directly to disk; injected in tests to avoid network requests.
public struct OriginalFileDownloader: Sendable {
    private let downloadFile: @Sendable (MediaRequest, URL) async throws -> Void

    public init(download: @escaping @Sendable (MediaRequest, URL) async throws -> Void) {
        downloadFile = download
    }

    public func download(_ request: MediaRequest, to destination: URL) async throws {
        try await downloadFile(request, destination)
    }

    /// Downloads with the API key on `ImmichNetwork.session`, which never follows a redirect to
    /// another server (URLSession.shared would, and send the key along).
    public static let live = OriginalFileDownloader { request, destination in
        let (temporary, response) = try await ImmichNetwork.session.download(for: request.urlRequest)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ImmichServiceError.invalidResponse
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try Task.checkCancellation()
    }
}

/// A complete batch, kept on disk until the activity controller finishes.
public struct PreparedShare: Identifiable, Sendable {
    public let id: UUID
    public let urls: [URL]
    public let directory: URL
}

enum SelectionShareFiles {
    static func prepare(
        assets: [Asset], service: any ImmichService, downloader: OriginalFileDownloader,
        progress: @Sendable (Int) async -> Void
    ) async throws -> PreparedShare {
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BloomShare-\(id.uuidString)", isDirectory: true)
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var urls: [URL] = []
            for asset in assets {
                try Task.checkCancellation()
                // Timeline rows omit original names and MIME types. Fetch detail only when
                // needed so the activity controller receives the original format and name.
                var original = asset
                if asset.originalFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    original = try await service.asset(id: asset.id)
                    guard original.id == asset.id else { throw ImmichServiceError.invalidResponse }
                    try Task.checkCancellation()
                }
                // Separate directories preserve duplicate original names without collisions.
                let assetDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
                let destination = assetDirectory.appendingPathComponent(safeName(for: original))
                let request = try await service.mediaRequest(.original, assetID: asset.id)
                try Task.checkCancellation()
                try await downloader.download(request, to: destination)
                try Task.checkCancellation()
                urls.append(destination)
                await progress(urls.count)
            }
            try Task.checkCancellation()
            return PreparedShare(id: id, urls: urls, directory: directory)
        } catch {
            remove(directory)
            throw error
        }
    }

    /// Awaits a preparation task and forwards the caller's cancellation to it. Returns nil when
    /// the caller or the task was cancelled, removing the files if the worker finished anyway
    /// (cancellation can race with it returning a completed batch). Other errors are rethrown.
    /// Main-actor isolated so the cancellation check and the caller's use of the result run
    /// without a suspension in between.
    @MainActor
    static func awaitPreparation(_ task: Task<PreparedShare, any Error>) async throws -> PreparedShare? {
        do {
            let prepared = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if Task.isCancelled || task.isCancelled {
                remove(prepared.directory)
                return nil
            }
            return prepared
        } catch {
            if error is CancellationError || Task.isCancelled || task.isCancelled { return nil }
            throw error
        }
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A file name for the share sheet. Original names come from whoever uploaded the photo (for
    /// shared albums, another person), so invisible and direction-changing characters are removed:
    /// "IMG\u{202E}gpj.exe" would otherwise show as "IMGexe.jpg". Separators become "_", leading
    /// dots (hidden files) are dropped, and the name stays within the 255-byte file-name limit.
    static func safeName(for asset: Asset) -> String {
        let unsafe: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator,
                                                    .surrogate, .privateUse, .unassigned]
        var scalars = String.UnicodeScalarView()
        // Zero-width (non-)joiners are format characters too, but harmless and needed for emoji
        // sequences and some scripts.
        let joiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]
        for scalar in (asset.originalFileName ?? "").unicodeScalars
        where joiners.contains(scalar) || !unsafe.contains(scalar.properties.generalCategory) {
            scalars.append("/\\:".unicodeScalars.contains(scalar) ? "_" : scalar)
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.utf8.count > maxNameBytes { name = truncated(name) }
        guard name.isEmpty else { return name }
        let fileExtension = asset.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            ?? (asset.isVideo ? "mov" : "jpg")
        return "original." + fileExtension
    }

    /// Well under the 255-byte limit of APFS, leaving room for the system's own suffixes.
    static let maxNameBytes = 200

    /// Shortens the stem and keeps a short extension, cutting on character boundaries.
    private static func truncated(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let keepsExtension = !ext.isEmpty && ext.utf8.count <= 16
        var stem = keepsExtension ? String(name.dropLast(ext.count + 1)) : name
        let budget = maxNameBytes - (keepsExtension ? ext.utf8.count + 1 : 0)
        while stem.utf8.count > budget { stem.removeLast() }
        return keepsExtension ? stem + "." + ext : stem
    }
}
