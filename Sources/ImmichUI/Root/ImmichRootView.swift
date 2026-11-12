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
                ProgressView(tr("Opening Library…"))
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
                    Label(tr("Saved Connection Unavailable"), systemImage: "lock.trianglebadge.exclamationmark")
                } description: { Text(model.error ?? tr("Try again.")) } actions: {
                    Button(tr("Try Again")) { Task { await model.retryRestore() } }
                    Button(tr("Remove Saved Connection"), role: .destructive) { Task { await model.signOut() } }
                        .disabled(model.isSigningOut)
                }
            }
        }
        .task { await model.restore() }
        // Dates and numbers SwiftUI formats itself follow the app's language too.
        .environment(\.locale, Localization.locale)
        .alert(tr("Couldn't Sign Out"), isPresented: Binding(
            get: { model.phase == .signedIn && model.error != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button(tr("OK"), role: .cancel) { model.dismissError() }
        } message: { Text(model.error ?? tr("Please try again.")) }
    }
}

private struct ImmichTabs: View {
    let session: ImmichSession
    let isSigningOut: Bool
    let signOut: () -> Void
    @State private var selection: AppTab = .library
    /// Bumped when the Library tab is tapped while it is already open.
    @State private var libraryReselections = 0

    enum AppTab: Hashable { case library, collections, search }

    /// Tapping the open tab again calls the setter with the same value. iOS would scroll the
    /// Library to its top, which is the oldest photo; Photos goes to the newest, so we do too.
    private var tabSelection: Binding<AppTab> {
        Binding(get: { selection }, set: { tab in
            guard !session.library.isTrashing else { return }
            if tab == selection && tab == .library { libraryReselections += 1 }
            selection = tab
        })
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab(tr("Library"), systemImage: "photo.on.rectangle", value: AppTab.library) {
                NavigationStack {
                    LibraryGridView(model: session.library, headerStyle: .largeTitle, accessory: AnyView(accountMenu),
                                    scrollToNewestTrigger: libraryReselections, allowsTrash: true)
                }
            }
            Tab(tr("Collections"), systemImage: "rectangle.stack", value: AppTab.collections) {
                NavigationStack {
                    CollectionsView(service: session.service, loader: session.loader, accessory: AnyView(accountMenu))
                }
                // These hidden stacks own cached searches/collections. Recreate them after a
                // library mutation so old snapshots cannot offer an item moved to trash.
                .id(session.library.trashRevision)
            }
            // Search sits apart from the other tabs at the trailing edge, like Photos.
            Tab(tr("Search"), systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack { SearchView(model: session.search) }
                    .id(session.library.trashRevision)
            }
        }
        .onChange(of: session.library.trashRevision) { _, _ in
            session.search.invalidateAfterLibraryMutation()
        }
        .modifier(MinimizeTabBarOnScroll())
    }

    private var accountMenu: some View {
        Menu {
            Button(tr("Sign Out"), systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: signOut)
                .disabled(isSigningOut || session.library.isTrashing)
        } label: {
            Label(tr("Account"), systemImage: "person.crop.circle")
                .labelStyle(.iconOnly)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .photosGlass(in: Circle())
    }
}

/// iOS 26: the tab bar shrinks while scrolling down, like Photos.
private struct MinimizeTabBarOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#Preview("Immich") { ImmichRootView(service: MockImmichService.preview) }
#Preview("Sign in") {
    ImmichRootView(model: RootModel(store: CredentialStore(storage: InMemorySecureStorage()), makeService: { _ in MockImmichService.preview }))
}
#Preview("Tabs") {
    ImmichTabs(session: ImmichSession(service: MockImmichService.preview, disk: nil), isSigningOut: false, signOut: {})
}
