import XCTest
@testable import ImmichKit

final class BackupIndexTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupIndexTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(url)
        return url
    }

    private func sampleEntry(state: BackupState = .backedUp(serverAssetID: "srv-1")) -> BackupEntry {
        BackupEntry(
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            checksums: [.photo: "aa", .pairedVideo: "bb"],
            state: state
        )
    }

    func testRoundTripThroughSaveAndNewIndex() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        await index.set(sampleEntry(), for: "1")
        await index.set(sampleEntry(state: .pending(reason: .waitingForWiFi)), for: "2")
        await index.set(sampleEntry(state: .failed(reason: "boom")), for: "3")
        await index.setSelection(BackupSelection(included: ["A"], excluded: ["B"]))
        try await index.save()

        let reloaded = BackupIndex(directory: directory)
        let one = await reloaded.entry(for: "1")
        let two = await reloaded.entry(for: "2")
        let three = await reloaded.entry(for: "3")
        let selection = await reloaded.selection()
        XCTAssertEqual(one, sampleEntry())
        XCTAssertEqual(two?.state, .pending(reason: .waitingForWiFi))
        XCTAssertEqual(three?.state, .failed(reason: "boom"))
        XCTAssertEqual(selection, BackupSelection(included: ["A"], excluded: ["B"]))
    }

    func testUnsavedChangesAreNotPersisted() async {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        await index.set(sampleEntry(), for: "1")
        let other = BackupIndex(directory: directory)
        let entry = await other.entry(for: "1")
        XCTAssertNil(entry)
    }

    func testClearRemovesFileAndEntries() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        await index.set(sampleEntry(), for: "1")
        try await index.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path))
        await index.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path))
        let entry = await index.entry(for: "1")
        XCTAssertNil(entry)
        let reloaded = BackupIndex(directory: directory)
        let again = await reloaded.entry(for: "1")
        XCTAssertNil(again)
    }

    func testDirectoriesAreIsolated() async throws {
        let a = BackupIndex(directory: makeDirectory())
        let b = BackupIndex(directory: makeDirectory())
        await a.set(sampleEntry(), for: "1")
        try await a.save()
        let entry = await b.entry(for: "1")
        XCTAssertNil(entry)
    }

    func testCorruptFileLoadsAsEmpty() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json {".utf8).write(to: directory.appendingPathComponent("index.json"))
        let index = BackupIndex(directory: directory)
        let entry = await index.entry(for: "1")
        let selection = await index.selection()
        XCTAssertNil(entry)
        XCTAssertEqual(selection, BackupSelection())
        await index.set(sampleEntry(), for: "1")
        try await index.save()
        let reloaded = BackupIndex(directory: directory)
        let again = await reloaded.entry(for: "1")
        XCTAssertNotNil(again)
    }

    func testSavedFileIsProtectedOnIOS() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        await index.set(sampleEntry(), for: "1")
        try await index.save()
        let file = directory.appendingPathComponent("index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        #if os(iOS)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        #endif
    }
}
