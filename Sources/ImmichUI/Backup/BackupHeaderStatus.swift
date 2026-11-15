import Foundation
import ImmichKit

/// What the top of the Backup screen says: one state, a title, a detail line, how full the ring is and
/// the one button it offers. Pure so the priority order is tested without a view.
struct BackupHeaderStatus: Equatable {
    enum Kind: Equatable {
        case noAlbums, stopped, waitingForBackground, checking, off, uploading, upToDate, notChecked, remaining, problems
    }
    enum Action: Equatable { case chooseAlbums, turnOn }

    var kind: Kind
    var title: String
    var detail: String?
    /// Share of the selection on the server, 0…1.
    var fraction: Double
    var action: Action?

    init(
        isEnabled: Bool, hasSelection: Bool, counts: BackupCounts, checking: BackupModel.Progress?,
        isScanning: Bool, upload: UploadProgress?, inFlight: Int, lastBackup: Date?,
        isRedirectBlocked: Bool, connection: BackupModel.ConnectionStatus?, waitingForBackground: Bool = false,
        now: Date = .now
    ) {
        // Deleted on Server is a choice, not something still to do: leave it out of "x of y".
        let base = counts.backedUp + counts.pending + counts.failed
        let backedUpLine = base > 0 ? tr("%lld of %lld backed up", Int64(counts.backedUp), Int64(base)) : nil
        fraction = base > 0 ? Double(counts.backedUp) / Double(base) : 0
        action = nil
        detail = nil

        if !hasSelection {
            kind = .noAlbums
            title = tr("No Albums Chosen")
            detail = tr("Choose the albums Bloom backs up.")
            fraction = 0
            action = .chooseAlbums
        } else if isRedirectBlocked {
            kind = .stopped
            title = tr("Backup Stopped")
            detail = backedUpLine
        } else if waitingForBackground {
            // The screen's scan or upload run waits its turn: say so instead of "checking" without progress.
            kind = .waitingForBackground
            title = tr("Backing Up in the Background")
            detail = tr("Bloom continues here when that is done.")
        } else if checking != nil || isScanning {
            kind = .checking
            if let checking {
                title = tr("Checking %@ of %@", Self.number(checking.done), Self.number(checking.total))
            } else {
                title = tr("Checking Photos…")
            }
            detail = backedUpLine
        } else if !isEnabled {
            kind = .off
            title = tr("Backup Is Off")
            detail = backedUpLine
            action = .turnOn
        } else if let upload {
            kind = .uploading
            // `done` counts finished items: with a file in flight, that is the next one.
            let current = upload.currentFilename == nil ? upload.done : min(upload.done + 1, upload.total)
            title = tr("Uploading %@ of %@", Self.number(current), Self.number(upload.total))
            detail = upload.currentFilename ?? backedUpLine
        } else if inFlight > 0 {
            kind = .uploading
            title = backedUpLine ?? tr("Backup")
            detail = tr("Uploading in the background: %lld", Int64(inFlight))
        } else if counts.total == 0 {
            kind = .notChecked
            title = tr("Not Checked Yet")
        } else if counts.pending == 0 && counts.failed == 0 {
            kind = .upToDate
            title = tr("Everything Is Backed Up")
            detail = lastBackup.map { tr("Last backup: %@", Self.relative($0, now: now)) }
            fraction = 1
        } else if counts.pending == 0 {
            kind = .problems
            title = backedUpLine ?? ""
            detail = tr("%lld with problems", Int64(counts.failed))
        } else {
            kind = .remaining
            title = backedUpLine ?? ""
            switch connection {
            case .waitingForNetwork: detail = tr("Waiting for a network connection.")
            case .serverUnreachable: detail = tr("Can't reach the server.")
            case nil:
                if counts.waitingForWiFi > 0 {
                    detail = tr("%lld waiting for Wi-Fi", Int64(counts.waitingForWiFi))
                } else {
                    detail = lastBackup.map { tr("Last backup: %@", Self.relative($0, now: now)) }
                }
            }
        }
    }

    /// The SF Symbol in the middle of the ring.
    var symbol: String {
        switch kind {
        case .noAlbums: "photo.stack"
        case .stopped, .problems: "exclamationmark"
        case .waitingForBackground: "hourglass"
        case .checking: "magnifyingglass"
        case .off: "pause.fill"
        case .uploading, .remaining: "arrow.up"
        case .upToDate: "checkmark"
        case .notChecked: "arrow.triangle.2.circlepath"
        }
    }

    private static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Localization.locale))
    }

    /// "2 hours ago", in the app's language.
    static func relative(_ date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Localization.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
