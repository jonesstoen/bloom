/// Only identities whose current server state confirms restoration are successful.
public struct RestoreResult: Sendable, Equatable {
    public let confirmedIDs: [String]
    public let failedIDs: [String]

    public init(confirmedIDs: [String], failedIDs: [String]) {
        self.confirmedIDs = confirmedIDs
        self.failedIDs = failedIDs
    }
}
