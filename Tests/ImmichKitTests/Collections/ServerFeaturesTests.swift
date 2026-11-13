import XCTest
import ImmichKit
@testable import ImmichUI

/// An empty People list must say when the server has facial recognition turned off, instead of
/// suggesting there are simply no people yet.
@MainActor
final class ServerFeaturesTests: XCTestCase {
    func testDecodesFlagsAndTreatsMissingOnesAsOn() throws {
        let off = #"{"facialRecognition":false,"smartSearch":false,"reverseGeocoding":false,"trash":true}"#
        XCTAssertEqual(try JSONDecoder().decode(ServerFeatures.self, from: Data(off.utf8)),
                       ServerFeatures(facialRecognition: false, smartSearch: false, reverseGeocoding: false))
        XCTAssertEqual(try JSONDecoder().decode(ServerFeatures.self, from: Data("{}".utf8)), ServerFeatures())
        let odd = #"{"facialRecognition":"no"}"#
        XCTAssertEqual(try JSONDecoder().decode(ServerFeatures.self, from: Data(odd.utf8)), ServerFeatures(),
                       "an unreadable flag must not be reported as off")
    }

    func testEmptyPeopleWithFaceRecognitionOff() async {
        let mock = MockImmichService()
        await mock.setServerFeatures(ServerFeatures(facialRecognition: false))
        let model = CollectionsModel(service: mock)
        await model.loadPeople()
        XCTAssertTrue(model.loadedPeople)
        XCTAssertTrue(model.people.isEmpty)
        XCTAssertTrue(model.faceRecognitionOff)
    }

    func testEmptyPeopleWithFaceRecognitionOnIsPlainEmpty() async {
        let model = CollectionsModel(service: MockImmichService())
        await model.loadPeople()
        XCTAssertTrue(model.loadedPeople)
        XCTAssertTrue(model.people.isEmpty)
        XCTAssertFalse(model.faceRecognitionOff)
    }

    func testPeopleStillLoadWhenTheFlagSaysOff() async {
        let mock = MockImmichService(library: .standard)
        await mock.setServerFeatures(ServerFeatures(facialRecognition: false))
        let model = CollectionsModel(service: mock)
        await model.loadPeople()
        XCTAssertFalse(model.people.isEmpty, "imported faces still show even with recognition off")
    }

    func testFailingFeaturesRequestMeansUnknown() async {
        let mock = MockImmichService()
        await mock.setServerFeaturesFailure(.unexpectedStatus(404))
        let model = CollectionsModel(service: mock)
        await model.loadPeople()
        XCTAssertTrue(model.loadedPeople)
        XCTAssertNil(model.peopleError)
        XCTAssertFalse(model.faceRecognitionOff)
    }

    func testEditGuardForwardsFeatures() async throws {
        let mock = MockImmichService()
        await mock.setServerFeatures(ServerFeatures(facialRecognition: false))
        let guarded = EditGuardedService(base: mock, permission: EditingPermission(isAllowed: false))
        let features = try await guarded.serverFeatures()
        XCTAssertFalse(features.facialRecognition)
    }
}
