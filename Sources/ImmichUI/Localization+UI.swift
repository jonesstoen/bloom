import Foundation
import ImmichKit

/// ImmichUI's texts, translated from its own `Localizable.strings` (see `Localization`).
@usableFromInline func tr(_ key: String) -> String { Localization.string(key, bundle: .module) }
@usableFromInline func tr(_ key: String, _ arguments: CVarArg...) -> String { Localization.format(key, bundle: .module, arguments) }
