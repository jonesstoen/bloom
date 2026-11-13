import XCTest
@testable import ImmichKit

final class BackupSelectionTests: XCTestCase {
    private func library() -> FakePhotoLibrary {
        let fake = FakePhotoLibrary()
        fake.addAlbum(id: "A", title: "A", assetIDs: ["1", "2", "3"])
        fake.addAlbum(id: "B", title: "B", assetIDs: ["3", "4"])
        fake.addAlbum(id: "S", title: "Screenshots", assetIDs: ["2"])
        return fake
    }

    func testIncludedMinusExcluded() async {
        let selection = BackupSelection(included: ["A", "B"], excluded: ["S"])
        let ids = await selection.assetIDs(in: library())
        XCTAssertEqual(ids, ["1", "3", "4"])
    }

    func testNothingIncludedIsEmpty() async {
        let selection = BackupSelection(included: [], excluded: ["S"])
        let ids = await selection.assetIDs(in: library())
        XCTAssertTrue(ids.isEmpty)
    }

    func testUnknownAlbumIDsAreIgnored() async {
        let selection = BackupSelection(included: ["A", "gone"], excluded: ["also-gone"])
        let ids = await selection.assetIDs(in: library())
        XCTAssertEqual(ids, ["1", "2", "3"])
    }

    func testCodableRoundTrip() throws {
        let selection = BackupSelection(included: ["A"], excluded: ["S"])
        let data = try JSONEncoder().encode(selection)
        XCTAssertEqual(try JSONDecoder().decode(BackupSelection.self, from: data), selection)
    }
}
