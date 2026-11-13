import XCTest
@testable import ImmichKit
@testable import ImmichUI

/// Photos and metadata from earlier sessions, and originals from interrupted shares, must not
/// stay on the device; authenticated responses must not land in the shared HTTP cache.
final class CacheHygieneTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CacheHygiene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("file"))
        return url
    }

    private func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    }

    func testOtherAccountsCachesAreRemoved() throws {
        let current = try makeDirectory("aaaa")
        _ = try makeDirectory("bbbb")
        _ = try makeDirectory("cccc")
        CacheProtection.removeOtherAccounts(in: root, keeping: current)
        XCTAssertEqual(try names(), ["aaaa"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("file").path))
        CacheProtection.removeOtherAccounts(in: root, keeping: nil)
        XCTAssertEqual(try names(), [])
    }

    func testLeftoverShareFoldersAreRemovedAndNothingElse() throws {
        _ = try makeDirectory("BloomShare-1")
        _ = try makeDirectory("BloomShare-2")
        _ = try makeDirectory("SomethingElse")
        SelectionShareFiles.removeLeftovers(in: root)
        XCTAssertEqual(try names(), ["SomethingElse"])
    }

    func testTheAPISessionKeepsNoHTTPCacheOrCookies() {
        let configuration = ImmichNetwork.session.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertTrue(SameOriginRedirects.guards(ImmichNetwork.session), "still refuses cross-origin redirects")
    }

    func testCacheWritesStillWork() async throws {
        let cache = DiskImageCache(directory: root.appendingPathComponent("Images"), byteLimit: 1024)
        await cache.store(Data("photo".utf8), for: "k")
        let stored = await cache.data(for: "k")
        XCTAssertEqual(stored, Data("photo".utf8))
    }
}
