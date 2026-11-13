/// Keeps intermediate scan snapshots from overwhelming the main actor. Final counts bypass this gate.
struct BackupProgressGate {
    private var lastPublished: ContinuousClock.Instant?

    mutating func shouldPublish(at now: ContinuousClock.Instant) -> Bool {
        if let lastPublished, lastPublished.duration(to: now) < .milliseconds(200) { return false }
        lastPublished = now
        return true
    }
}
