import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Which Home Screen icon Bloom uses. `automatic` is the primary icon, whose light, dark and tinted
/// appearances follow the Home Screen setting; the others are alternate icon sets in the app target
/// that keep one look.
enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic, light, dark, tinted

    var id: Self { self }

    /// The icon set's name in the app target's asset catalog (`nil` = the primary `AppIcon`).
    var alternateIconName: String? {
        switch self {
        case .automatic: nil
        case .light: "AppIcon-Light"
        case .dark: "AppIcon-Dark"
        case .tinted: "AppIcon-Tinted"
        }
    }

    /// An unknown name (an icon set from an older build) counts as the primary icon.
    init(alternateIconName: String?) {
        self = Self.allCases.first { $0.alternateIconName == alternateIconName } ?? .automatic
    }

    var title: String {
        switch self {
        case .automatic: tr("Automatic")
        case .light: tr("Light")
        case .dark: tr("Dark")
        case .tinted: tr("Tinted")
        }
    }
}

/// Reads and changes the app's Home Screen icon.
@MainActor
protocol AppIconSwitching: AnyObject {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func setAlternateIconName(_ name: String?) async throws
}

/// The real icon, through UIApplication. Unsupported on macOS.
@MainActor
final class SystemAppIconSwitcher: AppIconSwitching {
    var supportsAlternateIcons: Bool {
        #if os(iOS)
        UIApplication.shared.supportsAlternateIcons
        #else
        false
        #endif
    }

    var alternateIconName: String? {
        #if os(iOS)
        UIApplication.shared.alternateIconName
        #else
        nil
        #endif
    }

    func setAlternateIconName(_ name: String?) async throws {
        #if os(iOS)
        try await UIApplication.shared.setAlternateIconName(name)
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}

/// For tests and previews: remembers every request, optionally fails.
@MainActor
final class InMemoryAppIconSwitcher: AppIconSwitching {
    private(set) var current: String?
    private(set) var requests: [String?] = []
    let supportsAlternateIcons: Bool
    var failure: (any Error)?

    init(current: String?, supported: Bool = true) {
        self.current = current
        self.supportsAlternateIcons = supported
    }

    var alternateIconName: String? { current }

    func setAlternateIconName(_ name: String?) async throws {
        requests.append(name)
        if let failure { throw failure }
        current = name
    }
}

/// The icon picker's state in About Bloom.
@MainActor
@Observable
final class AppIconModel {
    private(set) var selection: AppIconChoice
    private(set) var isChanging = false
    private(set) var error: String?
    let isSupported: Bool
    @ObservationIgnored private let switcher: any AppIconSwitching

    init(switcher: any AppIconSwitching) {
        self.switcher = switcher
        isSupported = switcher.supportsAlternateIcons
        selection = AppIconChoice(alternateIconName: switcher.alternateIconName)
    }

    func select(_ choice: AppIconChoice) async {
        guard choice != selection, !isChanging else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            try await switcher.setAlternateIconName(choice.alternateIconName)
            selection = choice
        } catch {
            self.error = error.localizedDescription
        }
    }

    func dismissError() { error = nil }
}
