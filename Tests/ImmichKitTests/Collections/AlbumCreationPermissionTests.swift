import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
@testable import ImmichKit
@testable import ImmichUI

final class AlbumCreationPermissionTests: XCTestCase {
    @MainActor
    func testTurningChangesOffAfterCreationRefusesTheSeparateAdd() async throws {
        Localization.languageOverride = "en"
        defer { Localization.languageOverride = nil }
        let permission = EditingPermission(isAllowed: true)
        let transport = RevokeAfterCreationTransport(permission: permission)
        let credentials = try ServerCredentials(server: "https://photos.example.invalid", apiKey: "unit-test-placeholder")
        let service: any ImmichService = EditGuardedService(
            base: LiveImmichService(credentials: credentials, transport: transport), permission: permission
        )
        let model = AlbumPickerModel(service: service, assetIDs: ["11111111-1111-4111-8111-111111111111"])
        let changed = expectation(forNotification: .bloomAlbumsDidChange, object: nil)

        await model.createAlbum(named: "Trip")

        XCTAssertEqual(transport.methods, [.post], "The add must not reach the transport after changes are disabled")
        XCTAssertEqual(model.outcome, "Created «Trip», but couldn't confirm the added items. Open the album before trying again.")
        XCTAssertFalse(model.isWorking)
        await fulfillment(of: [changed], timeout: 1)
    }
}

private final class RevokeAfterCreationTransport: ClientTransport, @unchecked Sendable {
    private let permission: EditingPermission
    private let lock = NSLock()
    private var recordedMethods: [HTTPRequest.Method] = []
    var methods: [HTTPRequest.Method] { lock.withLock { recordedMethods } }

    init(permission: EditingPermission) { self.permission = permission }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { recordedMethods.append(request.method) }
        permission.isAllowed = false
        return (HTTPResponse(status: .created), HTTPBody(#"{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}"#))
    }
}
