import XCTest
import ImmichKit
@testable import ImmichUI

/// The viewer's title shows when a photo was taken like Photos: "Today", "Yesterday", the weekday
/// within the last week, and otherwise the full date. (Only the weekday made a photo from last
/// year read "Tuesday".)
final class ViewerDateTextTests: XCTestCase {
    private let norwegian = Locale(identifier: "nb_NO")
    /// Wednesday 12 November 2026, 19:50 wall-clock time (UTC-encoded like `localDateTime`).
    private let now = date(2026, 11, 12, 19, 50)

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        Asset.localCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func text(_ date: Date) -> String {
        ViewerDateText.day(of: date, now: now, locale: norwegian, today: "I dag", yesterday: "I går")
    }

    func testRecentDaysAreRelative() {
        XCTAssertEqual(text(Self.date(2026, 11, 12, 0, 5)), "I dag")
        XCTAssertEqual(text(Self.date(2026, 11, 11, 23, 59)), "I går")
        XCTAssertEqual(text(Self.date(2026, 11, 10)).lowercased(), "tirsdag")
        XCTAssertEqual(text(Self.date(2026, 11, 6)).lowercased(), "fredag", "six days ago is still this week")
    }

    func testOlderPhotosShowTheFullDate() {
        let lastWeek = text(Self.date(2026, 11, 5))
        XCTAssertTrue(lastWeek.contains("5") && lastWeek.contains("november") && lastWeek.contains("2026"), lastWeek)
        let lastYear = text(Self.date(2025, 11, 11, 17, 29))
        XCTAssertTrue(lastYear.contains("11") && lastYear.contains("november") && lastYear.contains("2025"), lastYear)
        XCTAssertFalse(lastYear.lowercased().contains("tirsdag"))
        let future = text(Self.date(2026, 11, 14))
        XCTAssertTrue(future.contains("2026"), "a clock ahead of the phone gets a date, not a weekday")
    }

    func testEnglish() {
        XCTAssertEqual(ViewerDateText.day(of: Self.date(2026, 11, 12), now: now, locale: Locale(identifier: "en_US"),
                                          today: "Today", yesterday: "Yesterday"), "Today")
        XCTAssertEqual(ViewerDateText.day(of: Self.date(2026, 11, 10), now: now, locale: Locale(identifier: "en_US")),
                       "Tuesday")
    }
}
