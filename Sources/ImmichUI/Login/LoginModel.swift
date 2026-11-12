import ImmichKit
import Observation
import SwiftUI

/// State behind `LoginView`: the entered server and key, the connection test and the save.
@MainActor
@Observable
public final class LoginModel {
    public enum Phase: Equatable {
        case editing
        case connecting
        case failed(LoginError)
        case connected(ConnectionInfo)
    }

    public var server: String {
        didSet { clearError() }
    }
    public var apiKey: String {
        didSet { clearError() }
    }
    public private(set) var phase: Phase = .editing

    @ObservationIgnored private let tester: ConnectionTester
    @ObservationIgnored private let store: CredentialStore
    @ObservationIgnored private let onConnect: @MainActor (ServerCredentials) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - store: where the credentials are saved after a successful test.
    ///   - tester: defaults to testing against the live server.
    ///   - onConnect: called with the saved credentials.
    public init(
        server: String = "",
        apiKey: String = "",
        store: CredentialStore = CredentialStore(),
        tester: ConnectionTester = ConnectionTester(),
        onConnect: @escaping @MainActor (ServerCredentials) -> Void = { _ in }
    ) {
        self.server = server
        self.apiKey = apiKey
        self.store = store
        self.tester = tester
        self.onConnect = onConnect
    }

    public var isConnecting: Bool { phase == .connecting }

    public var error: LoginError? {
        if case .failed(let error) = phase { return error }
        return nil
    }

    /// The address is plain `http://`: the API key would travel unencrypted.
    public var isUnencrypted: Bool {
        ServerCredentials.normalizedServerURL(from: server)?.scheme == "http"
    }

    /// Plain http to a host outside the user's own network or Tailscale, which Bloom refuses.
    public var isRefusedHTTP: Bool {
        guard let url = ServerCredentials.normalizedServerURL(from: server) else { return false }
        return !ServerCredentials.protectsAPIKey(url)
    }

    public var canConnect: Bool {
        !isConnecting
            && !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Starts testing and saving in the background. The view observes `phase`.
    public func connect() {
        guard !isConnecting else { return }
        task = Task { await connectNow() }
    }

    /// Tests the connection, saves on success and calls `onConnect`. Awaitable for tests.
    public func connectNow() async {
        guard !isConnecting else { return }
        phase = .connecting
        do {
            let info = try await tester.connect(server: server, apiKey: apiKey, store: store)
            guard !Task.isCancelled else {
                phase = .editing
                return
            }
            phase = .connected(info)
            onConnect(info.credentials)
        } catch let error as LoginError {
            phase = .failed(error)
        } catch is CancellationError {
            phase = .editing
        } catch {
            phase = .failed(.serverUnreachable(error.localizedDescription))
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        if isConnecting { phase = .editing }
    }

    private func clearError() {
        if case .failed = phase { phase = .editing }
    }
}
