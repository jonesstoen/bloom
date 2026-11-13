import Foundation

/// The outcome of a write that affects several assets (move to trash, restore).
///
/// `confirmedIDs` are the assets whose new server state is confirmed. `failedIDs` are the ones
/// whose state could not be established: never treat them as done (for trash: never as
/// permanently deleted) and never retry them automatically.
public struct WriteResult: Sendable, Equatable {
    public let confirmedIDs: [String]
    public let failedIDs: [String]

    public init(confirmedIDs: [String], failedIDs: [String]) {
        self.confirmedIDs = confirmedIDs
        self.failedIDs = failedIDs
    }
}

/// Confirmed trash moves and items whose server state could not be established.
public typealias TrashResult = WriteResult

/// Only identities whose current server state confirms restoration are successful.
public typealias RestoreResult = WriteResult

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
