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
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var value: Data { lock.withLock { data } }
}
