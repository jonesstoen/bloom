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
        // What `LiveImmichService` turns a transport failure into: the code decides.
        XCTAssertTrue(ImmichServiceError.isConnectivityFailure(ImmichServiceError.network("offline", code: .notConnectedToInternet)))
        XCTAssertFalse(ImmichServiceError.isConnectivityFailure(ImmichServiceError.network("TLS", code: .serverCertificateUntrusted)))
        XCTAssertFalse(ImmichServiceError.isConnectivityFailure(ImmichServiceError.network("no cause known")))
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

    func testConditionsThatCannotTellReportConnected() async {
        struct Fixed: NetworkConditions {
            let isOnCellular = false
            func changes() -> AsyncStream<NetworkPath> { AsyncStream { $0.finish() } }
        }
        let connected = await Fixed().isConnected
        XCTAssertTrue(connected)
    }

    /// Through the live service's error mapping: the transport's code decides, not just "it was a URLError".
    func testLiveServiceKeepsTheCauseOfTransportFailures() async {
        for (code, offline) in [(URLError.Code.notConnectedToInternet, true), (.timedOut, true), (.cannotConnectToHost, true),
                                (.serverCertificateUntrusted, false), (.secureConnectionFailed, false),
                                (.appTransportSecurityRequiresSecureConnection, false), (.badServerResponse, false)] {
            do {
                try await LiveImmichService.mapErrors { throw URLError(code) }
                XCTFail("expected an error")
            } catch {
                guard case ImmichServiceError.network = error else { return XCTFail("\(code): got \(error)") }
                XCTAssertEqual(ImmichServiceError.isConnectivityFailure(error), offline, "\(code)")
            }
            do {
                try await LiveImmichService.mapErrors { throw NSError(domain: NSURLErrorDomain, code: code.rawValue) }
            } catch {
                XCTAssertEqual(ImmichServiceError.isConnectivityFailure(error), offline, "NSError \(code)")
            }
        }
    }
}
