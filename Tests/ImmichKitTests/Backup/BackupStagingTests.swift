import XCTest
@testable import ImmichKit

private struct StagingReadFailure: Error, LocalizedError {
    var errorDescription: String? { "disk on fire" }
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
