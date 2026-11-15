import XCTest
@testable import ImmichKit

private struct FixedNetwork: NetworkConditions {
    let isOnCellular: Bool
    /// Doesn't observe the network: the stream ends at once.
    func changes() -> AsyncStream<NetworkPath> { AsyncStream { $0.finish() } }
}

private struct ReadFailure: Error, LocalizedError {
    var errorDescription: String? { "disk on fire" }
}

final class BackupScannerTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    // MARK: Helpers

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupScannerTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(url)
        return url
    }

    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func checksum(_ string: String) -> String {
        var sha = SHA1Stream()
        sha.update(Data(string.utf8))
        return sha.base64()
    }

    /// Adds an asset whose resources each contain `"<assetID>/<filename>"` (split in two chunks),
    /// and returns the checksum of each resource.
    @discardableResult
    private func addAsset(
        _ id: String,
        to library: FakePhotoLibrary,
        types: [DeviceResourceType] = [.photo],
        isVideo: Bool = false,
        modified: Date = BackupScannerTests.date
    ) -> [DeviceResourceType: String] {
        var sums: [DeviceResourceType: String] = [:]
        var resources: [DeviceResource] = []
        for type in types {
            let resource = DeviceResource(type: type, filename: "\(id)-\(type.rawValue)")
            let content = "\(id)/\(resource.filename)/\(modified.timeIntervalSince1970)"
            let bytes = Data(content.utf8)
            library.setData([bytes.prefix(3), bytes.dropFirst(3)].map { Data($0) }, for: resource)
            sums[type] = checksum(content)
            resources.append(resource)
        }
        library.addAsset(DeviceAsset(
            id: id, isVideo: isVideo, creationDate: Self.date, modificationDate: modified,
            isFavorite: false, duration: 0, resources: resources))
        return sums
    }

    private func makeLibrary(album ids: Set<String>) -> FakePhotoLibrary {
        let library = FakePhotoLibrary()
        library.addAlbum(id: "A", title: "Recents", assetIDs: ids)
        return library
    }

    /// Gives the asset a new modification date and keeps its bytes, as PhotoKit does when it is made a
    /// favourite, hidden, captioned or moved.
    private func touch(_ id: String, in library: FakePhotoLibrary, modified: Date) async throws {
        let found = await library.asset(id)
        let asset = try XCTUnwrap(found)
        library.addAsset(DeviceAsset(
            id: asset.id, isVideo: asset.isVideo, creationDate: asset.creationDate, modificationDate: modified,
            isFavorite: !asset.isFavorite, duration: asset.duration, resources: asset.resources))
    }

    private func makeIndex(_ directory: URL? = nil) async -> BackupIndex {
        let index = BackupIndex(directory: directory ?? makeDirectory())
        await index.setSelection(BackupSelection(included: ["A"]))
        return index
    }

    private func makeScanner(
        _ library: FakePhotoLibrary,
        _ service: any ImmichService,
        _ index: BackupIndex,
        cellular: Bool = false,
        settings: BackupSettings = BackupSettings()
    ) -> BackupScanner {
        BackupScanner(
            source: library, service: service, index: index,
            network: FixedNetwork(isOnCellular: cellular), settings: settings)
    }

    /// The sizes of the checks that carry checksums. A scan that reads anything sends a one-item
    /// probe first (see `testProbeComesBeforeTheFirstRead`); it is left out here.
    private func checkRequests(_ service: MockImmichService) async -> [Int] {
        await service.requests.compactMap {
            if case let .bulkUploadCheck(count) = $0 { return count } else { return nil }
        }.dropFirst().map { $0 }
    }

    private func allCheckRequests(_ service: MockImmichService) async -> [Int] {
        await service.requests.compactMap {
            if case let .bulkUploadCheck(count) = $0 { return count } else { return nil }
        }
    }

    private func assertInvariant(_ counts: BackupCounts, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(counts.total, counts.backedUp + counts.pending + counts.deletedOnServer + counts.failed, file: file, line: line)
        XCTAssertLessThanOrEqual(counts.waitingForWiFi, counts.pending, file: file, line: line)
    }

    // MARK: Tests

    func testSHA1Base64() {
        XCTAssertEqual(checksum("abc"), "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=")
        var split = SHA1Stream()
        split.update(Data("a".utf8))
        split.update(Data("bc".utf8))
        XCTAssertEqual(split.base64(), "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=")
    }

    func testRecognisesItemsAlreadyOnServer() async throws {
        let library = makeLibrary(album: ["1", "2", "3"])
        let one = addAsset("1", to: library)
        let two = addAsset("2", to: library)
        addAsset("3", to: library)
        let service = MockImmichService()
        await service.setServerChecksums([one[.photo]!, two[.photo]!])
        let index = await makeIndex()

        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        XCTAssertEqual(counts, BackupCounts(total: 3, backedUp: 2, pending: 1, failed: 0, waitingForWiFi: 0))
        let requests = await checkRequests(service)
        XCTAssertEqual(requests, [3])
        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "server-\(one[.photo]!)"))
        XCTAssertEqual(entry?.checksums, one)
        let three = await index.entry(for: "3")
        XCTAssertEqual(three?.state, .pending(reason: .needsUpload))
        let stored = await makeScanner(library, service, index).counts()
        XCTAssertEqual(stored, counts)
    }

    func testProgressIsReportedAfterEachItem() async throws {
        let library = makeLibrary(album: ["1", "2", "3"])
        for id in ["1", "2", "3"] { addAsset(id, to: library) }
        let index = await makeIndex()
        let seen = Box<[Int]>([])

        let counts = try await makeScanner(library, MockImmichService(), index).scan { counts, checked in
            XCTAssertEqual(counts.total, 3)
            XCTAssertEqual(counts.total, counts.backedUp + counts.pending + counts.deletedOnServer + counts.failed)
            seen.mutate { $0.append(checked) }
        }

        XCTAssertEqual(seen.value, [1, 2, 3])
        assertInvariant(counts)
    }

    func testReadingReportsEachItemBeforeItIsHashedAndNotItemsOnlyAskedAgain() async throws {
        let library = makeLibrary(album: ["1", "2", "3"])
        for id in ["1", "2", "3"] { addAsset(id, to: library) }
        let index = await makeIndex()
        let read = Box<[String]>([])
        let readsAtReport = Box<[Int]>([])

        try await makeScanner(library, MockImmichService(), index).scan(reading: { item in
            read.mutate { $0.append(item?.id ?? "end") }
            readsAtReport.mutate { $0.append(library.reads.count) }
        }) { _, _ in }
        XCTAssertEqual(read.value, ["1", "end", "2", "end", "3", "end"])
        XCTAssertEqual(readsAtReport.value, [0, 1, 1, 2, 2, 3], "reported before its own file is read, ended after")

        read.mutate { $0 = [] }
        try await makeScanner(library, MockImmichService(), index).scan(reading: { item in
            read.mutate { $0.append(item?.id ?? "end") }
        }) { _, _ in }
        XCTAssertEqual(read.value, [], "already hashed: only asked about again, nothing read")
    }

    func testUnchangedItemsAreNotRehashedOnTheNextScan() async throws {
        let library = makeLibrary(album: ["1", "2", "3"])
        let one = addAsset("1", to: library)
        addAsset("2", to: library)
        addAsset("3", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setServerChecksums([one[.photo]!])
        let index = await makeIndex()
        let first = try await makeScanner(library, service, index).scan { _, _ in }
        let readsAfterFirst = library.reads.count

        let second = try await makeScanner(library, service, index).scan { _, _ in }

        XCTAssertEqual(readsAfterFirst, 4)
        XCTAssertEqual(library.reads.count, readsAfterFirst, "second scan must not read any resource")
        XCTAssertEqual(second, first)
    }

    func testEditedItemIsRecheckedAndPendingWhenServerLacksNewVersion() async throws {
        let library = makeLibrary(album: ["1"])
        let original = addAsset("1", to: library)
        let service = MockImmichService()
        await service.setServerChecksums([original[.photo]!])
        let index = await makeIndex()
        let first = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(first.backedUp, 1)

        // Edited in Photos: new modification date, and PhotoKit now has the edited full-size file.
        let edited = addAsset("1", to: library, types: [.photo, .fullSizePhoto], modified: Self.date + 60)
        let readsBefore = library.reads.count
        let afterEdit = try await makeScanner(library, service, index).scan { _, _ in }

        XCTAssertEqual(afterEdit, BackupCounts(total: 1, backedUp: 0, pending: 1, failed: 0, waitingForWiFi: 0))
        let newReads = library.reads.dropFirst(readsBefore).map(\.resource.type)
        XCTAssertEqual(newReads, [.fullSizePhoto], "only the policy resource (the edit) is hashed")
        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry?.modificationDate, Self.date + 60)
        XCTAssertEqual(entry?.checksums, [.fullSizePhoto: edited[.fullSizePhoto]!])
        XCTAssertEqual(entry?.state, .pending(reason: .needsUpload))
    }

    func testLivePhotoIsBackedUpOnlyWhenBothResourcesAreOnServer() async throws {
        let library = makeLibrary(album: ["live"])
        let sums = addAsset("live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setServerChecksums([sums[.photo]!])
        let index = await makeIndex()

        let partial = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(partial, BackupCounts(total: 1, backedUp: 0, pending: 1, failed: 0, waitingForWiFi: 0))
        var entry = await index.entry(for: "live")
        XCTAssertEqual(entry?.state, .pending(reason: .needsUpload))
        XCTAssertEqual(entry?.checksums, sums)

        // Only the motion part on the server is not enough either.
        await service.setServerChecksums([sums[.pairedVideo]!])
        let other = BackupIndex(directory: makeDirectory())
        await other.setSelection(BackupSelection(included: ["A"]))
        let videoOnly = try await makeScanner(library, service, other).scan { _, _ in }
        XCTAssertEqual(videoOnly.backedUp, 0)

        // Both: backed up, with the photo's server ID.
        await service.setServerChecksums([sums[.photo]!, sums[.pairedVideo]!])
        let fresh = BackupIndex(directory: makeDirectory())
        await fresh.setSelection(BackupSelection(included: ["A"]))
        let both = try await makeScanner(library, service, fresh).scan { _, _ in }
        XCTAssertEqual(both, BackupCounts(total: 1, backedUp: 1, pending: 0, failed: 0, waitingForWiFi: 0))
        entry = await fresh.entry(for: "live")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "server-\(sums[.photo]!)"))
        let requests = await checkRequests(service)
        XCTAssertEqual(requests.last, 2, "both resources of the Live Photo are checked")
    }

    func testReadFailureMarksFailedAndContinues() async throws {
        let library = makeLibrary(album: ["1", "2", "3"])
        let one = addAsset("1", to: library)
        addAsset("2", to: library)
        addAsset("3", to: library)
        library.failReads(of: DeviceResource(type: .photo, filename: "2-photo"), with: ReadFailure())
        let service = MockImmichService()
        await service.setServerChecksums([one[.photo]!])
        let index = await makeIndex()

        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        XCTAssertEqual(counts, BackupCounts(total: 3, backedUp: 1, pending: 1, failed: 1, waitingForWiFi: 0))
        let entry = await index.entry(for: "2")
        guard case let .failed(reason)? = entry?.state else { return XCTFail("expected failed, got \(String(describing: entry))") }
        XCTAssertFalse(reason.isEmpty)
        let three = await index.entry(for: "3")
        XCTAssertEqual(three?.state, .pending(reason: .needsUpload))
        let requests = await checkRequests(service)
        XCTAssertEqual(requests, [2], "the failed item is not sent to the server")
    }

    func testCellularOffDoesNotAllowNetworkReads() async throws {
        let library = makeLibrary(album: ["photo", "video", "cloud"])
        addAsset("photo", to: library)
        addAsset("video", to: library, types: [.video], isVideo: true)
        addAsset("cloud", to: library)
        library.markICloudOnly(DeviceResource(type: .photo, filename: "cloud-photo"))
        let index = await makeIndex()

        let counts = try await makeScanner(library, MockImmichService(), index, cellular: true).scan { _, _ in }

        XCTAssertFalse(library.reads.isEmpty)
        XCTAssertTrue(library.reads.allSatisfy { !$0.allowNetwork })
        XCTAssertEqual(counts, BackupCounts(total: 3, backedUp: 0, pending: 3, failed: 0, waitingForWiFi: 1))
        let entry = await index.entry(for: "cloud")
        XCTAssertEqual(entry?.state, .pending(reason: .waitingForWiFi))
    }

    func testNetworkReadsFollowTheSwitchForTheMediaType() async throws {
        let library = makeLibrary(album: ["photo", "live", "video"])
        addAsset("photo", to: library)
        addAsset("live", to: library, types: [.photo, .pairedVideo])
        addAsset("video", to: library, types: [.video], isVideo: true)

        let photosOn = await makeIndex()
        _ = try await makeScanner(library, MockImmichService(), photosOn, cellular: true,
                                  settings: BackupSettings(photosOnCellular: true, videosOnCellular: false)).scan { _, _ in }
        var allowed = Dictionary(grouping: library.reads, by: \.assetID).mapValues { $0.allSatisfy(\.allowNetwork) }
        XCTAssertEqual(allowed, ["photo": true, "live": true, "video": false], "a Live Photo counts as a photo")

        let wifi = BackupIndex(directory: makeDirectory())
        await wifi.setSelection(BackupSelection(included: ["A"]))
        let before = library.reads.count
        _ = try await makeScanner(library, MockImmichService(), wifi, cellular: false).scan { _, _ in }
        allowed = Dictionary(grouping: library.reads.dropFirst(before), by: \.assetID).mapValues { $0.allSatisfy(\.allowNetwork) }
        XCTAssertEqual(allowed, ["photo": true, "live": true, "video": true], "off cellular, iCloud downloads are allowed")
    }

    func testCountsInvariant() async throws {
        var ids: Set<String> = []
        let library = FakePhotoLibrary()
        var onServer: Set<String> = []
        for i in 0..<12 { ids.insert("p\(i)"); let s = addAsset("p\(i)", to: library); if i.isMultiple(of: 3) { onServer.insert(s[.photo]!) } }
        for i in 0..<3 { ids.insert("l\(i)"); let s = addAsset("l\(i)", to: library, types: [.photo, .pairedVideo]); if i == 0 { onServer.formUnion(s.values) } }
        ids.insert("cloud"); addAsset("cloud", to: library)
        library.markICloudOnly(DeviceResource(type: .photo, filename: "cloud-photo"))
        ids.insert("broken"); addAsset("broken", to: library)
        library.failReads(of: DeviceResource(type: .photo, filename: "broken-photo"), with: ReadFailure())
        ids.insert("empty"); addAsset("empty", to: library, types: [.other])
        ids.insert("vanished") // in the album, but no longer in the library
        library.addAlbum(id: "A", title: "Recents", assetIDs: ids)
        let service = MockImmichService()
        await service.setServerChecksums(onServer)
        let index = await makeIndex()

        let counts = try await makeScanner(library, service, index, cellular: true).scan { counts, _ in
            XCTAssertEqual(counts.total, counts.backedUp + counts.pending + counts.deletedOnServer + counts.failed)
        }

        assertInvariant(counts)
        XCTAssertEqual(counts, BackupCounts(total: 18, backedUp: 5, pending: 11, failed: 2, waitingForWiFi: 1))
        let empty = await index.entry(for: "empty")
        guard case let .failed(reason)? = empty?.state else { return XCTFail("asset without resources must fail") }
        XCTAssertFalse(reason.isEmpty)
        let vanished = await index.entry(for: "vanished")
        XCTAssertNil(vanished)
        let stored = await makeScanner(library, service, index).counts()
        XCTAssertEqual(stored, counts)
    }

    func testBatchesOf500() async throws {
        let ids = (0..<1_200).map { "a\($0)" }
        let library = makeLibrary(album: Set(ids))
        for id in ids { addAsset(id, to: library) }
        let service = MockImmichService()
        let index = await makeIndex()

        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        XCTAssertEqual(counts.total, 1_200)
        XCTAssertEqual(counts.pending, 1_200)
        let requests = await checkRequests(service)
        XCTAssertEqual(requests, [500, 500, 200])
    }

    func testCancellationSavesProgress() async throws {
        let ids = (0..<10).map { "c\($0)" }
        let library = makeLibrary(album: Set(ids))
        for id in ids { addAsset(id, to: library) }
        let service = MockImmichService()
        let directory = makeDirectory()
        let index = await makeIndex(directory)
        let scanner = makeScanner(library, service, index)

        let task = Task {
            try await scanner.scan { _, checked in
                if checked == 4 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            XCTFail("scan should stop when cancelled")
        } catch is CancellationError {}
        let readsBeforeResume = library.reads
        XCTAssertGreaterThanOrEqual(readsBeforeResume.count, 4)
        XCTAssertLessThan(readsBeforeResume.count, 10)

        // A fresh index from disk proves the progress was saved.
        let reloaded = BackupIndex(directory: directory)
        let counts = try await makeScanner(library, service, reloaded).scan { _, _ in }

        XCTAssertEqual(counts, BackupCounts(total: 10, backedUp: 0, pending: 10, failed: 0, waitingForWiFi: 0))
        let reread = Set(library.reads.dropFirst(readsBeforeResume.count).map(\.assetID))
        XCTAssertTrue(reread.isDisjoint(with: Set(readsBeforeResume.map(\.assetID))), "recorded items are not read again")
        XCTAssertEqual(reread.count + Set(readsBeforeResume.map(\.assetID)).count, 10)
    }

    func testUnavailableIndexStopsTheScan() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("index.json"), withIntermediateDirectories: true)
        let index = await makeIndex(directory)
        let library = makeLibrary(album: ["1"])
        addAsset("1", to: library)

        do {
            _ = try await makeScanner(library, MockImmichService(), index).scan { _, _ in }
            XCTFail("scan must not run on an index that couldn't be read")
        } catch BackupIndexError.unavailable {}
        XCTAssertTrue(library.reads.isEmpty)
    }

    func testProbeComesBeforeTheFirstRead() async throws {
        let library = makeLibrary(album: ["1", "2"])
        addAsset("1", to: library)
        addAsset("2", to: library)
        let service = MockImmichService()
        let index = await makeIndex()

        _ = try await makeScanner(library, service, index).scan { _, _ in }

        let requests = await allCheckRequests(service)
        XCTAssertEqual(requests, [1, 2], "one probe, then the checksums")
    }

    func testRejectedKeyFailsBeforeAnythingIsRead() async throws {
        let library = makeLibrary(album: ["1", "2", "3"])
        for id in ["1", "2", "3"] { addAsset(id, to: library) }
        let service = MockImmichService()
        await service.setFailure(.unauthorized)
        let index = await makeIndex()

        do {
            _ = try await makeScanner(library, service, index).scan { _, _ in }
            XCTFail("a key that can't check backups must stop the scan")
        } catch ImmichServiceError.unauthorized {}
        XCTAssertTrue(library.reads.isEmpty, "nothing is read or hashed before the probe passes")
        let requests = await allCheckRequests(service)
        XCTAssertEqual(requests, [1])
    }

    func testNothingToReadSendsNoProbe() async throws {
        let library = makeLibrary(album: ["1"])
        let sums = addAsset("1", to: library)
        let service = MockImmichService()
        let index = await makeIndex()
        _ = try await makeScanner(library, service, index).scan { _, _ in }
        await service.setServerChecksums([sums[.photo]!])
        let before = await allCheckRequests(service).count

        _ = try await makeScanner(library, service, index).scan { _, _ in } // already hashed
        let after = await allCheckRequests(service).count
        XCTAssertEqual(after - before, 1, "only the checksum request, no probe")

        let empty = makeLibrary(album: [])
        let none = MockImmichService()
        _ = try await makeScanner(empty, none, await makeIndex()).scan { _, _ in }
        let requests = await allCheckRequests(none)
        XCTAssertEqual(requests, [])
    }

    func testConcurrentScansShareOneRun() async throws {
        let library = makeLibrary(album: ["1", "2", "3"])
        for id in ["1", "2", "3"] { addAsset(id, to: library) }
        let service = MockImmichService(latency: .milliseconds(200))
        let scanner = makeScanner(library, service, await makeIndex())

        async let first = scanner.scan { _, _ in }
        async let second = scanner.scan { _, _ in }
        let (a, b) = try await (first, second)

        XCTAssertEqual(a, b)
        XCTAssertEqual(library.reads.count, 3, "each resource is read once")
        let requests = await checkRequests(service)
        XCTAssertEqual(requests, [3])
    }

    func testStaleVerdictIsNotApplied() async throws {
        let library = makeLibrary(album: ["1"])
        let v1 = addAsset("1", to: library)
        let service = MockImmichService(latency: .milliseconds(300))
        await service.setServerChecksums([v1[.photo]!])
        let index = await makeIndex()
        let scanner = makeScanner(library, service, index)

        let task = Task { try await scanner.scan { _, _ in } }
        // While the server is answering for v1, the entry moves on to an edited version.
        while await checkRequests(service).isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let edited = BackupEntry(
            modificationDate: Self.date + 60, checksums: [.photo: "v2"], state: .pending(reason: .notChecked))
        await index.set(edited, for: "1")
        _ = try await task.value

        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry, edited, "v1's verdict must not land on v2")
    }

    func testNeedsUploadIsRecheckedWithoutReading() async throws {
        let library = makeLibrary(album: ["1"])
        let sums = addAsset("1", to: library)
        let service = MockImmichService()
        let index = await makeIndex()
        let first = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(first.pending, 1)
        let reads = library.reads.count

        await service.setServerChecksums([sums[.photo]!]) // uploaded from elsewhere meanwhile
        let second = try await makeScanner(library, service, index).scan { _, _ in }

        XCTAssertEqual(second, BackupCounts(total: 1, backedUp: 1, pending: 0, failed: 0, waitingForWiFi: 0))
        XCTAssertEqual(library.reads.count, reads)
        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "server-\(sums[.photo]!)"))
    }

    func testLivePhotoPairIsNeverSplitAcrossRequests() async throws {
        let ids = (0..<499).map { String(format: "a%03d", $0) }
        let library = makeLibrary(album: Set(ids + ["z-live"]))
        for id in ids { addAsset(id, to: library) }
        addAsset("z-live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()

        _ = try await makeScanner(library, service, await makeIndex()).scan { _, _ in }

        let requests = await checkRequests(service)
        XCTAssertEqual(requests, [499, 2])
    }

    func testAssetsAreFetchedInBatchesAndCountsReadNoResources() async throws {
        let ids = (0..<1_200).map { "a\($0)" }
        let library = makeLibrary(album: Set(ids))
        for id in ids { addAsset(id, to: library) }
        let index = await makeIndex()
        let scanner = makeScanner(library, MockImmichService(), index)

        let scanned = try await scanner.scan { _, _ in }
        XCTAssertEqual(library.batchLookups, [500, 500, 200])
        XCTAssertEqual(library.singleLookups, 0)

        let counted = await scanner.counts()
        XCTAssertEqual(counted, scanned)
        XCTAssertEqual(library.batchLookups, [500, 500, 200], "counts() fetches no resources")
        XCTAssertEqual(library.dateLookups, [500, 500, 200])
    }

    func testServerErrorKeepsChecksumsForTheNextScan() async throws {
        let library = makeLibrary(album: ["1", "2"])
        let one = addAsset("1", to: library)
        addAsset("2", to: library)
        let service = MockImmichService()
        await service.setBulkUploadFailure(.unauthorized, afterCalls: 1) // the probe passes
        let index = await makeIndex()

        do {
            _ = try await makeScanner(library, service, index).scan { _, _ in }
            XCTFail("a failed server check must surface")
        } catch {}
        let reads = library.reads.count
        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry?.state, .pending(reason: .notChecked))

        await service.setBulkUploadFailure(nil)
        await service.setServerChecksums([one[.photo]!])
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        XCTAssertEqual(library.reads.count, reads, "hashed items are checked again without rereading")
        XCTAssertEqual(counts, BackupCounts(total: 2, backedUp: 1, pending: 1, failed: 0, waitingForWiFi: 0))
    }

    // MARK: Re-checking what is on the server (Phase 2, option C)

    func testBackedUpItemsAreRecheckedWithoutReads() async throws {
        let library = makeLibrary(album: ["1", "2", "live"])
        let one = addAsset("1", to: library)
        let two = addAsset("2", to: library)
        let live = addAsset("live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setServerChecksums(Set(one.values).union(two.values).union(live.values))
        let index = await makeIndex()
        let first = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(first.backedUp, 3)
        let reads = library.reads.count
        let before = await allCheckRequests(service).count

        let second = try await makeScanner(library, service, index).scan { _, _ in }

        XCTAssertEqual(library.reads.count, reads, "backed-up items are re-checked from their stored checksums")
        let requests = await allCheckRequests(service).dropFirst(before)
        XCTAssertEqual(Array(requests), [4], "one request with every stored checksum, no probe")
        XCTAssertEqual(second, first)
        let entry = await index.entry(for: "live")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "server-\(live[.photo]!)"))
        XCTAssertEqual(entry?.serverIDs, [.photo: "server-\(live[.photo]!)", .pairedVideo: "server-\(live[.pairedVideo]!)"])
    }

    func testPurgedOnServerBecomesDeletedOnServer() async throws {
        let library = makeLibrary(album: ["1"])
        let sums = addAsset("1", to: library)
        let service = MockImmichService()
        await service.setServerChecksums([sums[.photo]!])
        let index = await makeIndex()
        _ = try await makeScanner(library, service, index).scan { _, _ in }

        await service.setServerChecksums([]) // deleted and purged on the server
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts, BackupCounts(total: 1, backedUp: 0, pending: 0, failed: 0, deletedOnServer: 1, waitingForWiFi: 0))
        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry?.state, .deletedOnServer(trashed: [], gone: [.photo]))
        XCTAssertEqual(entry?.serverIDs, [:], "a gone copy's ID is not kept")
        XCTAssertEqual(entry?.checksums, sums)
        let stored = await makeScanner(library, service, index).counts()
        XCTAssertEqual(stored, counts)
    }

    func testTrashedOnServerBecomesDeletedOnServerTrashed() async throws {
        let library = makeLibrary(album: ["1"])
        let sums = addAsset("1", to: library)
        let mock = MockImmichService()
        await mock.setServerChecksums([sums[.photo]!])
        let service = mock
        let index = await makeIndex()
        let first = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(first.backedUp, 1)

        await mock.setTrashedChecksums([sums[.photo]!]) // moved to the trash on the server
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts, BackupCounts(total: 1, backedUp: 0, pending: 0, failed: 0, deletedOnServer: 1, waitingForWiFi: 0))
        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry?.state, .deletedOnServer(trashed: [.photo], gone: []))
        XCTAssertEqual(entry?.serverIDs, [.photo: "server-\(sums[.photo]!)"], "the trashed copy's ID is kept for restoring")
    }

    func testDeletedItemRestoredOnServerBecomesBackedUpAgain() async throws {
        let library = makeLibrary(album: ["1", "2"])
        let one = addAsset("1", to: library)
        let two = addAsset("2", to: library)
        let mock = MockImmichService()
        await mock.setServerChecksums([one[.photo]!, two[.photo]!])
        let service = mock
        let index = await makeIndex()
        _ = try await makeScanner(library, service, index).scan { _, _ in }
        let reads = library.reads.count

        // "1" goes to the server's trash, "2" is purged.
        await mock.setTrashedChecksums([one[.photo]!])
        await mock.setServerChecksums([one[.photo]!])
        let deleted = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(deleted.deletedOnServer, 2)

        // Restored in the web app, and uploaded again from another device.
        await mock.setTrashedChecksums([])
        await mock.setServerChecksums([one[.photo]!, two[.photo]!])
        let restored = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(restored)
        XCTAssertEqual(restored, BackupCounts(total: 2, backedUp: 2, pending: 0, failed: 0, deletedOnServer: 0, waitingForWiFi: 0))
        XCTAssertEqual(library.reads.count, reads, "nothing is read again")
        let entry = await index.entry(for: "2")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "server-\(two[.photo]!)"))
        XCTAssertEqual(entry?.serverIDs, [.photo: "server-\(two[.photo]!)"])
    }

    func testLivePhotoWithMotionGoneIsDeletedOnServerGoneMotion() async throws {
        let library = makeLibrary(album: ["live"])
        let sums = addAsset("live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setServerChecksums([sums[.photo]!, sums[.pairedVideo]!])
        let index = await makeIndex()
        let first = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(first.backedUp, 1)

        await service.setServerChecksums([sums[.photo]!]) // the motion video was purged
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts.deletedOnServer, 1)
        let entry = await index.entry(for: "live")
        guard case let .deletedOnServer(trashed, gone)? = entry?.state else {
            return XCTFail("expected deletedOnServer, got \(String(describing: entry?.state))")
        }
        XCTAssertEqual(gone, [.pairedVideo])
        XCTAssertEqual(trashed, [])
        XCTAssertEqual(entry?.serverIDs, [.photo: "server-\(sums[.photo]!)"], "the photo still on the server keeps its ID")
    }

    func testNeverSeenAndAcceptedIsNeedsUploadNotDeleted() async throws {
        let library = makeLibrary(album: ["1", "live"])
        addAsset("1", to: library)
        let live = addAsset("live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setServerChecksums([live[.photo]!]) // only the photo half is on the server
        let index = await makeIndex()

        let first = try await makeScanner(library, service, index).scan { _, _ in }
        let second = try await makeScanner(library, service, index).scan { _, _ in }

        for counts in [first, second] {
            assertInvariant(counts)
            XCTAssertEqual(counts, BackupCounts(total: 2, backedUp: 0, pending: 2, failed: 0, deletedOnServer: 0, waitingForWiFi: 0))
        }
        let one = await index.entry(for: "1")
        XCTAssertEqual(one?.state, .pending(reason: .needsUpload))
        let entry = await index.entry(for: "live")
        XCTAssertEqual(entry?.state, .pending(reason: .needsUpload))
        XCTAssertEqual(entry?.serverIDs, [.photo: "server-\(live[.photo]!)"], "the half the server has is remembered")
    }

    /// Replaces Phase 1's rule that a trashed duplicate counts as on the server.
    func testFirstCheckFindsTrashedCopyIsDeletedOnServer() async throws {
        let library = makeLibrary(album: ["1"])
        let sums = addAsset("1", to: library)
        let mock = MockImmichService()
        await mock.setServerChecksums([sums[.photo]!])
        let service = mock
        await mock.setTrashedChecksums([sums[.photo]!])
        let index = await makeIndex()

        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts, BackupCounts(total: 1, backedUp: 0, pending: 0, failed: 0, deletedOnServer: 1, waitingForWiFi: 0))
        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry?.state, .deletedOnServer(trashed: [.photo], gone: []))
        XCTAssertEqual(entry?.serverIDs, [.photo: "server-\(sums[.photo]!)"])
    }

    func testEditedDeletedItemBecomesNeedsUpload() async throws {
        let library = makeLibrary(album: ["1"])
        let original = addAsset("1", to: library)
        let service = MockImmichService()
        await service.setServerChecksums([original[.photo]!])
        let index = await makeIndex()
        _ = try await makeScanner(library, service, index).scan { _, _ in }
        await service.setServerChecksums([])
        let deleted = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(deleted.deletedOnServer, 1)

        // Edited on the phone: a new version, not the one deleted on the server.
        let edited = addAsset("1", to: library, modified: Self.date + 60)
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts, BackupCounts(total: 1, backedUp: 0, pending: 1, failed: 0, deletedOnServer: 0, waitingForWiFi: 0))
        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry?.state, .pending(reason: .needsUpload))
        XCTAssertEqual(entry?.checksums, edited)
    }

    /// A favourite, hide, caption or location change bumps the date but not the bytes: the item deleted
    /// on the server stays deleted there and is not queued for upload.
    func testDateOnlyChangeKeepsDeletedOnServer() async throws {
        let library = makeLibrary(album: ["1"])
        let sums = addAsset("1", to: library)
        let service = MockImmichService()
        await service.setServerChecksums([sums[.photo]!])
        let index = await makeIndex()
        _ = try await makeScanner(library, service, index).scan { _, _ in }
        await service.setServerChecksums([]) // purged on the server
        let deleted = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(deleted.deletedOnServer, 1)

        try await touch("1", in: library, modified: Self.date + 60)
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts, BackupCounts(total: 1, backedUp: 0, pending: 0, failed: 0, deletedOnServer: 1, waitingForWiFi: 0))
        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry?.state, .deletedOnServer(trashed: [], gone: [.photo]))
        XCTAssertEqual(entry?.checksums, sums)
        XCTAssertEqual(entry?.modificationDate, Self.date + 60)
        let stored = await makeScanner(library, service, index).counts()
        XCTAssertEqual(stored, counts)

        // Nothing is queued: an upload run sends nothing.
        let directory = makeDirectory()
        let uploader = BackupUploader(
            source: library, service: service, index: index,
            staging: BackupStaging(directory: directory, freeSpace: { 100 * 1024 * 1024 * 1024 }),
            settings: { BackupSettings() }, network: FixedNetwork(isOnCellular: false))
        try await uploader.run(progress: { _ in }, shouldPause: { false })
        let uploads = await service.uploads
        XCTAssertEqual(uploads.count, 0)
    }

    /// A date-only change to a backed-up item keeps what the scanner knew, even when the server's answer
    /// for it is missing this time.
    func testDateOnlyChangeKeepsBackedUpWithItsServerIDs() async throws {
        let library = makeLibrary(album: ["live"])
        let sums = addAsset("live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setServerChecksums([sums[.photo]!, sums[.pairedVideo]!])
        let index = await makeIndex()
        let first = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(first.backedUp, 1)
        let before = await index.entry(for: "live")
        let serverIDs = [DeviceResourceType.photo: "server-\(sums[.photo]!)", .pairedVideo: "server-\(sums[.pairedVideo]!)"]
        XCTAssertEqual(before?.serverIDs, serverIDs)

        try await touch("live", in: library, modified: Self.date + 60)
        await service.setUnansweredChecksums([sums[.photo]!]) // no verdict this time
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts, BackupCounts(total: 1, backedUp: 1, pending: 0, failed: 0, deletedOnServer: 0, waitingForWiFi: 0))
        let entry = await index.entry(for: "live")
        XCTAssertEqual(entry?.state, .backedUp(serverAssetID: "server-\(sums[.photo]!)"))
        XCTAssertEqual(entry?.serverIDs, serverIDs)
        XCTAssertEqual(entry?.checksums, sums)
        XCTAssertEqual(entry?.modificationDate, Self.date + 60)
    }

    /// The uploader records `backedUp` while the scanner's check for the item's earlier state is on its
    /// way: the older answer must not turn it into deleted on the server.
    func testVerdictForAnEarlierStateIsNotApplied() async throws {
        let library = makeLibrary(album: ["1"])
        let sums = addAsset("1", to: library)
        let service = MockImmichService()
        let index = await makeIndex()
        _ = try await makeScanner(library, service, index).scan { _, _ in }
        let queued = await index.entry(for: "1")
        XCTAssertEqual(queued?.state, .pending(reason: .needsUpload))
        let checksBefore = await allCheckRequests(service).count

        await service.setLatency(.milliseconds(300))
        let scanner = makeScanner(library, service, index)
        let task = Task { try await scanner.scan { _, _ in } }
        // While the server answers "accept" for the queued item, the uploader finishes it.
        while await allCheckRequests(service).count == checksBefore { try await Task.sleep(for: .milliseconds(5)) }
        let uploaded = BackupEntry(
            modificationDate: Self.date, checksums: sums, state: .backedUp(serverAssetID: "U"), serverIDs: [.photo: "U"])
        await index.set(uploaded, for: "1")
        _ = try await task.value

        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry, uploaded, "the answer for needsUpload must not land on backedUp")
    }

    func testRecheckOf1300BackedUpSendsThreeBatchedRequests() async throws {
        let ids = (0..<1_300).map { "a\($0)" }
        let library = makeLibrary(album: Set(ids))
        var sums: Set<String> = []
        for id in ids { sums.formUnion(addAsset(id, to: library).values) }
        let service = MockImmichService()
        await service.setServerChecksums(sums)
        let index = await makeIndex()
        let first = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(first.backedUp, 1_300)
        let reads = library.reads.count
        let before = await allCheckRequests(service).count

        let second = try await makeScanner(library, service, index).scan { _, _ in }

        let requests = await allCheckRequests(service).dropFirst(before)
        XCTAssertEqual(Array(requests), [500, 500, 300])
        XCTAssertEqual(library.reads.count, reads)
        XCTAssertEqual(second, first)
    }

    // MARK: Re-check edge cases (fix round 1)

    /// A Phase 1 index entry: backed up, no per-resource IDs (a trashed copy then counted as on the server).
    private func phase1Entry(_ sums: [DeviceResourceType: String]) -> BackupEntry {
        BackupEntry(modificationDate: Self.date, checksums: sums, state: .backedUp(serverAssetID: "server-\(sums[.photo]!)"))
    }

    func testPhase1EntryIsCorrectedByTheNextRecheck() async throws {
        let library = makeLibrary(album: ["kept", "trashed", "purged"])
        let kept = addAsset("kept", to: library)
        let trashed = addAsset("trashed", to: library)
        let purged = addAsset("purged", to: library)
        let index = await makeIndex()
        for (id, sums) in [("kept", kept), ("trashed", trashed), ("purged", purged)] {
            await index.set(phase1Entry(sums), for: id)
        }
        let service = MockImmichService()
        await service.setServerChecksums([kept[.photo]!])
        await service.setTrashedChecksums([trashed[.photo]!])

        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts, BackupCounts(total: 3, backedUp: 1, pending: 0, failed: 0, deletedOnServer: 2, waitingForWiFi: 0))
        XCTAssertTrue(library.reads.isEmpty, "Phase 1 checksums are reused")
        let keptEntry = await index.entry(for: "kept")
        XCTAssertEqual(keptEntry?.state, .backedUp(serverAssetID: "server-\(kept[.photo]!)"))
        XCTAssertEqual(keptEntry?.serverIDs, [.photo: "server-\(kept[.photo]!)"], "IDs filled in")
        let trashedEntry = await index.entry(for: "trashed")
        XCTAssertEqual(trashedEntry?.state, .deletedOnServer(trashed: [.photo], gone: []))
        XCTAssertEqual(trashedEntry?.serverIDs, [.photo: "server-\(trashed[.photo]!)"])
        let purgedEntry = await index.entry(for: "purged")
        XCTAssertEqual(purgedEntry?.state, .deletedOnServer(trashed: [], gone: [.photo]))
        XCTAssertEqual(purgedEntry?.serverIDs, [:])
    }

    func testLivePhotoWithOneHalfTrashedAndTheOtherGone() async throws {
        let library = makeLibrary(album: ["live"])
        let sums = addAsset("live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setServerChecksums(Set(sums.values))
        let index = await makeIndex()
        _ = try await makeScanner(library, service, index).scan { _, _ in }

        await service.setServerChecksums([])
        await service.setTrashedChecksums([sums[.photo]!]) // photo in the trash, motion purged
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts.deletedOnServer, 1)
        let entry = await index.entry(for: "live")
        XCTAssertEqual(entry?.state, .deletedOnServer(trashed: [.photo], gone: [.pairedVideo]))
        XCTAssertEqual(entry?.serverIDs, [.photo: "server-\(sums[.photo]!)"])
    }

    func testMissingAnswerKeepsSeenStateAndResetsNeverSeen() async throws {
        let library = makeLibrary(album: ["seen", "new"])
        let seen = addAsset("seen", to: library)
        let new = addAsset("new", to: library)
        let service = MockImmichService()
        await service.setServerChecksums([seen[.photo]!])
        let index = await makeIndex()
        _ = try await makeScanner(library, service, index).scan { _, _ in }
        let newBefore = await index.entry(for: "new")
        XCTAssertEqual(newBefore?.state, .pending(reason: .needsUpload))

        await service.setServerChecksums([])
        await service.setUnansweredChecksums([seen[.photo]!, new[.photo]!])
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        let seenEntry = await index.entry(for: "seen")
        XCTAssertEqual(seenEntry?.state, .backedUp(serverAssetID: "server-\(seen[.photo]!)"), "no answer is no news")
        XCTAssertEqual(seenEntry?.serverIDs, [.photo: "server-\(seen[.photo]!)"])
        let newEntry = await index.entry(for: "new")
        XCTAssertEqual(newEntry?.state, .pending(reason: .notChecked))
    }

    func testNeedsUploadItemFoundTrashedBecomesDeletedOnServer() async throws {
        let library = makeLibrary(album: ["1"])
        let sums = addAsset("1", to: library)
        let service = MockImmichService()
        let index = await makeIndex()
        let first = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(first.pending, 1)

        await service.setTrashedChecksums([sums[.photo]!]) // uploaded elsewhere, then trashed
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts, BackupCounts(total: 1, backedUp: 0, pending: 0, failed: 0, deletedOnServer: 1, waitingForWiFi: 0))
        let entry = await index.entry(for: "1")
        XCTAssertEqual(entry?.state, .deletedOnServer(trashed: [.photo], gone: []))
    }

    func testHalfSeenLivePhotoPurgedOnServerBecomesDeletedOnServer() async throws {
        let library = makeLibrary(album: ["live"])
        let sums = addAsset("live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setServerChecksums([sums[.photo]!]) // only the photo half was ever on the server
        let index = await makeIndex()
        _ = try await makeScanner(library, service, index).scan { _, _ in }
        let steady = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(steady.pending, 1, "the missing motion alone doesn't make it deleted")

        await service.setServerChecksums([]) // the photo half is purged
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts, BackupCounts(total: 1, backedUp: 0, pending: 0, failed: 0, deletedOnServer: 1, waitingForWiFi: 0))
        let entry = await index.entry(for: "live")
        XCTAssertEqual(entry?.state, .deletedOnServer(trashed: [], gone: [.photo, .pairedVideo]))
        XCTAssertEqual(entry?.serverIDs, [:])
    }

    func testUnsupportedFormatGivesNoVerdictForSeenAndNeedsUploadForNeverSeen() async throws {
        let library = makeLibrary(album: ["seen", "new"])
        let seen = addAsset("seen", to: library)
        let new = addAsset("new", to: library)
        let service = MockImmichService()
        await service.setServerChecksums([seen[.photo]!])
        let index = await makeIndex()
        _ = try await makeScanner(library, service, index).scan { _, _ in }

        await service.setServerChecksums([])
        await service.setRejectedChecksums([seen[.photo]!, new[.photo]!])
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts.deletedOnServer, 0, "a rejection is not a deletion")
        let seenEntry = await index.entry(for: "seen")
        XCTAssertEqual(seenEntry?.state, .backedUp(serverAssetID: "server-\(seen[.photo]!)"))
        XCTAssertEqual(seenEntry?.serverIDs, [.photo: "server-\(seen[.photo]!)"])
        let newEntry = await index.entry(for: "new")
        XCTAssertEqual(newEntry?.state, .pending(reason: .needsUpload))
    }

    // MARK: Rejections next to other answers (fix round 2)

    func testHalfSeenLivePhotoWithRejectedHalfStaysNeedsUpload() async throws {
        let library = makeLibrary(album: ["live"])
        let sums = addAsset("live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setServerChecksums([sums[.photo]!])
        await service.setRejectedChecksums([sums[.pairedVideo]!])
        let index = await makeIndex()

        _ = try await makeScanner(library, service, index).scan { _, _ in }
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts, BackupCounts(total: 1, backedUp: 0, pending: 1, failed: 0, deletedOnServer: 0, waitingForWiFi: 0))
        let entry = await index.entry(for: "live")
        XCTAssertEqual(entry?.state, .pending(reason: .needsUpload), "left to the uploader, which reports the refusal")
        XCTAssertEqual(entry?.serverIDs, [.photo: "server-\(sums[.photo]!)"])
    }

    func testTrashedAndRejectedSeenItemIsDeletedOnServer() async throws {
        let library = makeLibrary(album: ["live"])
        let sums = addAsset("live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setServerChecksums(Set(sums.values))
        let index = await makeIndex()
        let first = try await makeScanner(library, service, index).scan { _, _ in }
        XCTAssertEqual(first.backedUp, 1)

        await service.setServerChecksums([])
        await service.setTrashedChecksums([sums[.photo]!])
        await service.setRejectedChecksums([sums[.pairedVideo]!])
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts.deletedOnServer, 1)
        let entry = await index.entry(for: "live")
        XCTAssertEqual(entry?.state, .deletedOnServer(trashed: [.photo], gone: []))
    }

    func testTrashedAndRejectedNeverSeenItemIsDeletedOnServer() async throws {
        let library = makeLibrary(album: ["live"])
        let sums = addAsset("live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setTrashedChecksums([sums[.photo]!])
        await service.setRejectedChecksums([sums[.pairedVideo]!])
        let index = await makeIndex()

        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        XCTAssertEqual(counts.deletedOnServer, 1)
        let entry = await index.entry(for: "live")
        XCTAssertEqual(entry?.state, .deletedOnServer(trashed: [.photo], gone: []))
        XCTAssertEqual(entry?.serverIDs, [.photo: "server-\(sums[.photo]!)"])
    }

    func testHalfSeenPurgedAndRejectedIsDeletedOnServer() async throws {
        let library = makeLibrary(album: ["live"])
        let sums = addAsset("live", to: library, types: [.photo, .pairedVideo])
        let service = MockImmichService()
        await service.setServerChecksums([sums[.photo]!])
        await service.setRejectedChecksums([sums[.pairedVideo]!])
        let index = await makeIndex()
        _ = try await makeScanner(library, service, index).scan { _, _ in }

        await service.setServerChecksums([]) // the photo half Bloom saw is purged
        let counts = try await makeScanner(library, service, index).scan { _, _ in }

        assertInvariant(counts)
        let entry = await index.entry(for: "live")
        XCTAssertEqual(entry?.state, .deletedOnServer(trashed: [], gone: [.photo]), "a seen half is never re-uploaded on its own")
    }
}

/// A tiny locked box for collecting values from `@Sendable` closures.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}
