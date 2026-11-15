#if canImport(Photos)
import Photos
import XCTest
@testable import ImmichKit

/// How PhotoKit's read errors become Bloom's: they decide between waiting, a readable problem and a raw error.
final class PhotoKitErrorMappingTests: XCTestCase {
    func testInternalErrorMeansPhotosCouldNotDeliverTheFile() {
        let error = NSError(domain: PHPhotosErrorDomain, code: -1)
        XCTAssertEqual(PhotoKitLibrarySource.map(error) as? PhotoLibraryReadError, .notDelivered)
    }

    func testNetworkAccessRequiredWaitsForTheNetwork() {
        let error = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.networkAccessRequired.rawValue)
        XCTAssertEqual(PhotoKitLibrarySource.map(error) as? PhotoLibraryReadError, .needsNetwork)
    }

    func testOtherErrorsPassThrough() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4)
        XCTAssertEqual(PhotoKitLibrarySource.map(error) as NSError, error)
    }
}
#endif
