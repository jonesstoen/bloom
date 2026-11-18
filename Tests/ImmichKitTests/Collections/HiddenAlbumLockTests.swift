import XCTest
import ImmichKit
@testable import ImmichUI

/// The Hidden collection asks for Face ID / Touch ID / the passcode before it shows photos.
@MainActor
final class HiddenAlbumLockTests: XCTestCase {
    /// Counts prompts; answers with `result` after `delay` (so tests can overlap two unlocks).
    private final class FakeAuthenticator: DeviceAuthenticator, @unchecked Sendable {
        private let lock = NSLock()
        private var prompts = 0
        let available: Bool
        let result: Bool
        let delay: Duration

        init(available: Bool = true, result: Bool = true, delay: Duration = .zero) {
            self.available = available
            self.result = result
            self.delay = delay
        }

        var promptCount: Int { lock.withLock { prompts } }
        func canAuthenticate() -> Bool { available }
        func authenticate(reason: String) async -> Bool {
            lock.withLock { prompts += 1 }
            if delay != .zero { try? await Task.sleep(for: delay) }
            return result
        }
    }

    func testStartsLocked() {
        XCTAssertFalse(HiddenAlbumLock(authenticator: FakeAuthenticator()).isUnlocked)
    }

    func testSettingOffUnlocksWithoutPrompting() async {
        let auth = FakeAuthenticator(result: false)
        let lock = HiddenAlbumLock(authenticator: auth)
        await lock.unlock(requiresAuthentication: false)
        XCTAssertTrue(lock.isUnlocked)
        XCTAssertEqual(auth.promptCount, 0)
    }

    func testNoAuthenticationOnTheDeviceUnlocksWithoutPrompting() async {
        let auth = FakeAuthenticator(available: false, result: false)
        let lock = HiddenAlbumLock(authenticator: auth)
        await lock.unlock(requiresAuthentication: true)
        XCTAssertTrue(lock.isUnlocked)
        XCTAssertEqual(auth.promptCount, 0)
    }

    func testSuccessUnlocks() async {
        let auth = FakeAuthenticator(result: true)
        let lock = HiddenAlbumLock(authenticator: auth)
        await lock.unlock(requiresAuthentication: true)
        XCTAssertTrue(lock.isUnlocked)
        XCTAssertEqual(auth.promptCount, 1)
    }

    func testFailureOrCancelStaysLocked() async {
        let auth = FakeAuthenticator(result: false)
        let lock = HiddenAlbumLock(authenticator: auth)
        await lock.unlock(requiresAuthentication: true)
        XCTAssertFalse(lock.isUnlocked)
        XCTAssertEqual(auth.promptCount, 1)
    }

    func testLockRelocks() async {
        let lock = HiddenAlbumLock(authenticator: FakeAuthenticator())
        await lock.unlock(requiresAuthentication: true)
        XCTAssertTrue(lock.isUnlocked)
        lock.lock()
        XCTAssertFalse(lock.isUnlocked)
    }

    func testAlreadyUnlockedDoesNotPromptAgain() async {
        let auth = FakeAuthenticator()
        let lock = HiddenAlbumLock(authenticator: auth)
        await lock.unlock(requiresAuthentication: true)
        await lock.unlock(requiresAuthentication: true)
        XCTAssertEqual(auth.promptCount, 1)
    }

    func testConcurrentUnlocksPromptOnce() async {
        let auth = FakeAuthenticator(delay: .milliseconds(100))
        let lock = HiddenAlbumLock(authenticator: auth)
        async let first: Void = lock.unlock(requiresAuthentication: true)
        async let second: Void = lock.unlock(requiresAuthentication: true)
        _ = await (first, second)
        XCTAssertEqual(auth.promptCount, 1)
        XCTAssertTrue(lock.isUnlocked)
    }

    func testLeavingWhilePromptingDoesNotUnlockLater() async {
        let auth = FakeAuthenticator(result: true, delay: .milliseconds(100))
        let lock = HiddenAlbumLock(authenticator: auth)
        let unlocking = Task { await lock.unlock(requiresAuthentication: true) }
        try? await Task.sleep(for: .milliseconds(20))
        lock.lock()
        await unlocking.value
        XCTAssertFalse(lock.isUnlocked)
    }

    func testPromptShowsTheLockOnlyWhileLockedAndRequired() async {
        let lock = HiddenAlbumLock(authenticator: FakeAuthenticator())
        XCTAssertTrue(lock.showsLock(requiresAuthentication: true))
        XCTAssertFalse(lock.showsLock(requiresAuthentication: false))
        await lock.unlock(requiresAuthentication: true)
        XCTAssertFalse(lock.showsLock(requiresAuthentication: true))
        let none = HiddenAlbumLock(authenticator: FakeAuthenticator(available: false))
        XCTAssertFalse(none.showsLock(requiresAuthentication: true))
    }
}
