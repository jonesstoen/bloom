import ImmichKit
import SwiftUI

/// Sign-in screen: server URL and API key, a connection test, then the credentials go to the Keychain.
///
/// Styled like a system settings form (grouped list, system fonts, SF Symbols).
public struct LoginView: View {
    @State private var model: LoginModel
    @FocusState private var focus: Field?

    private enum Field: Hashable { case server, apiKey }

    public init(model: LoginModel) {
        _model = State(initialValue: model)
    }

    /// A login screen that tests against the live server, saves to the Keychain and then calls `onConnect`.
    public init(store: CredentialStore = CredentialStore(), onConnect: @escaping @MainActor (ServerCredentials) -> Void) {
        self.init(model: LoginModel(store: store, onConnect: onConnect))
    }

    public var body: some View {
        NavigationStack {
            Form {
                header
                fields
                if let error = model.error {
                    errorSection(error)
                }
                if case .connected(let info) = model.phase {
                    connectedSection(info)
                }
                connectSection
            }
            .formStyle(.grouped)
            .disabled(model.isConnecting)
            .navigationTitle(tr("Connect to Immich"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .animation(.default, value: model.phase)
        }
    }

    private var header: some View {
        Section {
            VStack(spacing: 12) {
                BloomMark()
                    .frame(width: 76, height: 76)
                Text(tr("Bloom"))
                    .font(.largeTitle.bold())
                Text(tr("Sign in to your Immich server to browse your photos and videos."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    private var fields: some View {
        Section {
            TextField(tr("Server URL"), text: $model.server, prompt: Text(tr("https://photos.example.com")))
                .textContentType(.URL)
                .autocorrectionDisabled()
                .focused($focus, equals: .server)
                .submitLabel(.next)
                .onSubmit { focus = .apiKey }
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
            SecureField(tr("API Key"), text: $model.apiKey, prompt: Text(tr("API Key")))
                .textContentType(.password)
                .autocorrectionDisabled()
                .focused($focus, equals: .apiKey)
                .submitLabel(.go)
                .onSubmit(connect)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text(tr("Server"))
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if model.isRefusedHTTP {
                    Label(tr("Bloom only uses http on your own network or Tailscale. Use https for this server."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if model.isUnencrypted {
                    Label(tr("Unencrypted, so only for a server on your own network or Tailscale."), systemImage: "lock.open")
                }
                Text(tr("Create an API key in the Immich web app under Account Settings › API Keys. It is stored in the Keychain on this device."))
            }
        }
    }

    private func errorSection(_ error: LoginError) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.title)
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func connectedSection(_ info: ConnectionInfo) -> some View {
        Section {
            Label {
                Text(tr("Connected to Immich %@", info.version.description))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var connectSection: some View {
        Section {
            Button(action: connect) {
                HStack {
                    Spacer()
                    if model.isConnecting {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text(tr("Connecting…"))
                    } else {
                        Text(tr("Connect"))
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
            }
            .disabled(!model.canConnect)
        }
    }

    private func connect() {
        guard model.canConnect else { return }
        focus = nil
        model.connect()
    }
}

// MARK: - Previews

/// Preview tester: any key works except "wrong"; servers containing "offline" are unreachable.
private func previewTester() -> ConnectionTester {
    ConnectionTester { credentials in
        let mock = MockImmichService(library: .small, latency: .milliseconds(600))
        Task {
            if credentials.serverURL.host()?.contains("offline") == true {
                await mock.setFailure(.network("The request timed out."))
            }
            if credentials.apiKey == "wrong" {
                await mock.setRejectsAPIKey(true)
            }
        }
        return mock
    }
}

#Preview("Empty") {
    LoginView(model: LoginModel(store: CredentialStore(storage: InMemorySecureStorage()), tester: previewTester()))
}

#Preview("Wrong key") {
    let model = LoginModel(
        server: "https://photos.example.com",
        apiKey: "wrong",
        store: CredentialStore(storage: InMemorySecureStorage()),
        tester: previewTester()
    )
    return LoginView(model: model)
        .task { await model.connectNow() }
}
