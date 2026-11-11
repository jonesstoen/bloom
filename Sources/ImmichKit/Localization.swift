import Foundation

/// The app's language: Norwegian Bokmål when the device prefers Norwegian (nb, no or nn),
/// otherwise English (the keys). Chosen from the device's preferred languages, so it works
/// without the app target declaring its localizations.
public enum Localization {
    /// Forces a language ("en" or "nb"), e.g. in tests on a Norwegian Mac. `nil`: the device's.
    nonisolated(unsafe) public static var languageOverride: String?

    /// `"nb"` or `"en"`.
    public static var languageCode: String {
        let preferred = (languageOverride ?? Locale.preferredLanguages.first ?? "en").lowercased()
        let code = preferred.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "en"
        return ["nb", "no", "nn"].contains(code) ? "nb" : "en"
    }

    /// The locale for dates and numbers, matching the language of the texts.
    public static var locale: Locale {
        languageCode == "nb" ? Locale(identifier: "nb_NO") : (languageOverride == nil ? Locale.current : Locale(identifier: "en_US"))
    }

    /// `key` translated from `bundle`'s `<language>.lproj/Localizable.strings`, or `key` itself
    /// (the English text) when there is no translation.
    public static func string(_ key: String, bundle: Bundle) -> String {
        guard languageCode != "en",
              let path = bundle.path(forResource: languageCode, ofType: "lproj"),
              let localized = Bundle(path: path) else { return key }
        return localized.localizedString(forKey: key, value: key, table: nil)
    }

    /// A translated format string (`%@`, `%lld`) filled in with `arguments`.
    public static func format(_ key: String, bundle: Bundle, _ arguments: [CVarArg]) -> String {
        String(format: string(key, bundle: bundle), locale: locale, arguments: arguments)
    }
}

/// ImmichKit's own texts (errors, memory titles).
func tr(_ key: String) -> String { Localization.string(key, bundle: .module) }
func tr(_ key: String, _ arguments: CVarArg...) -> String { Localization.format(key, bundle: .module, arguments) }
