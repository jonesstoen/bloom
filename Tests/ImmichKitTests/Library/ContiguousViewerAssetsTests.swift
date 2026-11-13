import XCTest
import ImmichKit
@testable import ImmichUI

final class ContiguousViewerAssetsTests: XCTestCase {
    func testLoadedEmptyMonthsBridgeButUnloadedMonthsSeparateViewerPages() {
        let cells = GridCellIndex(months: [month(1, ["a", "b"]), month(2, []), month(3, ["c"]), month(4, nil), month(5, ["d"])])
        XCTAssertEqual(cells.viewerAssets(around: "c").map(\.id), ["a", "b", "c"])
        XCTAssertEqual(cells.viewerAssets(around: "d").map(\.id), ["d"])
        XCTAssertTrue(cells.viewerAssets(around: "missing").isEmpty)
    }

    func testViewerKeepsMonthAndAssetOrderInEitherDirection() {
        let months = [month(1, ["a", "b"]), month(2, ["d", "c"])]
        XCTAssertEqual(GridCellIndex(months: months).viewerAssets(around: "c").map(\.id), ["a", "b", "d", "c"])
        XCTAssertEqual(GridCellIndex(months: Array(months.reversed())).viewerAssets(around: "a").map(\.id), ["d", "c", "a", "b"])
        XCTAssertTrue(GridCellIndex().viewerAssets(around: "missing").isEmpty)
    }

    private func month(_ index: Int, _ ids: [String]?) -> TimelineMonth {
        let assets = ids?.map { Asset(id: $0, kind: .image, takenAt: .distantPast) }
        return TimelineMonth(bucket: TimeBucket(id: "m\(index)", year: 2024, month: index, count: ids?.count ?? 3),
                             days: assets.map { [TimelineDay(year: 2024, month: index, day: 1, assets: $0)] })
    }
}
