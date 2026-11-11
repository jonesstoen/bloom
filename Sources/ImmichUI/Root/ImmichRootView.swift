import ImmichKit
import SwiftUI

/// The only view an app target needs. Restores Keychain credentials or presents LoginView.
public struct ImmichRootView: View {
    @State private var model: RootModel

    public init() { _model = State(initialValue: RootModel()) }

    public init(model: RootModel) { _model = State(initialValue: model) }

    /// A self-contained mock/demo session; never reads the real Keychain.
    public init(service: any ImmichService) {
        _model = State(initialValue: RootModel(previewService: service))
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("Opening Library…")
            case .signedOut:
                LoginView(model: model.makeLoginModel())
            case .signedIn:
                if let session = model.session {
                    ImmichTabs(session: session, isSigningOut: model.isSigningOut) {
                        Task { await model.signOut() }
                    }
                    .id(session.id)
                }
            case .failed:
                ContentUnavailableView {
                    Label("Saved Connection Unavailable", systemImage: "lock.trianglebadge.exclamationmark")
                } description: { Text(model.error ?? "Try again.") } actions: {
                    Button("Try Again") { Task { await model.retryRestore() } }
                    Button("Remove Saved Connection", role: .destructive) { Task { await model.signOut() } }
                        .disabled(model.isSigningOut)
                }
            }
        }
        .task { await model.restore() }
        .alert("Couldn't Sign Out", isPresented: Binding(
            get: { model.phase == .signedIn && model.error != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: { Text(model.error ?? "Please try again.") }
    }
}

private struct ImmichTabs: View {
    let session: ImmichSession
    let isSigningOut: Bool
    let signOut: () -> Void

    var body: some View {
        TabView {
            NavigationStack {
                LibraryGridView(model: session.library)
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Menu {
                                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: signOut)
                                    .disabled(isSigningOut)
                            } label: { Label("Account", systemImage: "person.crop.circle") }
                        }
                    }
            }
            .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
            NavigationStack { AlbumsView(service: session.service, loader: session.loader) }
                .tabItem { Label("Albums", systemImage: "rectangle.stack") }
            NavigationStack { PeopleView(service: session.service, loader: session.loader) }
                .tabItem { Label("People", systemImage: "person.2") }
            NavigationStack { SearchView(service: session.service, loader: session.loader) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
        }
    }
}

#Preview("Immich") { ImmichRootView(service: MockImmichService.preview) }
#Preview("Sign in") {
    ImmichRootView(model: RootModel(store: CredentialStore(storage: InMemorySecureStorage()), makeService: { _ in MockImmichService.preview }))
}
#Preview("Tabs") {
    ImmichTabs(session: ImmichSession(service: MockImmichService.preview, disk: nil), isSigningOut: false, signOut: {})
}
