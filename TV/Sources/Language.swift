import Foundation

// The app's language, as the web app chooses it (lib/i18n.ts): its synced `language` setting, a
// catalogue's locale or `auto` for the system's language among those the app has. Every string the
// app shows goes through `L`, which reads the chosen language's table, so a change applies as soon as
// the pages are drawn again, without waiting for the system's language or a restart.

enum AppLanguage {
    /// The web app's catalogues that it lists (at least half translated), by its locale ids, with
    /// the folder each one's table is in here.
    static let catalogues: [(id: String, folder: String)] = [
        ("en-GB", "en"), ("ar", "ar"), ("de", "de"), ("el", "el"), ("es", "es"), ("fr", "fr"),
        ("id", "id"), ("it", "it"), ("ms", "ms"), ("pl", "pl"), ("pt-BR", "pt-BR"), ("pt", "pt-PT"),
        ("ro", "ro"), ("tr", "tr"), ("zh-Hans", "zh-Hans"),
    ]

    /// The setting as chosen, kept on the device too, so the screens before sign-in use it.
    private static let savedKey = "interface.language"

    /// The catalogue in use, by the web app's id.
    private(set) static var current = resolve(UserDefaults.standard.string(forKey: savedKey) ?? "auto")
    private(set) static var bundle = tableBundle(for: current)
    /// For dates, numbers and language names: the system's own region where it speaks the app's
    /// language, so British English still shows US dates in the US, as the web app does.
    private(set) static var locale = formatLocale(for: current)

    /// Follows the setting; true when the language changed, so the pages are drawn again.
    @discardableResult
    static func apply(_ choice: String) -> Bool {
        UserDefaults.standard.set(choice, forKey: savedKey)
        let next = resolve(choice)
        guard next != current else { return false }
        current = next
        bundle = tableBundle(for: next)
        locale = formatLocale(for: next)
        return true
    }

    /// A catalogue's id for a choice: itself where there is one, else the system's language.
    static func resolve(_ choice: String) -> String {
        if catalogues.contains(where: { $0.id == choice }) { return choice }
        return system
    }

    /// The system's language, among the catalogues; else English.
    static var system: String {
        let folders = catalogues.map(\.folder)
        let found = Bundle.preferredLocalizations(from: folders, forPreferences: Locale.preferredLanguages).first
        return catalogues.first { $0.folder == found }?.id ?? "en-GB"
    }

    /// Whether the language is written right to left (Arabic), which mirrors the app's layout.
    static var rightToLeft: Bool {
        Locale.Language(identifier: current).characterDirection == .rightToLeft
    }

    /// A catalogue's language, in that language, as a list of languages shows it.
    static func name(_ id: String) -> String {
        let locale = Locale(identifier: id)
        let name = locale.localizedString(forIdentifier: id) ?? id
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    private static func tableBundle(for id: String) -> Bundle {
        let folder = catalogues.first { $0.id == id }?.folder ?? "en"
        return Bundle.main.path(forResource: folder, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    private static func formatLocale(for id: String) -> Locale {
        let language = Locale(identifier: id).language.languageCode
        let match = Locale.preferredLanguages.first { Locale(identifier: $0).language.languageCode == language }
        return Locale(identifier: match ?? id)
    }
}

/// A string in the app's language, by its English text.
func L(_ english: String) -> String {
    AppLanguage.bundle.localizedString(forKey: english, value: english, table: nil)
}

/// A string in the app's language with values put in, by its English format: `%@` for text, `%ld`
/// for a whole number. A count's plural forms come from the language's stringsdict.
func L(_ english: String, _ values: CVarArg...) -> String {
    String(format: L(english), locale: AppLanguage.locale, arguments: values)
}

extension UnitPoint {
    /// The side a line of text starts on, and the one it ends on: left and right, or the other way
    /// round in a language written right to left, for gradients that follow the layout.
    static var start: UnitPoint { AppLanguage.rightToLeft ? .trailing : .leading }
    static var end: UnitPoint { AppLanguage.rightToLeft ? .leading : .trailing }
}
