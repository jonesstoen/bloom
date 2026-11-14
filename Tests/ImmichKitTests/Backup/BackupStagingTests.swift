import XCTest
@testable import ImmichKit

private struct StagingReadFailure: Error, LocalizedError {
    var errorDescription: String? { "disk on fire" }
}

/// A photo library whose `read` waits at a gate (cancellably) before handing out its data, so a test
/// can hold several `stageBody` calls in the middle of their read. Everything else is the fake.
private final class GatedLibrary: PhotoLibrarySource, @unchecked Sendable {
    let inner = FakePhotoLibrary()
    private let lock = NSLock()
    private var isOpen = false
    private var arrivals = 0

    func open() { lock.withLock { isOpen = true } }
    var readCount: Int { lock.withLock { arrivals } }

    /// Returns once `count` reads have started.
    func waitForReads(_ count: Int) async throws {
        for _ in 0..<2000 {
            if lock.withLock({ arrivals }) >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(count) reads")
    }

    func read(_ resource: DeviceResource, of assetID: String, allowNetwork: Bool,
              onData: @escaping @Sendable (Data) -> Void) async throws {
        lock.withLock { arrivals += 1 }
        while !lock.withLock({ isOpen }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await inner.read(resource, of: assetID, allowNetwork: allowNetwork, onData: onData)
    }

    func authorization() async -> PhotoAccess { await inner.authorization() }
    func requestAuthorization() async -> PhotoAccess { await inner.requestAuthorization() }
    func albums() async -> [DeviceAlbum] { await inner.albums() }
    func assetIDs(inAlbum id: String) async -> Set<String> { await inner.assetIDs(inAlbum: id) }
    func asset(_ id: String) async -> DeviceAsset? { await inner.asset(id) }
    func assets(_ ids: [String]) async -> [DeviceAsset] { await inner.assets(ids) }
    func modificationDates(_ ids: [String]) async -> [String: Date] { await inner.modificationDates(ids) }
    func changes() -> AsyncStream<Void> { inner.changes() }
    func thumbnailData(_ id: String, pixelSide: Int) async -> Data? { await inner.thumbnailData(id, pixelSide: pixelSide) }
}

/// Hands out a scripted series of free-space answers, then the last one again.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int64] = []
    var values: [Int64] {
        get { lock.withLock { _values } }
        set { lock.withLock { _values = newValue } }
    }
    func next() -> Int64 {
        lock.withLock { _values.count > 1 ? _values.removeFirst() : (_values.first ?? 0) }
    }
}

final class BackupStagingTests: XCTestCase {
    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        // Reasons are compared as English text, whatever the Mac's language.
        Localization.languageOverride = "en"
    }

    override func tearDown() {
        Localization.languageOverride = nil
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
        super.tearDown()
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupStagingTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
        directories.append(url.deletingLastPathComponent())
        return url
    }

    private func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private static let date = Date(timeIntervalSince1970: 1_700_000_000)
    private static let plenty: Int64 = 100 * 1024 * 1024 * 1024

    private func asset(_ resources: [DeviceResource], isVideo: Bool = false, duration: TimeInterval = 0) -> DeviceAsset {
        DeviceAsset(id: "a", isVideo: isVideo, creationDate: Self.date, modificationDate: Self.date,
                    isFavorite: false, duration: duration, resources: resources)
    }

    func testStagedFileMatchesChecksum() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let resource = DeviceResource(type: .photo, filename: "IMG_1.HEIC")
        let chunks = [Data("hello ".utf8), Data("staged ".utf8), Data("world".utf8)]
        library.setData(chunks, for: resource)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty })

        let staged = try await staging.stage(resource, of: asset([resource]), from: library, allowNetwork: false)

        var sha = SHA1Stream()
        sha.update(Data("hello staged world".utf8))
        XCTAssertEqual(staged.checksum, sha.base64())
        XCTAssertEqual(try Data(contentsOf: staged.url), Data("hello staged world".utf8))
        XCTAssertEqual(staged.url.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
        XCTAssertEqual(library.reads, [.init(resource: resource, assetID: "a", allowNetwork: false)])

        staging.remove(staged.url)
        XCTAssertEqual(contents(of: directory), [])
    }

    func testNotEnoughSpaceThrows() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let margin = BackupStaging.margin
        // PhotoKit gives no size: room for twice the estimate (the staged copy and the upload body)
        // plus the margin is needed.
        let photo = DeviceResource(type: .photo, filename: "IMG_2.HEIC")
        library.setData([Data("x".utf8)], for: photo)
        let estimate = BackupStaging.photoEstimate
        let tight = BackupStaging(directory: directory, freeSpace: { margin + 2 * estimate - 1 })
        do {
            _ = try await tight.stage(photo, of: asset([photo]), from: library, allowNetwork: true)
            XCTFail("Expected notEnoughSpace")
        } catch let error as BackupStagingError {
            XCTAssertEqual(error, .notEnoughSpace)
        }
        XCTAssertEqual(library.reads, [], "Nothing is read when there is no room for it")
        XCTAssertEqual(contents(of: directory), [])

        let exact = BackupStaging(directory: directory, freeSpace: { margin + 2 * estimate })
        let staged = try await exact.stage(photo, of: asset([photo]), from: library, allowNetwork: true)
        exact.remove(staged.url)

        // The margin alone is not enough.
        let marginOnly = BackupStaging(directory: directory, freeSpace: { margin })
        do {
            _ = try await marginOnly.stage(photo, of: asset([photo]), from: library, allowNetwork: true)
            XCTFail("Expected notEnoughSpace")
        } catch let error as BackupStagingError {
            XCTAssertEqual(error, .notEnoughSpace)
        }
        XCTAssertEqual(contents(of: directory), [])
    }

    func testEstimatesFollowTheKindOfFile() {
        let photo = DeviceResource(type: .fullSizePhoto, filename: "FullSizeRender.jpg")
        let motion = DeviceResource(type: .pairedVideo, filename: "IMG_1.MOV")
        let video = DeviceResource(type: .video, filename: "IMG_2.MOV")
        XCTAssertEqual(BackupStaging.estimate(photo, of: asset([photo])), BackupStaging.photoEstimate)
        XCTAssertEqual(BackupStaging.estimate(motion, of: asset([motion])), BackupStaging.motionEstimate)
        XCTAssertEqual(BackupStaging.estimate(video, of: asset([video], isVideo: true, duration: 2)),
                       BackupStaging.minimumVideoEstimate)
        XCTAssertEqual(BackupStaging.estimate(video, of: asset([video], isVideo: true, duration: 600)),
                       600 * BackupStaging.videoBytesPerSecond)
    }

    /// A file larger than the estimate is checked again while it is written, so it can't fill the disk.
    func testRunningOutOfSpaceWhileStagingThrowsAndRemovesTheFile() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let margin = BackupStaging.margin
        let resource = DeviceResource(type: .video, filename: "IMG_4.MOV")
        library.setData(Array(repeating: Data(repeating: 7, count: 8), count: 20), for: resource)
        let staging = BackupStaging(directory: directory, freeSpace: { margin + 40 }, recheckInterval: 16,
                                    estimate: { _, _ in 10 })

        do {
            _ = try await staging.stage(resource, of: asset([resource], isVideo: true), from: library, allowNetwork: true)
            XCTFail("Expected notEnoughSpace")
        } catch let error as BackupStagingError {
            XCTAssertEqual(error, .notEnoughSpace)
        }
        XCTAssertEqual(contents(of: directory), [])
    }

    /// Out of room halfway: the read is stopped, so the rest of the file isn't downloaded for nothing.
    func testFailedStagingStopsTheRead() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let margin = BackupStaging.margin
        let resource = DeviceResource(type: .video, filename: "IMG_8.MOV")
        library.setData(Array(repeating: Data(repeating: 7, count: 8), count: 20), for: resource)
        let staging = BackupStaging(directory: directory, freeSpace: { margin + 40 }, recheckInterval: 16,
                                    estimate: { _, _ in 10 })

        do {
            _ = try await staging.stage(resource, of: asset([resource], isVideo: true), from: library, allowNetwork: true)
            XCTFail("Expected notEnoughSpace")
        } catch let error as BackupStagingError {
            XCTAssertEqual(error, .notEnoughSpace)
        }
        // Space runs out at 48 bytes, the sixth chunk; the reader stops at its next chunk.
        XCTAssertEqual(library.deliveredChunks(of: resource), 6)
        XCTAssertEqual(contents(of: directory), [])
    }

    func testFailedReadRethrowsAndLeavesNoFile() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let resource = DeviceResource(type: .photo, filename: "IMG_5.HEIC")
        library.failReads(of: resource, with: StagingReadFailure())
        let cloud = DeviceResource(type: .fullSizePhoto, filename: "FullSizeRender.jpg")
        library.markICloudOnly(cloud)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty })

        do {
            _ = try await staging.stage(resource, of: asset([resource]), from: library, allowNetwork: true)
            XCTFail("Expected the read error")
        } catch is StagingReadFailure {}
        do {
            _ = try await staging.stage(cloud, of: asset([cloud]), from: library, allowNetwork: false)
            XCTFail("Expected needsNetwork")
        } catch let error as PhotoLibraryReadError {
            XCTAssertEqual(error, .needsNetwork)
        }
        XCTAssertEqual(contents(of: directory), [])
    }

    func testRemoveAllEmptiesFolder() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let first = DeviceResource(type: .photo, filename: "IMG_6.HEIC")
        let second = DeviceResource(type: .pairedVideo, filename: "IMG_6.MOV")
        library.setData([Data("one".utf8)], for: first)
        library.setData([Data("two".utf8)], for: second)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty })
        _ = try await staging.stage(first, of: asset([first, second]), from: library, allowNetwork: false)
        _ = try await staging.stage(second, of: asset([first, second]), from: library, allowNetwork: false)
        // A body file the service left behind (it removes its own, but not if the app was killed).
        try Data("body".utf8).write(to: directory.appendingPathComponent("upload-1.multipart"))
        XCTAssertEqual(contents(of: directory).count, 3)

        await staging.removeAll()

        XCTAssertEqual(contents(of: directory), [])
        await staging.removeAll() // an empty or missing folder is fine
    }

    // MARK: - stageBody

    private func checksum(_ data: Data) -> String {
        var sha = SHA1Stream()
        sha.update(data)
        return sha.base64()
    }

    private func fields(hidden: Bool = false, filename: String = "IMG_9.HEIC") -> MultipartFields {
        MultipartFields(filename: filename, mimeType: "image/heic", createdAt: Self.date, modifiedAt: Self.date,
                        isFavorite: false, duration: nil, livePhotoVideoID: nil, hidden: hidden)
    }

    func testHiddenAddsVisibilityHidden() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let motion = DeviceResource(type: .pairedVideo, filename: "IMG_9.MOV")
        library.setData([Data("motion".utf8)], for: motion)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty })

        let hidden = try await staging.stageBody(
            motion, of: asset([motion]), from: library, allowNetwork: false, fields: fields(hidden: true),
            expectedChecksum: checksum(Data("motion".utf8)))
        let visible = try await staging.stageBody(
            motion, of: asset([motion]), from: library, allowNetwork: false, fields: fields(hidden: false),
            expectedChecksum: checksum(Data("motion".utf8)))

        let hiddenText = String(decoding: try Data(contentsOf: hidden.bodyFile), as: UTF8.self)
        let visibleText = String(decoding: try Data(contentsOf: visible.bodyFile), as: UTF8.self)
        XCTAssertTrue(hiddenText.contains("name=\"visibility\"\r\n\r\nhidden\r\n"))
        XCTAssertFalse(visibleText.contains("name=\"visibility\""))
        // The field comes before the file part.
        let field = try XCTUnwrap(hiddenText.range(of: "name=\"visibility\""))
        let file = try XCTUnwrap(hiddenText.range(of: "name=\"assetData\""))
        XCTAssertLessThan(field.lowerBound, file.lowerBound)
    }

    func testChecksumMismatchThrowsAndLeavesNoFile() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        library.setData([Data("changed".utf8)], for: photo)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty })

        do {
            _ = try await staging.stageBody(
                photo, of: asset([photo]), from: library, allowNetwork: false, fields: fields(),
                expectedChecksum: checksum(Data("original".utf8)))
            XCTFail("Expected checksumMismatch")
        } catch let error as BackupStagingError {
            XCTAssertEqual(error, .checksumMismatch)
        }
        XCTAssertEqual(contents(of: directory), [])
    }

    func testOneCopyOnDisk() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        library.setData([Data("pixels".utf8)], for: photo)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty })

        let staged = try await staging.stageBody(
            photo, of: asset([photo]), from: library, allowNetwork: false, fields: fields(),
            expectedChecksum: checksum(Data("pixels".utf8)))

        XCTAssertEqual(contents(of: directory), [staged.bodyFile.lastPathComponent],
                       "Only the body is left; there is no separate copy of the resource")
        XCTAssertEqual(staged.bodyFile.deletingLastPathComponent().standardizedFileURL.path,
                       directory.standardizedFileURL.path)
        XCTAssertEqual(staging.url(forBodyNamed: staged.bodyFile.lastPathComponent)?.standardizedFileURL.path,
                       staged.bodyFile.standardizedFileURL.path)
    }

    /// Single copy: room for the body once (not twice) plus the margin is enough.
    func testBodyNeedsRoomForOneCopyOnly() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        library.setData([Data("x".utf8)], for: photo)
        let margin = BackupStaging.margin
        let estimate = BackupStaging.photoEstimate

        let tight = BackupStaging(directory: directory, freeSpace: { margin + estimate - 1 })
        do {
            _ = try await tight.stageBody(photo, of: asset([photo]), from: library, allowNetwork: false,
                                          fields: fields(), expectedChecksum: checksum(Data("x".utf8)))
            XCTFail("Expected notEnoughSpace")
        } catch let error as BackupStagingError {
            XCTAssertEqual(error, .notEnoughSpace)
        }
        XCTAssertEqual(library.reads, [])

        let exact = BackupStaging(directory: directory, freeSpace: { margin + estimate })
        let staged = try await exact.stageBody(photo, of: asset([photo]), from: library, allowNetwork: false,
                                               fields: fields(), expectedChecksum: checksum(Data("x".utf8)))
        exact.remove(staged.bodyFile)
    }

    func testBudgetRefusesBeyondTheLimit() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        let data = Data(repeating: 3, count: 100)
        library.setData([data], for: photo)
        // The estimate (600) fits the budget (700) alone; the first body's bytes on disk plus another
        // estimate don't.
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty }, recheckInterval: 1024,
                                    budget: 700, estimate: { _, _ in 600 })

        let first = try await staging.stageBody(photo, of: asset([photo]), from: library, allowNetwork: false,
                                                fields: fields(), expectedChecksum: checksum(data))
        let readsBefore = library.reads.count
        do {
            _ = try await staging.stageBody(photo, of: asset([photo]), from: library, allowNetwork: false,
                                            fields: fields(), expectedChecksum: checksum(data))
            XCTFail("Expected overBudget")
        } catch let error as BackupStagingError {
            XCTAssertEqual(error, .overBudget)
        }
        XCTAssertEqual(library.reads.count, readsBefore, "Nothing is read when the budget is used up")
        XCTAssertEqual(contents(of: directory), [first.bodyFile.lastPathComponent], "The refused body leaves no file")

        // Once the first body is recorded and removed, there is room again.
        staging.remove(first.bodyFile)
        let again = try await staging.stageBody(photo, of: asset([photo]), from: library, allowNetwork: false,
                                                fields: fields(), expectedChecksum: checksum(data))
        staging.remove(again.bodyFile)
    }

    /// The positive case: a second body that fits next to the first is staged.
    func testBudgetAllowsBodiesThatFitTogether() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        let data = Data(repeating: 3, count: 100)
        library.setData([data], for: photo)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty }, recheckInterval: 1024,
                                    budget: 10_000, estimate: { _, _ in 600 })

        let first = try await staging.stageBody(photo, of: asset([photo]), from: library, allowNetwork: false,
                                                fields: fields(), expectedChecksum: checksum(data))
        let second = try await staging.stageBody(photo, of: asset([photo]), from: library, allowNetwork: false,
                                                 fields: fields(), expectedChecksum: checksum(data))
        XCTAssertEqual(contents(of: directory).count, 2)
        XCTAssertNotEqual(first.bodyFile, second.bodyFile)
    }

    /// `stageBody` is reentrant at the photo library read: a second body started while the first is
    /// still being read must count the first's reserved estimate, not just the bytes on disk so far.
    func testConcurrentBodiesCountEachOthersReservations() async throws {
        let directory = makeDirectory()
        let library = GatedLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        let data = Data(repeating: 3, count: 100)
        library.inner.setData([data], for: photo)
        // The first body has only its header (a few hundred bytes) on disk while it waits, so a check
        // that looks at the disk alone would let the second through: 500 + 5000 < 6000.
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty }, recheckInterval: 1024,
                                    budget: 6_000, estimate: { _, _ in 5_000 })

        let first = Task {
            try await staging.stageBody(photo, of: self.asset([photo]), from: library, allowNetwork: false,
                                        fields: self.fields(), expectedChecksum: self.checksum(data))
        }
        try await library.waitForReads(1)
        let second = Task {
            try await staging.stageBody(photo, of: self.asset([photo]), from: library, allowNetwork: false,
                                        fields: self.fields(), expectedChecksum: self.checksum(data))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(library.readCount, 1, "The second body is refused before it reads anything")
        library.open() // so a wrongly accepted second body finishes instead of hanging the test
        do {
            _ = try await second.value
            XCTFail("Expected overBudget: 5000 reserved + 5000 estimated > 6000")
        } catch let error as BackupStagingError {
            XCTAssertEqual(error, .overBudget)
        }
        let staged = try await first.value
        XCTAssertEqual(contents(of: directory), [staged.bodyFile.lastPathComponent])
    }

    func testConcurrentBodiesThatFitTogetherAreBothStaged() async throws {
        let directory = makeDirectory()
        let library = GatedLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        let data = Data(repeating: 3, count: 100)
        library.inner.setData([data], for: photo)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty }, recheckInterval: 1024,
                                    budget: 10_500, estimate: { _, _ in 5_000 })

        let tasks = (0..<2).map { _ in
            Task {
                try await staging.stageBody(photo, of: self.asset([photo]), from: library, allowNetwork: false,
                                            fields: self.fields(), expectedChecksum: self.checksum(data))
            }
        }
        try await library.waitForReads(2)
        library.open()
        let first = try await tasks[0].value
        let second = try await tasks[1].value
        XCTAssertNotEqual(first.bodyFile, second.bodyFile)
        XCTAssertEqual(contents(of: directory).count, 2)
    }

    /// A leftover of an earlier run counts as bytes, but doesn't stop a body larger than the budget.
    func testOrphanDoesNotBlockAnOversizedBody() async throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: directory.appendingPathComponent("old.multipart"))
        let library = FakePhotoLibrary()
        let video = DeviceResource(type: .video, filename: "IMG_9.MOV")
        let data = Data(repeating: 3, count: 100)
        library.setData([data], for: video)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty }, recheckInterval: 1024,
                                    budget: 10, estimate: { _, _ in 600 })
        let staged = try await staging.stageBody(video, of: asset([video], isVideo: true), from: library,
                                                 allowNetwork: false, fields: fields(), expectedChecksum: checksum(data))
        staging.remove(staged.bodyFile)
    }

    /// A body larger than the whole budget still goes through when nothing else is staged,
    /// else a large video could never be backed up.
    func testBudgetAllowsOneOversizedBodyWhenNothingElseIsStaged() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let video = DeviceResource(type: .video, filename: "IMG_9.MOV")
        let data = Data(repeating: 3, count: 100)
        library.setData([data], for: video)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty }, recheckInterval: 1024,
                                    budget: 10, estimate: { _, _ in 600 })
        let staged = try await staging.stageBody(video, of: asset([video], isVideo: true), from: library,
                                                 allowNetwork: false, fields: fields(), expectedChecksum: checksum(data))
        staging.remove(staged.bodyFile)
    }

    func testRemoveUnreferencedKeepsReferencedFiles() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        library.setData([Data("x".utf8)], for: photo)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty })
        let keep = try await staging.stageBody(photo, of: asset([photo]), from: library, allowNetwork: false,
                                               fields: fields(), expectedChecksum: checksum(Data("x".utf8)))
        let drop = try await staging.stageBody(photo, of: asset([photo]), from: library, allowNetwork: false,
                                               fields: fields(), expectedChecksum: checksum(Data("x".utf8)))
        try Data("orphan".utf8).write(to: directory.appendingPathComponent("upload-1.multipart"))

        await staging.removeUnreferenced(keeping: [keep.bodyFile])

        XCTAssertEqual(contents(of: directory), [keep.bodyFile.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: drop.bodyFile.path))
        // Keeping a file by an equivalent URL (symlinked temp dir, `..`) still keeps it.
        let alias = directory.appendingPathComponent("../Staging/\(keep.bodyFile.lastPathComponent)")
        await staging.removeUnreferenced(keeping: [alias])
        XCTAssertEqual(contents(of: directory), [keep.bodyFile.lastPathComponent])
        await staging.removeUnreferenced(keeping: [])
        XCTAssertEqual(contents(of: directory), [])
        await staging.removeUnreferenced(keeping: []) // a missing or empty folder is fine
    }

    /// Cleanup that runs while a body is being written leaves that body alone.
    func testRemoveUnreferencedSkipsABodyBeingWritten() async throws {
        let directory = makeDirectory()
        let library = GatedLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        let data = Data("pixels".utf8)
        library.inner.setData([data], for: photo)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: directory.appendingPathComponent("old.multipart"))

        let task = Task {
            try await staging.stageBody(photo, of: self.asset([photo]), from: library, allowNetwork: false,
                                        fields: self.fields(), expectedChecksum: self.checksum(data))
        }
        try await library.waitForReads(1)
        XCTAssertEqual(contents(of: directory).count, 2)

        await staging.removeUnreferenced(keeping: [])

        XCTAssertEqual(contents(of: directory).count, 1, "The orphan goes, the body being written stays")
        library.open()
        let staged = try await task.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.bodyFile.path))
        XCTAssertEqual(contents(of: directory), [staged.bodyFile.lastPathComponent])
        let text = String(decoding: try Data(contentsOf: staged.bodyFile), as: UTF8.self)
        XCTAssertTrue(text.contains("pixels"), "The body is complete")
    }

    /// Cancelling the task stops the read and leaves no file and no reservation behind.
    func testCancellingMidBodyLeavesNoFile() async throws {
        let directory = makeDirectory()
        let library = GatedLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        let data = Data("pixels".utf8)
        library.inner.setData([data], for: photo)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty }, recheckInterval: 1024,
                                    budget: 700, estimate: { _, _ in 600 })

        let task = Task {
            try await staging.stageBody(photo, of: self.asset([photo]), from: library, allowNetwork: false,
                                        fields: self.fields(), expectedChecksum: self.checksum(data))
        }
        try await library.waitForReads(1)
        XCTAssertEqual(contents(of: directory).count, 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(contents(of: directory), [])

        // The reservation is gone too: a body that needs the whole budget is staged now.
        library.open()
        let again = try await staging.stageBody(photo, of: asset([photo]), from: library, allowNetwork: false,
                                                fields: fields(), expectedChecksum: checksum(data))
        staging.remove(again.bodyFile)
    }

    /// Exact bytes of a hidden motion half, as the upload would send them.
    func testHiddenBodyMatchesTheFixtureByteForByte() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let motion = DeviceResource(type: .pairedVideo, filename: "IMG_9.MOV")
        let bytes = Data([0x01, 0xFF, 0x42])
        library.setData([bytes], for: motion)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty })
        let hiddenFields = MultipartFields(
            filename: "IMG_9.MOV", mimeType: "video/quicktime", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100.5), isFavorite: false, duration: 1.5,
            livePhotoVideoID: nil, hidden: true)

        let staged = try await staging.stageBody(
            motion, of: asset([motion]), from: library, allowNetwork: false, fields: hiddenFields,
            expectedChecksum: checksum(bytes))

        func field(_ name: String, _ value: String) -> String {
            "--\(staged.boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        var expected = Data()
        expected.append(Data(field("fileCreatedAt", "2023-11-14T22:13:20.000Z").utf8))
        expected.append(Data(field("fileModifiedAt", "2023-11-14T22:15:00.500Z").utf8))
        expected.append(Data(field("filename", "IMG_9.MOV").utf8))
        expected.append(Data(field("isFavorite", "false").utf8))
        expected.append(Data(field("duration", "1500").utf8))
        expected.append(Data(field("visibility", "hidden").utf8))
        expected.append(Data(("--\(staged.boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; "
            + "filename=\"IMG_9.MOV\"\r\nContent-Type: video/quicktime\r\n\r\n").utf8))
        expected.append(bytes)
        expected.append(Data("\r\n--\(staged.boundary)--\r\n".utf8))
        XCTAssertEqual(try Data(contentsOf: staged.bodyFile), expected)
    }

    /// The body is kept out of device backups. (The file-protection class
    /// `.completeUntilFirstUserAuthentication` is set on iOS only and can't be read back on macOS.)
    func testBodyIsExcludedFromBackup() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        library.setData([Data("x".utf8)], for: photo)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty })

        let staged = try await staging.stageBody(
            photo, of: asset([photo]), from: library, allowNetwork: false, fields: fields(),
            expectedChecksum: checksum(Data("x".utf8)))

        let values = try staged.bodyFile.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testFailedBodyReadRethrowsAndLeavesNoFile() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let photo = DeviceResource(type: .photo, filename: "IMG_9.HEIC")
        library.failReads(of: photo, with: StagingReadFailure())
        let cloud = DeviceResource(type: .fullSizePhoto, filename: "FullSizeRender.jpg")
        library.markICloudOnly(cloud)
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty })

        do {
            _ = try await staging.stageBody(photo, of: asset([photo]), from: library, allowNetwork: true,
                                            fields: fields(), expectedChecksum: "x")
            XCTFail("Expected the read error")
        } catch is StagingReadFailure {}
        do {
            _ = try await staging.stageBody(cloud, of: asset([cloud]), from: library, allowNetwork: false,
                                            fields: fields(), expectedChecksum: "x")
            XCTFail("Expected needsNetwork")
        } catch let error as PhotoLibraryReadError {
            XCTAssertEqual(error, .needsNetwork)
        }
        XCTAssertEqual(contents(of: directory), [])
    }

    /// A body larger than expected is checked again while it is written; the free space then already
    /// reflects what was written, so only the margin must remain.
    func testRunningOutOfSpaceWhileStagingABodyStopsTheReadAndRemovesTheFile() async throws {
        let directory = makeDirectory()
        let library = FakePhotoLibrary()
        let margin = BackupStaging.margin
        let video = DeviceResource(type: .video, filename: "IMG_9.MOV")
        library.setData(Array(repeating: Data(repeating: 7, count: 8), count: 20), for: video)
        let free = Counter()
        let staging = BackupStaging(
            directory: directory, freeSpace: { free.next() }, recheckInterval: 16, estimate: { _, _ in 10 })
        free.values = [margin + 10, margin + 10, margin - 1] // start, first recheck, second recheck

        do {
            _ = try await staging.stageBody(video, of: asset([video], isVideo: true), from: library,
                                            allowNetwork: true, fields: fields(), expectedChecksum: "x")
            XCTFail("Expected notEnoughSpace")
        } catch let error as BackupStagingError {
            XCTAssertEqual(error, .notEnoughSpace)
        }
        XCTAssertLessThan(library.deliveredChunks(of: video), 20)
        XCTAssertEqual(contents(of: directory), [])
    }

    func testReadFailureStatesMatchTheScanner() throws {
        let resource = DeviceResource(type: .photo, filename: "IMG_7.HEIC")
        XCTAssertEqual(try BackupReadFailure.state(for: PhotoLibraryReadError.needsNetwork, reading: resource),
                       .pending(reason: .waitingForWiFi))
        XCTAssertEqual(try BackupReadFailure.state(for: StagingReadFailure(), reading: resource),
                       .failed(reason: "Couldn't read IMG_7.HEIC: disk on fire"))
        XCTAssertThrowsError(try BackupReadFailure.state(for: CancellationError(), reading: resource)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
