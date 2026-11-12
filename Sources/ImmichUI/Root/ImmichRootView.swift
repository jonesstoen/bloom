import ImmichKit
import SwiftUI

/// The only view an app target needs. Restores Keychain credentials or presents LoginView.
public struct ImmichRootView: View {
    @State private var model: RootModel

    public init() {
        #if DEBUG
        // README screenshots: `-BloomDemo` opens the mock library without touching the Keychain.
        if ProcessInfo.processInfo.arguments.contains("-BloomDemo") {
            _model = State(initialValue: RootModel(previewService: MockImmichService(library: MockLibrary(assetCount: 2400, years: 6))))
            return
        }
        #endif
        _model = State(initialValue: RootModel())
    }

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
    @State private var selection: AppTab = Self.initialTab
    /// Bumped when the Library tab is tapped while it is already open.
    @State private var libraryReselections = 0
    @State private var showsAbout = false
    /// Years / Months / All and the Library's scroll state, shared with the tab bar.
    @State private var libraryChrome = LibraryChrome()

    enum AppTab: Hashable { case library, collections, search }

    /// `-BloomDemoTab collections|search` (Debug builds only), for README screenshots.
    private static var initialTab: AppTab {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-BloomDemoTab"), i + 1 < args.count {
            switch args[i + 1] {
            case "collections": return .collections
            case "search": return .search
            default: break
            }
        }
        #endif
        return .library
    }

    /// Tapping the open tab again calls the setter with the same value. iOS would scroll the
    /// Library to its top, which is the oldest photo; Photos goes to the newest, so we do too.
    private var tabSelection: Binding<AppTab> {
        Binding(get: { selection }, set: { tab in
            guard !session.library.isMutating else { return }
            if tab == selection && tab == .library { libraryReselections += 1 }
            selection = tab
        })
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab(tr("Library"), systemImage: "photo.on.rectangle", value: AppTab.library) {
                NavigationStack {
                    LibraryGridView(model: session.library, headerStyle: .largeTitle, accessory: AnyView(accountMenu),
                                    chrome: libraryChrome, scrollToNewestTrigger: libraryReselections, allowsTrash: true)
                }
            }
            Tab(tr("Collections"), systemImage: "rectangle.stack", value: AppTab.collections) {
                NavigationStack {
                    CollectionsView(service: session.service, loader: session.loader, accessory: AnyView(accountMenu),
                                    onRestore: { assets in try await session.library.restoreToLibrary(assets) },
                                    refreshRevision: session.library.restoreRevision)
                }
                // These hidden stacks own cached searches/collections. Recreate them after a
                // library mutation so old snapshots cannot offer an item moved to trash.
                .id(session.library.trashRevision)
            }
            // Search sits apart from the other tabs at the trailing edge, like Photos.
            Tab(tr("Search"), systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack { SearchView(model: session.search) }
                    .id([session.library.trashRevision, session.library.restoreRevision])
            }
        }
        .onChange(of: session.library.trashRevision) { _, _ in
            session.search.invalidateAfterLibraryMutation()
        }
        .onChange(of: session.library.restoreRevision) { _, _ in
            session.search.invalidateAfterLibraryMutation()
        }
        .modifier(LibraryScaleAccessory(chrome: libraryChrome, isLibraryTab: selection == .library))
        .modifier(MinimizeTabBarOnScroll(direction: LibraryChrome.tabBarMinimizeDirection(
            libraryTab: selection == .library, newestFirst: libraryChrome.newestFirst)))
        .sheet(isPresented: $showsAbout) {
            AboutBloomView(icons: AppIconModel(switcher: SystemAppIconSwitcher()))
        }
    }

    private var accountMenu: some View {
        Menu {
            Button(tr("About Bloom"), systemImage: "info.circle") { showsAbout = true }
            Button(tr("Sign Out"), systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: signOut)
                .disabled(isSigningOut || session.library.isMutating)
        } label: {
            Label(tr("Account"), systemImage: "person.crop.circle")
                .labelStyle(.iconOnly)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .photosGlass(in: Circle())
    }
}

/// iOS 26.1+: Years / Months / All sits in the tab bar like Photos. Hidden at the newest photos;
/// once you scroll away it shows between the minimized tab button and Search (inline), or above
/// the tabs while they are expanded. Earlier systems keep the floating switcher in the grid.
private struct LibraryScaleAccessory: ViewModifier {
    let chrome: LibraryChrome
    let isLibraryTab: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isLibraryTab && chrome.wantsSwitcher) {
                AccessorySwitcher(chrome: chrome)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
@available(iOS 26.0, *)
private struct AccessorySwitcher: View {
    @Bindable var chrome: LibraryChrome
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        LibraryScaleSwitcher(scale: $chrome.scale, showsGlass: false, isCompact: placement == .inline)
            .disabled(chrome.isBlocked)
    }
}
#endif

/// iOS 26: the tab bar shrinks while scrolling, like Photos: in the Library toward older photos.
private struct MinimizeTabBarOnScroll: ViewModifier {
    let direction: LibraryChrome.MinimizeDirection

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(direction == .up ? .onScrollUp : .onScrollDown)
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
