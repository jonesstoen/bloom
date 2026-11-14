import Foundation
import XCTest
@testable import ImmichKit
@testable import ImmichUI

private struct FixedBackupNetwork: NetworkConditions {
    let isOnCellular: Bool
    /// Doesn't observe the network: the stream ends at once.
    func changes() -> AsyncStream<NetworkPath> { AsyncStream { $0.finish() } }
}

@MainActor
final class BackupSelectionPersistenceTests: XCTestCase {
    func testImmediateCancelStillPersistsTheAlbumChoiceWithoutScanning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupCancelSelection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "BackupCancelSelection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let service = MockImmichService()
        let model = BackupModel(source: FakePhotoLibrary(), service: service, directory: directory,
                                network: FixedBackupNetwork(isOnCellular: false), defaults: defaults)
        let choice = BackupSelection(included: ["album-b"])
        model.setSelection(choice)
        model.cancel()
        await model.settle()
        let saved = await BackupIndex(directory: directory).selection()
        XCTAssertEqual(saved, choice)
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty, "Cancel saves the choice without starting a backup check")
        XCTAssertFalse(model.isScanning)
        await model.stop()
    }

    func testUnreadableIndexKeepsNewSelectionAndRetriesSaveOnLoad() async throws {
        Localization.languageOverride = "en"
        defer { Localization.languageOverride = nil }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupSelectionPersistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalSelection = BackupSelection(included: ["album-a"])
        let newSelection = BackupSelection(included: ["album-b"])
        let writer = BackupIndex(directory: directory)
        await writer.setSelection(originalSelection)
        try await writer.save()

        let file = directory.appendingPathComponent("index.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: file.path), "file is readable despite permissions (running as root)")

        let source = FakePhotoLibrary()
        source.addAlbum(id: "album-a", title: "A", assetIDs: [])
        source.addAlbum(id: "album-b", title: "B", assetIDs: [])
        let defaultsName = "BackupSelectionPersistence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
        let service = MockImmichService(library: MockLibrary(assetCount: 1, years: 1))
        let model = BackupModel(
            source: source,
            service: service,
            directory: directory,
            network: FixedBackupNetwork(isOnCellular: false),
            defaults: defaults
        )

        await model.load()
        model.setSelection(newSelection)
        await model.settle()
        XCTAssertEqual(model.selection, newSelection)
        XCTAssertEqual(model.error, "Bloom couldn't open its backup records. Unlock your device and try again.")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        await model.load()
        XCTAssertEqual(model.selection, newSelection, "A saved old choice must not replace the newer UI choice")
        await model.settle()

        let reloaded = await BackupIndex(directory: directory).selection()
        XCTAssertEqual(reloaded, newSelection)
        XCTAssertNil(model.error, "The resolved storage error must disappear after a successful retry")
        await model.stop()
    }
}
