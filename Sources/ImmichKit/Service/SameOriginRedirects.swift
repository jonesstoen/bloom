import Foundation

/// The URLSession delegate for Immich requests: follows a redirect only when it stays on the same
/// scheme, host and port. URLSession copies request headers onto a redirected request, so
/// following a redirect elsewhere would hand the API key (`x-api-key`) to another server. A refused
/// redirect arrives as its 3xx response, which the service reports as an error.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    /// The session every live service uses unless a test injects its own transport.
    static let session = URLSession(configuration: .default, delegate: SameOriginRedirects(), delegateQueue: nil)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let origin = task.originalRequest?.url ?? response.url
        completionHandler(Self.allows(from: origin, to: request.url) ? request : nil)
    }

    /// Whether `session` refuses redirects to other servers (for tests of code that downloads).
    static func guards(_ session: URLSession) -> Bool { session.delegate is SameOriginRedirects }

    static func allows(from: URL?, to: URL?) -> Bool {
        guard let from, let to,
              let scheme = from.scheme?.lowercased(), scheme == to.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = from.host?.lowercased(), host == to.host?.lowercased() else { return false }
        return port(of: from, scheme: scheme) == port(of: to, scheme: scheme)
    }

    private static func port(of url: URL, scheme: String) -> Int {
        url.port ?? (scheme == "https" ? 443 : 80)
    }
}

/// The URLSession for any request that carries the API key outside the generated client (for
/// example downloading originals to disk). Never use `URLSession.shared` for those: it follows
/// redirects to other servers and sends the key along.
public enum ImmichNetwork {
    public static var session: URLSession { SameOriginRedirects.session }
}
