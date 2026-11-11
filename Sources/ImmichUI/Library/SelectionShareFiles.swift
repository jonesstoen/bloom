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

    public static let live = OriginalFileDownloader { request, destination in
        let (temporary, response) = try await URLSession.shared.download(for: request.urlRequest)
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

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func safeName(for asset: Asset) -> String {
        let name = (asset.originalFileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
        guard name.isEmpty || name == "." || name == ".." else { return name }
        let fileExtension = asset.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            ?? (asset.isVideo ? "mov" : "jpg")
        return "original." + fileExtension
    }
}
