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

    func testCorruptFileIsMovedAsideAndLaterSaveWorks() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("index.json")
        try Data("not json {".utf8).write(to: file)
        let index = BackupIndex(directory: directory)
        let entry = await index.entry(for: "1")
        let selection = await index.selection()
        XCTAssertNil(entry)
        XCTAssertEqual(selection, BackupSelection())
        let aside = directory.appendingPathComponent("index.json.corrupt")
        XCTAssertEqual(try Data(contentsOf: aside), Data("not json {".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await index.set(sampleEntry(), for: "1")
        try await index.save()
        let reloaded = BackupIndex(directory: directory)
        let again = await reloaded.entry(for: "1")
        XCTAssertNotNil(again)
    }

    func testUnreadableFileMakesSaveThrowAndLeavesFileUntouched() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("index.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: file.path), "file is readable despite permissions (running as root)")

        let index = BackupIndex(directory: directory)
        do {
            try await index.saveIfChanged()
            XCTFail("An unchanged unavailable index must still reject a checkpoint")
        } catch BackupIndexError.unavailable {}
        await index.set(sampleEntry(), for: "1")
        let entry = await index.entry(for: "1")
        XCTAssertNotNil(entry) // in-memory edits are allowed, only persisting is blocked
        do {
            try await index.save()
            XCTFail("save should throw while the index is unavailable")
        } catch let error as BackupIndexError {
            XCTAssertEqual(error, .unavailable)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json.corrupt").path))
    }

    func testReloadRecoversOnceTheFileIsReadable() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let writer = BackupIndex(directory: directory)
        await writer.set(sampleEntry(), for: "1")
        try await writer.save()
        let file = directory.appendingPathComponent("index.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: file.path), "file is readable despite permissions (running as root)")

        let index = BackupIndex(directory: directory)
        let before = await index.entry(for: "1")
        XCTAssertNil(before)
        do { try await index.reload(); XCTFail("reload should throw while unreadable") } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try await index.reload()
        let after = await index.entry(for: "1")
        XCTAssertEqual(after, sampleEntry())
        try await index.save()
    }

    func testDirectoryNamedIndexJsonIsUnavailableToo() async throws {
        let directory = makeDirectory()
        let file = directory.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let index = BackupIndex(directory: directory)
        do { try await index.save(); XCTFail("save should throw") } catch BackupIndexError.unavailable {}
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
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
    func testUnchangedCheckpointDoesNotRewriteTheIndex() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        let entry = sampleEntry()
        let selection = BackupSelection(included: ["A"])
        await index.set(entry, for: "1")
        await index.setSelection(selection)
        try await index.save()
        let file = directory.appendingPathComponent("index.json")
        let marker = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: file.path)

        // Repeat scans can write the same server verdict and album selection into the index.
        await index.set(entry, for: "1")
        await index.setSelection(selection)
        try await index.saveIfChanged()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, marker,
                       "An unchanged checkpoint must not rewrite the file")
    }

    func testChangedCheckpointPersistsEntriesAndSelection() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        try await index.save()
        let entry = sampleEntry(state: .pending(reason: .needsUpload))
        let selection = BackupSelection(included: ["B"], excluded: ["A"])
        await index.set(entry, for: "1")
        await index.setSelection(selection)
        try await index.saveIfChanged()
        let reloaded = BackupIndex(directory: directory)
        let savedEntry = await reloaded.entry(for: "1")
        let savedSelection = await reloaded.selection()
        XCTAssertEqual(savedEntry, entry)
        XCTAssertEqual(savedSelection, selection)
    }

    func testFailedCheckpointKeepsChangesForRetry() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        // A regular file blocks creation of the index directory, without permission assumptions.
        try Data("blocker".utf8).write(to: directory)
        let entry = sampleEntry()
        await index.set(entry, for: "1")
        do {
            try await index.saveIfChanged()
            XCTFail("The checkpoint must fail while a file blocks the directory")
        } catch {}
        try FileManager.default.removeItem(at: directory)
        try await index.saveIfChanged()
        let saved = await BackupIndex(directory: directory).entry(for: "1")
        XCTAssertEqual(saved, entry, "A failed write must remain pending for the next checkpoint")
    }

    // MARK: Phase 2: server IDs and deletedOnServer

    func testPhase1IndexLoadsWithEmptyServerIDs() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Exactly what Phase 1 wrote: no `serverIDs` key, one `backedUp` entry.
        let json = """
        {"entries":{"1":{"modificationDate":721692800,"checksums":["photo","aa","pairedVideo","bb"],\
        "state":{"backedUp":{"serverAssetID":"srv-1"}}}},"selection":{"included":["A"],"excluded":[]}}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("index.json"))

        let index = BackupIndex(directory: directory)
        let entry = await index.entry(for: "1")
        let selection = await index.selection()
        XCTAssertEqual(entry, BackupEntry(
            modificationDate: Date(timeIntervalSinceReferenceDate: 721_692_800),
            checksums: [.photo: "aa", .pairedVideo: "bb"],
            state: .backedUp(serverAssetID: "srv-1"),
            serverIDs: [:]
        ))
        XCTAssertEqual(entry?.serverIDs, [:])
        XCTAssertEqual(selection, BackupSelection(included: ["A"]))
        let corrupt = directory.appendingPathComponent("index.json.corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path), "A Phase 1 file must not be treated as corrupt")
    }

    func testServerIDsRoundTrip() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        var entry = sampleEntry()
        entry.serverIDs = [.photo: "p-1", .pairedVideo: "v-1"]
        await index.set(entry, for: "1")
        try await index.save()
        let reloaded = await BackupIndex(directory: directory).entry(for: "1")
        XCTAssertEqual(reloaded, entry)
        XCTAssertEqual(reloaded?.serverIDs[.pairedVideo], "v-1")
    }

    func testDeletedOnServerRoundTrips() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        let entry = sampleEntry(state: .deletedOnServer(trashed: [.photo], gone: [.pairedVideo]))
        await index.set(entry, for: "1")
        try await index.save()
        let reloaded = await BackupIndex(directory: directory).entry(for: "1")
        XCTAssertEqual(reloaded, entry)
        XCTAssertEqual(reloaded?.state, .deletedOnServer(trashed: [.photo], gone: [.pairedVideo]))
    }

    func testCountsAddUpWithDeletedOnServer() {
        var counts = BackupCounts()
        let states: [BackupState] = [
            .backedUp(serverAssetID: "s"),
            .pending(reason: .needsUpload),
            .deletedOnServer(trashed: [.photo], gone: []),
            .failed(reason: "x"),
        ]
        for state in states { counts.add(state) }
        XCTAssertEqual(counts.total, 4)
        XCTAssertEqual(counts.deletedOnServer, 1)
        XCTAssertEqual(counts.total, counts.backedUp + counts.pending + counts.deletedOnServer + counts.failed)
        counts.remove(.deletedOnServer(trashed: [], gone: [.photo]))
        XCTAssertEqual(counts.deletedOnServer, 0)
        XCTAssertEqual(counts.total, 3)
    }

    func testEntriesWhereFiltersInsideTheIndex() async {
        let index = BackupIndex(directory: makeDirectory())
        for n in 0..<10 {
            await index.set(sampleEntry(state: n % 3 == 0 && n < 9 ? .failed(reason: "r\(n)") : .backedUp(serverAssetID: "s\(n)")),
                            for: "\(n)")
        }
        // 0, 3, 6 are failed.
        let ids = Set((0..<10).map(String.init))
        func isFailed(_ e: BackupEntry) -> Bool { if case .failed = e.state { true } else { false } }
        let limited = await index.entries(where: isFailed, in: ids, limit: 2)
        XCTAssertEqual(limited.count, 2)
        XCTAssertTrue(limited.allSatisfy { isFailed($0.1) })
        let all = await index.entries(where: isFailed, in: ids, limit: 100)
        XCTAssertEqual(Set(all.map(\.0)), ["0", "3", "6"])
        let restricted = await index.entries(where: isFailed, in: ["3", "4", "missing"], limit: 100)
        XCTAssertEqual(restricted.map(\.0), ["3"])
    }

    func testConditionalSetWritesOnlyOverTheSameVersion() async throws {
        let directory = makeDirectory()
        let index = BackupIndex(directory: directory)
        let stored = sampleEntry(state: .pending(reason: .needsUpload))
        await index.set(stored, for: "1")
        try await index.save()
        var uploaded = stored
        uploaded.state = .backedUp(serverAssetID: "srv-9")
        uploaded.serverIDs = [.photo: "srv-9", .pairedVideo: "srv-8"]

        // Another version recorded meanwhile (new date, or new checksums): left alone.
        let staleDate = await index.set(uploaded, for: "1", ifModificationDate: stored.modificationDate.addingTimeInterval(1),
                                        checksums: stored.checksums)
        let staleSums = await index.set(uploaded, for: "1", ifModificationDate: stored.modificationDate,
                                        checksums: [.photo: "aa"])
        let missing = await index.set(uploaded, for: "2", ifModificationDate: stored.modificationDate,
                                      checksums: stored.checksums)
        XCTAssertFalse(staleDate)
        XCTAssertFalse(staleSums)
        XCTAssertFalse(missing)
        let unchanged = await index.entry(for: "1")
        XCTAssertEqual(unchanged, stored)
        let noEntry = await index.entry(for: "2")
        XCTAssertNil(noEntry)

        // The same version: written, and marked for the next save.
        let wrote = await index.set(uploaded, for: "1", ifModificationDate: stored.modificationDate, checksums: stored.checksums)
        XCTAssertTrue(wrote)
        let current = await index.entry(for: "1")
        XCTAssertEqual(current, uploaded)
        try await index.saveIfChanged()
        let reloaded = await BackupIndex(directory: directory).entry(for: "1")
        XCTAssertEqual(reloaded, uploaded)
    }
}
