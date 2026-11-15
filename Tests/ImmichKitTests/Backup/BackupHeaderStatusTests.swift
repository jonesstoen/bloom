import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// What the top of the Backup screen says, in priority order.
final class BackupHeaderStatusTests: XCTestCase {
    override func setUp() { Localization.languageOverride = "en" }
    override func tearDown() { Localization.languageOverride = nil }

    private func status(
        enabled: Bool = true, hasSelection: Bool = true, counts: BackupCounts = BackupCounts(),
        checking: BackupModel.Progress? = nil, isScanning: Bool = false, upload: UploadProgress? = nil,
        inFlight: Int = 0, lastBackup: Date? = nil, redirect: Bool = false,
        connection: BackupModel.ConnectionStatus? = nil
    ) -> BackupHeaderStatus {
        BackupHeaderStatus(
            isEnabled: enabled, hasSelection: hasSelection, counts: counts, checking: checking,
            isScanning: isScanning, upload: upload, inFlight: inFlight, lastBackup: lastBackup,
            isRedirectBlocked: redirect, connection: connection, now: Date(timeIntervalSince1970: 1_000_000))
    }

    private let partial = BackupCounts(total: 10, backedUp: 6, pending: 4)

    func testNoAlbumsComesFirst() {
        let s = status(hasSelection: false, counts: partial, redirect: true)
        XCTAssertEqual(s.kind, .noAlbums)
        XCTAssertEqual(s.action, .chooseAlbums)
        XCTAssertEqual(s.fraction, 0)
    }

    func testRedirectBlockBeatsEverythingElse() {
        let s = status(counts: partial, upload: UploadProgress(done: 1, total: 4, currentFilename: nil), redirect: true)
        XCTAssertEqual(s.kind, .stopped)
        XCTAssertEqual(s.title, "Backup Stopped")
    }

    func testCheckingShowsCheckProgress() {
        let s = status(counts: partial, checking: .init(done: 3, total: 12), isScanning: true)
        XCTAssertEqual(s.kind, .checking)
        XCTAssertEqual(s.title, "Checking 3 of 12")
        XCTAssertEqual(s.detail, "6 of 10 backed up")
        XCTAssertEqual(status(isScanning: true).title, "Checking Photos…")
    }

    func testOffOffersToTurnOn() {
        let s = status(enabled: false, counts: partial, upload: UploadProgress(done: 1, total: 4, currentFilename: nil))
        XCTAssertEqual(s.kind, .off)
        XCTAssertEqual(s.action, .turnOn)
        XCTAssertEqual(s.detail, "6 of 10 backed up")
        XCTAssertEqual(s.fraction, 0.6, accuracy: 0.0001)
    }

    func testUploadingNamesTheFileInFlight() {
        let s = status(counts: partial, upload: UploadProgress(done: 3, total: 15, currentFilename: "IMG_1.HEIC"))
        XCTAssertEqual(s.kind, .uploading)
        XCTAssertEqual(s.title, "Uploading 4 of 15")
        XCTAssertEqual(s.detail, "IMG_1.HEIC")
        XCTAssertNil(s.action)
    }

    func testBackgroundUploadsWithoutForegroundRun() {
        let s = status(counts: partial, inFlight: 2)
        XCTAssertEqual(s.kind, .uploading)
        XCTAssertEqual(s.title, "6 of 10 backed up")
        XCTAssertEqual(s.detail, "Uploading in the background: 2")
    }

    func testEverythingBackedUp() {
        let done = BackupCounts(total: 10, backedUp: 9, deletedOnServer: 1)
        let s = status(counts: done, lastBackup: Date(timeIntervalSince1970: 1_000_000 - 7200))
        XCTAssertEqual(s.kind, .upToDate)
        XCTAssertEqual(s.title, "Everything Is Backed Up")
        XCTAssertEqual(s.detail, "Last backup: 2 hours ago")
        XCTAssertEqual(s.fraction, 1)
    }

    func testNeverChecked() {
        XCTAssertEqual(status().kind, .notChecked)
    }

    func testRemainingExplainsWhy() {
        let wifi = BackupCounts(total: 10, backedUp: 6, pending: 4, waitingForWiFi: 4)
        XCTAssertEqual(status(counts: wifi).detail, "4 waiting for Wi-Fi")
        XCTAssertEqual(status(counts: partial, connection: .serverUnreachable).detail, "Can't reach the server.")
        let s = status(counts: partial)
        XCTAssertEqual(s.kind, .remaining)
        XCTAssertEqual(s.title, "6 of 10 backed up")
    }

    func testOnlyProblemsLeft() {
        let s = status(counts: BackupCounts(total: 10, backedUp: 8, failed: 2))
        XCTAssertEqual(s.kind, .problems)
        XCTAssertEqual(s.title, "8 of 10 backed up")
        XCTAssertEqual(s.detail, "2 with problems")
    }
}
