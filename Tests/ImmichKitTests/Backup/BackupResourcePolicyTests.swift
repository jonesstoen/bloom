import XCTest
@testable import ImmichKit

final class BackupResourcePolicyTests: XCTestCase {
    private func r(_ type: DeviceResourceType) -> DeviceResource {
        DeviceResource(type: type, filename: "\(type.rawValue).bin")
    }

    private func check(_ input: [DeviceResourceType], _ expected: [DeviceResourceType], line: UInt = #line) {
        let result = BackupResourcePolicy.upload(from: input.map(r)).map(\.type)
        XCTAssertEqual(result, expected, line: line)
    }

    func testPhotoOnly() { check([.photo], [.photo]) }
    func testFullSizePhotoReplacesPhotoAndDropsOther() { check([.photo, .other, .fullSizePhoto], [.fullSizePhoto]) }
    func testLivePhotoKeepsBothSides() { check([.photo, .pairedVideo], [.photo, .pairedVideo]) }
    func testEditedLivePhotoUsesFullSizeBothSides() {
        check([.photo, .other, .fullSizePairedVideo, .pairedVideo, .fullSizePhoto], [.fullSizePhoto, .fullSizePairedVideo])
    }
    func testVideoOnly() { check([.video], [.video]) }
    func testFullSizeVideoReplacesVideo() { check([.video, .fullSizeVideo], [.fullSizeVideo]) }
    func testOtherOnlyIsEmpty() { check([.other], []) }
}
