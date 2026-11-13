import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// Models a callback-based reader that finishes with its own error after cancellation.
private actor ReadFailureGate {
    private var read: CheckedContinuation<Void, Error>?
    private var started: CheckedContinuation<Void, Never>?

    func waitForRead() async {
        if read != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func suspendRead() async throws {
        try await withCheckedThrowingContinuation { continuation in
            read = continuation
            started?.resume()
            started = nil
        }
    }

    func fail() {
        read?.resume(throwing: CocoaError(.fileReadUnknown))
        read = nil
    }
}

private struct GatedPhotoLibrary: PhotoLibrarySource {
    let base: FakePhotoLibrary
    let gate: ReadFailureGate

    func authorization() async -> PhotoAccess { await base.authorization() }
    func requestAuthorization() async -> PhotoAccess { await base.requestAuthorization() }
    func albums() async -> [DeviceAlbum] { await base.albums() }
    func assetIDs(inAlbum id: String) async -> Set<String> { await base.assetIDs(inAlbum: id) }
    func asset(_ id: String) async -> DeviceAsset? { await base.asset(id) }
    func assets(_ ids: [String]) async -> [DeviceAsset] { await base.assets(ids) }
    func modificationDates(_ ids: [String]) async -> [String: Date] { await base.modificationDates(ids) }
    func changes() -> AsyncStream<Void> { base.changes() }
    func thumbnailData(_ id: String, pixelSide: Int) async -> Data? { await base.thumbnailData(id, pixelSide: pixelSide) }
    func read(_ resource: DeviceResource, of assetID: String, allowNetwork: Bool,
              onData: @escaping @Sendable (Data) -> Void) async throws {
        if assetID == "b" { try await gate.suspendRead() }
        try await base.read(resource, of: assetID, allowNetwork: allowNetwork, onData: onData)
    }
}

private struct ReadTestNetwork: NetworkConditions { let isOnCellular = false }

@MainActor
final class BackupReadCancellationTests: XCTestCase {
    func testCancelDuringReadDoesNotShowTheReadersErrorAndKeepsEarlierChecksums() async throws {
        try await checkReadFailure(cancel: true)
    }

    func testReadFailureWithoutCancellationStillListsTheProblem() async throws {
        try await checkReadFailure(cancel: false)
    }

    private func checkReadFailure(cancel: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupReadCancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "BackupReadCancel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let library = FakePhotoLibrary()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for id in ["a", "b"] {
            let resource = DeviceResource(type: .photo, filename: "\(id).jpg")
            library.setData([Data(id.utf8)], for: resource)
            library.addAsset(DeviceAsset(id: id, isVideo: false, creationDate: date, modificationDate: date,
                                         isFavorite: false, duration: 0, resources: [resource]))
        }
        library.addAlbum(id: "recents", title: "Recents", assetIDs: ["a", "b"])
        let gate = ReadFailureGate()
        let model = BackupModel(source: GatedPhotoLibrary(base: library, gate: gate),
                                service: MockImmichService(), directory: directory,
                                network: ReadTestNetwork(), defaults: defaults)
        await model.load()
        model.setSelection(BackupSelection(included: ["recents"]))
        await gate.waitForRead()
        if cancel { model.cancel() }
        await gate.fail()
        await model.settle()

        XCTAssertNil(model.error, "Cancelling a resource read is not a failed backup check")
        XCTAssertNil(model.progress)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.counts.total, 2)
        XCTAssertEqual(model.counts.failed, cancel ? 0 : 1)
        XCTAssertEqual(model.failedItems.map(\.id), cancel ? [] : ["b"])
        let saved = BackupIndex(directory: directory)
        let first = await saved.entry(for: "a")
        XCTAssertFalse(try XCTUnwrap(first).checksums.isEmpty, "Earlier checksums survive cancellation")
        let second = await saved.entry(for: "b")
        if cancel { XCTAssertNil(second, "An interrupted read must not become a failed item") }
        await model.stop()
    }
}
