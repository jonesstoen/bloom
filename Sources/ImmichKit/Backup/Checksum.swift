import CryptoKit
import Foundation

/// Incremental SHA1 of a file's bytes, in the base64 form Immich accepts as a checksum.
/// SHA1 is what the server uses to recognise files, not a security measure.
public struct SHA1Stream: Sendable {
    private var hasher = Insecure.SHA1()

    public init() {}

    public mutating func update(_ data: Data) { hasher.update(data: data) }

    public func base64() -> String { Data(hasher.finalize()).base64EncodedString() }
}
