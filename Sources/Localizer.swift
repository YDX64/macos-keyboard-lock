import Foundation

/// The language the user picked in the app. `system` follows macOS; English is the default
/// whenever the system language is not one of the supported ones.
enum LanguageChoice: String, CaseIterable, Identifiable {
    case system, en, tr
    var id: String { rawValue }
}

/// Minimal localization layer on top of ordinary `Localizable.strings` files
/// (`Resources/<code>.lproj/Localizable.strings`). To add a language, copy `en.lproj`,
/// translate it and add the code to `Localizer.supported` (see CONTRIBUTING.md).
enum Localizer {
    static let supported = ["en", "tr"]
    private static let defaultsKey = "KeyboardLockLanguage"
    private static var bundles: [String: Bundle] = [:]

    static var choice: LanguageChoice {
        get {
            LanguageChoice(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    /// The language code actually used right now ("en" or "tr").
    static var resolvedCode: String {
        switch choice {
        case .en: return "en"
        case .tr: return "tr"
        case .system:
            return Bundle.preferredLocalizations(from: supported, forPreferences: Locale.preferredLanguages).first
                ?? "en"
        }
    }

    private static func bundle(for code: String) -> Bundle? {
        if let cached = bundles[code] { return cached }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path) else { return nil }
        bundles[code] = b
        return b
    }

    static func string(_ key: String) -> String {
        let code = resolvedCode
        let missing = "\u{0}missing"
        if let s = bundle(for: code)?.localizedString(forKey: key, value: missing, table: nil), s != missing {
            return s
        }
        // Fall back to English, then to the key itself.
        if let s = bundle(for: "en")?.localizedString(forKey: key, value: missing, table: nil), s != missing {
            return s
        }
        return key
    }
}

/// Translates `key` and fills in `%@` / `%d` placeholders.
func tr(_ key: String, _ args: CVarArg...) -> String {
    let format = Localizer.string(key)
    return args.isEmpty ? format : String(format: format, arguments: args)
}
