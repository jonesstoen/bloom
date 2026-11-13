import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// A video or Live Photo motion clip that AVFoundation plays without ever seeing the API key.
///
/// AVFoundation streams `http(s)` media with its own loader, which follows redirects to other
/// servers and sends custom headers along (measured: after a 302 to another host, the second host
/// received `x-api-key`). So AVFoundation gets a private `bloom-media:` URL instead, and every byte
/// range it asks for is fetched here on `ImmichNetwork.session`, which refuses redirects to other
/// servers. The asset keeps its loader alive (`AVAssetResourceLoader` holds its delegate weakly).
public final class GuardedMediaAsset: AVURLAsset, @unchecked Sendable {
    public static let scheme = "bloom-media"
    private let loader: GuardedMediaLoader

    public init(request: MediaRequest, session: URLSession = ImmichNetwork.session) {
        loader = GuardedMediaLoader(request: request, session: session)
        // Nothing of the real address or the key appears in the URL AVFoundation sees.
        super.init(url: URL(string: "\(Self.scheme)://media/\(UUID().uuidString)")!, options: nil)
        resourceLoader.setDelegate(loader, queue: loader.queue)
    }
}

/// Answers AVFoundation's loading requests with byte ranges fetched on a redirect-guarded session.
final class GuardedMediaLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "no.immichkit.guarded-media")
    private let request: MediaRequest
    private let session: URLSession
    /// Running fetches by loading request. Only touched on `queue`.
    private var fetches: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(request: MediaRequest, session: URLSession) {
        self.request = request
        self.session = session
    }

    /// The resource loader holds this loader weakly and stops calling `didCancel` once the asset
    /// is gone, so stop every download here; an open-ended range would otherwise run to the end
    /// of the file with nobody reading it, blocking connections the rest of the app needs.
    deinit {
        for task in fetches.values { task.cancel() }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(loadingRequest)
        let range = Self.byteRange(for: loadingRequest.dataRequest)
        var urlRequest = request.urlRequest
        urlRequest.setValue("bytes=\(range.lowerBound)-\(range.upperBound.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        let fetch = RangeFetch(start: range.lowerBound, queue: queue, loadingRequest: loadingRequest) { [weak self] in
            self?.fetches[id] = nil
        }
        let task = session.dataTask(with: urlRequest)
        task.delegate = fetch
        fetches[id] = task
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        fetches.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    /// The bytes a loading request wants: from its current offset to its end, or to the end of the
    /// resource. A request without data (content information only) asks for the first two bytes.
    static func byteRange(for dataRequest: AVAssetResourceLoadingDataRequest?) -> (lowerBound: Int64, upperBound: Int64?) {
        guard let dataRequest else { return (0, 1) }
        let start = max(dataRequest.currentOffset, dataRequest.requestedOffset)
        if dataRequest.requestsAllDataToEndOfResource { return (start, nil) }
        let end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength) - 1
        return (start, max(start, end))
    }
}

/// One byte-range download, delivered to AVFoundation in chunks as it arrives.
private final class RangeFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    private let loadingRequest: AVAssetResourceLoadingRequest
    private let onDone: () -> Void
    /// Bytes to drop first when a server answers a range request with the whole file (200).
    private var skip: Int64 = 0
    private let start: Int64

    init(start: Int64, queue: DispatchQueue, loadingRequest: AVAssetResourceLoadingRequest, onDone: @escaping () -> Void) {
        self.start = start
        self.queue = queue
        self.loadingRequest = loadingRequest
        self.onDone = onDone
    }

    /// Belt and braces: the session delegate already refuses these, but a task delegate that
    /// handles redirects itself must never be more permissive.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        SameOriginRedirects.allows(from: task.originalRequest?.url ?? response.url, to: request.url) ? request : nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
            return .cancel
        }
        let partial = http.statusCode == 206
        if !partial { skip = start }
        queue.async { [loadingRequest] in
            guard !loadingRequest.isCancelled, let info = loadingRequest.contentInformationRequest else { return }
            // A generic type such as application/octet-stream would make AVFoundation refuse the item.
            let type = http.mimeType.flatMap { UTType(mimeType: $0) }
            info.contentType = (type?.conforms(to: .audiovisualContent) == true ? type! : .mpeg4Movie).identifier
            info.isByteRangeAccessSupported = partial
            if let total = Self.totalLength(contentRange: http.value(forHTTPHeaderField: "Content-Range")) {
                info.contentLength = total
            } else if !partial, http.expectedContentLength >= 0 {
                info.contentLength = http.expectedContentLength
            }
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var chunk = data
        if skip > 0 {
            let dropped = min(Int64(chunk.count), skip)
            chunk = chunk.dropFirst(Int(dropped))
            skip -= dropped
        }
        guard !chunk.isEmpty else { return }
        queue.async { [loadingRequest] in
            guard !loadingRequest.isCancelled, !loadingRequest.isFinished else {
                dataTask.cancel()
                return
            }
            loadingRequest.dataRequest?.respond(with: chunk)
            // Stop once AVFoundation has everything it asked for.
            if let dataRequest = loadingRequest.dataRequest, !dataRequest.requestsAllDataToEndOfResource,
               dataRequest.currentOffset >= dataRequest.requestedOffset + Int64(dataRequest.requestedLength) {
                loadingRequest.finishLoading()
                dataTask.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        queue.async { [loadingRequest, onDone] in
            defer { onDone() }
            guard !loadingRequest.isCancelled, !loadingRequest.isFinished else { return }
            if let status, status != 200, status != 206 {
                // Includes a refused redirect, which arrives as its 3xx response.
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
            } else if let error {
                loadingRequest.finishLoading(with: error)
            } else {
                loadingRequest.finishLoading()
            }
        }
    }

    /// The total from `Content-Range: bytes 0-1/12345`.
    static func totalLength(contentRange: String?) -> Int64? {
        guard let total = contentRange?.split(separator: "/").last, let value = Int64(total), value >= 0 else { return nil }
        return value
    }
}
