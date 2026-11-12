import Foundation

/// Confirmed trash moves and items whose server state could not be established.
/// A failed ID must never be treated as permanently deleted or retried automatically.
public struct TrashResult: Sendable, Equatable {
    public let confirmedIDs: [String]
    public let failedIDs: [String]

    public init(confirmedIDs: [String], failedIDs: [String]) {
        self.confirmedIDs = confirmedIDs
        self.failedIDs = failedIDs
    }
}

public enum TrashError: Error, Sendable, Equatable, LocalizedError {
    case unavailable

    public var errorDescription: String? {
        tr("Moving items to Recently Deleted isn't available on this server.")
    }
}

enum TrashRequestIDs {
    static func validated(_ ids: [String]) throws -> [String] {
        guard ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
            throw ImmichServiceError.invalidResponse
        }
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
