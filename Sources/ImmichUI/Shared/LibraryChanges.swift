import SwiftUI

/// The Allow Changes setting: off until the user turns it on in the account menu, so Bloom only
/// views a library it hasn't been told it may change. `EditGuardedService` enforces it; views
/// read `allowsLibraryChanges` to hide favorite, trash, restore and album controls.
enum LibraryChanges {
    static let storageKey = "bloom.allowsLibraryChanges"

    static var storedValue: Bool { UserDefaults.standard.bool(forKey: storageKey) }
}

extension EnvironmentValues {
    /// Whether controls that change the library on the server are shown.
    @Entry var allowsLibraryChanges = false
}
