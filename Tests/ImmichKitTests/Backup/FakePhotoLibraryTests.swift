import XCTest
@testable import ImmichKit

final class FakePhotoLibraryTests: XCTestCase {
    private struct Boom: Error, Equatable {}

    private let local = DeviceResource(type: .photo, filename: "IMG_1.HEIC")
    private let cloud = DeviceResource(type: .fullSizePhoto, filename: "FullSizeRender.jpg")

    func testICloudOnlyThrowsNeedsNetworkWithoutNetworkAndRecordsCalls() async throws {
        let fake = FakePhotoLibrary()
        fake.setData([Data([1, 2])], for: local)
        fake.setData([Data([3])], for: cloud)
        fake.markICloudOnly(cloud)

        do {
            try await fake.read(cloud, of: "a", allowNetwork: false) { _ in }
            XCTFail("expected needsNetwork")
        } catch {
            XCTAssertEqual(error as? PhotoLibraryReadError, .needsNetwork)
        }

        let box = DataBox()
        try await fake.read(cloud, of: "a", allowNetwork: true) { box.append($0) }
        try await fake.read(local, of: "a", allowNetwork: false) { box.append($0) }

        XCTAssertEqual(box.value, Data([3, 1, 2]))
        XCTAssertEqual(fake.reads.map(\.allowNetwork), [false, true, false])
        XCTAssertEqual(fake.reads.map(\.resource), [cloud, cloud, local])
    }

    func testInjectedFailureIsThrownAndRecorded() async {
        let fake = FakePhotoLibrary()
        fake.failReads(of: local, with: Boom())
        do {
            try await fake.read(local, of: "a", allowNetwork: true) { _ in }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }
        XCTAssertEqual(fake.reads.count, 1)
    }

    func testFakeChangesStreamDeliversEmittedChanges() async {
        let fake = FakePhotoLibrary()
        let stream = fake.changes()
        fake.emitChange()
        fake.emitChange()

        var received = 0
        for await _ in stream {
            received += 1
            if received == 2 { break }
        }
        XCTAssertEqual(received, 2)
    }

    func testFakeThumbnailReturnsConfiguredData() async {
        let fake = FakePhotoLibrary()
        fake.thumbnails["a"] = Data([9, 8, 7])

        let known = await fake.thumbnailData("a", pixelSide: 120)
        let unknown = await fake.thumbnailData("b", pixelSide: 120)
        XCTAssertEqual(known, Data([9, 8, 7]))
        XCTAssertNil(unknown)
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var value: Data { lock.withLock { data } }
}
