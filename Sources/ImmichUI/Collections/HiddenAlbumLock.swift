import ImmichKit
import LocalAuthentication
import Observation

/// Asks the device owner to prove who they are (Face ID, Touch ID or the passcode).
public protocol DeviceAuthenticator: Sendable {
    /// Whether the device can authenticate at all (it has a passcode or biometrics set up).
    func canAuthenticate() -> Bool
    /// Shows the system prompt. `false` when it fails or the user cancels.
    func authenticate(reason: String) async -> Bool
}

/// `LocalAuthentication` with the device passcode as the fallback (`.deviceOwnerAuthentication`).
public struct LADeviceAuthenticator: DeviceAuthenticator {
    public init() {}

    public func canAuthenticate() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    public func authenticate(reason: String) async -> Bool {
        // A context remembers a success for a while, so every prompt gets a fresh one.
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Whether the Hidden collection is open. Bloom-only: on the server the photos are in Archive.
/// Starts locked; one instance lives as long as the signed-in session.
@MainActor @Observable
public final class HiddenAlbumLock {
    /// `@AppStorage` key of the "Use Face ID for Hidden" setting (default on).
    public nonisolated static let requiresAuthenticationKey = "hiddenRequiresAuthentication"

    public private(set) var isUnlocked = false
    @ObservationIgnored private let authenticator: any DeviceAuthenticator
    @ObservationIgnored private var prompt: Task<Void, Never>?
    /// Bumped by `lock()`, so an answer to a prompt started before it can't unlock afterwards.
    @ObservationIgnored private var generation = 0

    public init(authenticator: any DeviceAuthenticator = LADeviceAuthenticator()) {
        self.authenticator = authenticator
    }

    /// Whether Hidden is behind a lock the user has to open: the setting is on, the device can
    /// authenticate, and it is locked now.
    public func showsLock(requiresAuthentication: Bool) -> Bool {
        !isUnlocked && requiresAuthentication && authenticator.canAuthenticate()
    }

    /// Unlocks without a prompt when the setting is off or the device can't authenticate;
    /// otherwise prompts. Failure or cancel leaves it locked. A call during a prompt waits for it.
    public func unlock(requiresAuthentication: Bool) async {
        guard !isUnlocked else { return }
        guard requiresAuthentication, authenticator.canAuthenticate() else {
            isUnlocked = true
            return
        }
        if let prompt {
            await prompt.value
            return
        }
        let authenticator = authenticator
        let started = generation
        let reason = tr("Unlock your hidden photos.")
        let task = Task { @MainActor [weak self] in
            let success = await authenticator.authenticate(reason: reason)
            guard let self else { return }
            if success, self.generation == started { self.isUnlocked = true }
            self.prompt = nil
        }
        prompt = task
        await task.value
    }

    /// Locks again (the user left Hidden or the app). Discards the answer of a prompt in progress.
    public func lock() {
        generation += 1
        isUnlocked = false
    }
}
