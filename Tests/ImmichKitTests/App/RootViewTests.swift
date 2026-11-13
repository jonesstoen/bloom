import XCTest
import ImmichKit
@testable import ImmichUI

@MainActor
final class RootViewTests: XCTestCase {
    func testNoCredentialsShowsLoginThenSuccessfulLoginCreatesSession() async throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        let mock = MockImmichService.preview
        let root = RootModel(store: store, makeService: { _ in mock })
        await root.restore()
        XCTAssertEqual(root.phase, .signedOut)
        XCTAssertNil(root.session)
        let login = root.makeLoginModel()
        login.server = "https://example.invalid"
        login.apiKey = "unit-test-placeholder"
        await login.connectNow()
        XCTAssertEqual(root.phase, .signedIn)
        XCTAssertNotNil(root.session)
        XCTAssertNotNil(try store.load())
        await root.signOut()
        XCTAssertEqual(root.phase, .signedOut)
        XCTAssertNil(root.session)
        XCTAssertNil(try store.load())
    }

    /// A signed-in session only views the library until Allow Changes is turned on.
    func testSessionsAreViewOnlyUntilChangesAreAllowed() async throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        try store.save(ServerCredentials(server: "https://example.invalid", apiKey: "unit-test-placeholder"))
        let mock = MockImmichService(library: .standard)
        let editing = EditingPermission(isAllowed: false)
        let root = RootModel(store: store, makeService: { _ in mock }, editing: editing)
        await root.restore()
        let session = try XCTUnwrap(root.session)
        let asset = MockLibrary.standard.assets[0]
        do {
            _ = try await session.service.moveToTrash(assetIDs: [asset.id])
            XCTFail("A view-only session must not move anything to trash")
        } catch {
            XCTAssertEqual(error as? ImmichServiceError, .editingOff)
        }
        let unchanged = try await mock.asset(id: asset.id)
        XCTAssertFalse(unchanged.isTrashed)
        editing.isAllowed = true
        let result = try await session.service.moveToTrash(assetIDs: [asset.id])
        XCTAssertEqual(result.confirmedIDs, [asset.id])
    }

    func testStoredCredentialsRestoreWithoutNetworkValidation() async throws {
        let store = CredentialStore(storage: InMemorySecureStorage())
        try store.save(ServerCredentials(server: "https://example.invalid", apiKey: "unit-test-placeholder"))
        let mock = MockImmichService.preview
        await mock.setFailure(.network("Offline"))
        let root = RootModel(store: store, makeService: { _ in mock })
        await root.restore()
        XCTAssertEqual(root.phase, .signedIn)
        XCTAssertNotNil(root.session)
    }

    func testCorruptCredentialsShowRecoveryInsteadOfOverwriting() async throws {
        let storage = InMemorySecureStorage()
        try storage.set(Data("invalid-json".utf8), for: "server-credentials")
        let root = RootModel(store: CredentialStore(storage: storage), makeService: { _ in MockImmichService.preview })
        await root.restore()
        XCTAssertEqual(root.phase, .failed)
        XCTAssertNotNil(root.error)
        XCTAssertNil(root.session)
        await root.signOut()
        XCTAssertEqual(root.phase, .signedOut)
    }

    func testCacheNamespaceSeparatesServersAndCredentials() throws {
        let a = try ServerCredentials(server: "https://one.invalid", apiKey: "test-a")
        let b = try ServerCredentials(server: "https://two.invalid", apiKey: "test-a")
        let c = try ServerCredentials(server: "https://one.invalid", apiKey: "test-b")
        XCTAssertNotEqual(RootModel.cacheDirectory(for: a), RootModel.cacheDirectory(for: b))
        XCTAssertNotEqual(RootModel.cacheDirectory(for: a), RootModel.cacheDirectory(for: c))
        XCTAssertEqual(RootModel.cacheDirectory(for: a), RootModel.cacheDirectory(for: a))
    }

    func testBackupDirectoryIsPerAccountAndOutsideCaches() throws {
        let a = try ServerCredentials(server: "https://one.invalid", apiKey: "test-a")
        let b = try ServerCredentials(server: "https://two.invalid", apiKey: "test-a")
        let c = try ServerCredentials(server: "https://one.invalid", apiKey: "test-b")
        XCTAssertNotEqual(RootModel.backupDirectory(for: a), RootModel.backupDirectory(for: b))
        XCTAssertNotEqual(RootModel.backupDirectory(for: a), RootModel.backupDirectory(for: c))
        XCTAssertEqual(RootModel.backupDirectory(for: a), RootModel.backupDirectory(for: a))
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        XCTAssertFalse(RootModel.backupDirectory(for: a).standardizedFileURL.path.hasPrefix(caches.standardizedFileURL.path))
        XCTAssertFalse(RootModel.backupDirectory(for: a).path.contains("test-a"))
    }
}
