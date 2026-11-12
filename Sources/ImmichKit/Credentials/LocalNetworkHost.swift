import Foundation

/// Hosts where plain http doesn't expose the API key to the internet: the user's own network
/// (private and link-local addresses, `.local` and similar names) and Tailscale, whose WireGuard
/// tunnel already encrypts the traffic (100.64.0.0/10, `fd7a:115c:a1e0::/48`, `*.ts.net`).
enum LocalNetworkHost {
    static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let v4 = ipv4(host) { return isLocal(v4) }
        if host.contains(":") { return isLocalIPv6(host) }
        if host == "localhost" || !host.contains(".") { return true }
        return [".local", ".lan", ".home.arpa", ".internal", ".ts.net"].contains { host.hasSuffix($0) }
    }

    private static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    private static func isLocal(_ a: [UInt8]) -> Bool {
        switch (a[0], a[1]) {
        case (10, _), (127, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        case (100, 64...127): return true // Tailscale (carrier-grade NAT range)
        default: return false
        }
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        if host == "::1" { return true }
        guard let first = host.split(separator: ":").first, let word = UInt16(first, radix: 16) else { return false }
        return word & 0xfe00 == 0xfc00 // unique local, includes Tailscale's fd7a:115c:a1e0::/48
            || word & 0xffc0 == 0xfe80 // link-local
    }
}

extension ServerCredentials {
    /// https, or http to a host on the user's own network or Tailscale. Anything else would send
    /// the API key across the internet as plain text, so Bloom refuses it.
    public var protectsAPIKey: Bool { Self.protectsAPIKey(serverURL) }

    public static func protectsAPIKey(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return url.host.map(LocalNetworkHost.isLocal) ?? false
        default: return false
        }
    }
}
