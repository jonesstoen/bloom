import Foundation
import XCTest
@testable import ImmichKit

/// Which failures mean "no connection to the server" (shown as waiting, retried when the network is back).
final class BackupNetworkTests: XCTestCase {
    func testUnreachableServerCountsAsNoConnection() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
        ]
        for code in codes {
            XCTAssertTrue(ImmichServiceError.isConnectivityFailure(URLError(code)), "\(code)")
            XCTAssertTrue(ImmichServiceError.isConnectivityFailure(NSError(domain: NSURLErrorDomain, code: code.rawValue)),
                          "NSError \(code)")
        }
        // What `LiveImmichService` turns every transport failure into.
        XCTAssertTrue(ImmichServiceError.isConnectivityFailure(ImmichServiceError.network("offline")))
    }

    func testOtherFailuresAreNot() {
        let failures: [any Error] = [
            ImmichServiceError.unauthorized, ImmichServiceError.unexpectedStatus(503), ImmichServiceError.invalidResponse,
            ImmichServiceError.insecureConnection, ImmichServiceError.invalidServerURL, ImmichServiceError.editingOff,
            URLError(.badServerResponse), URLError(.cancelled), URLError(.serverCertificateUntrusted),
            CancellationError(), BackupIndexError.unavailable,
            CocoaError(.fileWriteOutOfSpace),
        ]
        for failure in failures {
            XCTAssertFalse(ImmichServiceError.isConnectivityFailure(failure), "\(failure)")
        }
    }

    func testConditionsThatCannotObserveTheNetworkReportConnectedAndNoChanges() async {
        struct Fixed: NetworkConditions { let isOnCellular = false }
        let fixed = Fixed()
        let connected = await fixed.isConnected
        XCTAssertTrue(connected)
        var events = 0
        for await _ in fixed.changes() { events += 1 }
        XCTAssertEqual(events, 0, "The stream ends at once")
    }
}
