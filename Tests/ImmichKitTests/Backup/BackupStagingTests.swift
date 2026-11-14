import XCTest
@testable import ImmichKit

private struct StagingReadFailure: Error, LocalizedError {
    var errorDescription: String? { "disk on fire" }
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
        XCTAssertEqual(staging.url(forBodyNamed: staged.bodyFile.lastPathComponent).standardizedFileURL.path,
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
        // Budget 1_000 bytes with a 600-byte estimate: the first body fits (nothing staged yet), the
        // second would take the total past the limit.
        let staging = BackupStaging(directory: directory, freeSpace: { Self.plenty }, recheckInterval: 1024,
                                    budget: 1_000, estimate: { _, _ in 600 })

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
        XCTAssertEqual(contents(of: directory), [first.bodyFile.lastPathComponent])

        // Once the first body is recorded and removed, there is room again.
        staging.remove(first.bodyFile)
        let again = try await staging.stageBody(photo, of: asset([photo]), from: library, allowNetwork: false,
                                                fields: fields(), expectedChecksum: checksum(data))
        staging.remove(again.bodyFile)
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
