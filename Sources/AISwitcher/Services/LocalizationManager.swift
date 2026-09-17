import Foundation
import Observation
import SwiftUI

/// App languages the user can force, or `.system` to follow macOS.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .system: return NSLocalizedString("lang.system", comment: "")
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }
}

/// Holds the current language override and resolves localized strings from
/// the right `.lproj` bundle so switching applies immediately, without relaunch.
@MainActor
@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()

    private let key = "app.language"

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: key)
            rebuildBundle()
        }
    }

    private var bundle: Bundle = .main

    init() {
        let saved = UserDefaults.standard.string(forKey: key)
        language = AppLanguage(rawValue: saved ?? "") ?? .system
        rebuildBundle()
    }

    /// Resolve the first application-supported language from macOS preferences.
    ///
    /// - Parameter identifiers: Ordered BCP-47 identifiers from the operating system.
    /// - Returns: `zh-Hans` for any preferred Chinese locale, otherwise English.
    /// This avoids asking an incorrectly packaged resource bundle to enumerate
    /// localizations while the menu-bar application is still launching.
    nonisolated static func preferredSupportedLanguage(from identifiers: [String]) -> String {
        for identifier in identifiers {
            let normalized = identifier.lowercased()
            if normalized.hasPrefix("zh") { return "zh-Hans" }
            if normalized.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    /// Find a known localization directory without triggering bundle enumeration.
    ///
    /// - Parameters:
    ///   - candidates: Supported folder-name variants.
    ///   - base: App or SwiftPM resource bundle.
    /// - Returns: Localized sub-bundle when its directory exists.
    private static func localizedBundle(candidates: [String], in base: Bundle) -> Bundle? {
        guard let resourceURL = base.resourceURL else { return nil }
        let fileManager = FileManager.default
        for candidate in candidates {
            let url = resourceURL.appendingPathComponent("\(candidate).lproj", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }

    /// Rebuild the localized string bundle for the selected language.
    ///
    /// - Side effects: Reads only known `.lproj` paths and replaces the in-memory
    ///   bundle. The packaged app prefers `Bundle.main`; SwiftPM is a development fallback.
    private func rebuildBundle() {
        let code: String
        switch language {
        case .system:
            code = Self.preferredSupportedLanguage(from: Locale.preferredLanguages)
        default:
            code = language.rawValue
        }
        // Resources are shipped in the SwiftPM module bundle. Folder names may
        // be case-variant (e.g. "zh-hans.lproj"), so try a few spellings.
        let candidates = [
            code, code.lowercased(),
            code.replacingOccurrences(of: "-Hans", with: "-hans"),
        ]
        if let localized = Self.localizedBundle(candidates: candidates, in: .main) {
            bundle = localized
            return
        }
        if let localized = Self.localizedBundle(candidates: candidates, in: .module) {
            bundle = localized
            return
        }
        bundle = .main
    }

    func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Locale used for date/number formatting in the current language.
    var locale: Locale {
        switch language {
        case .system: return .current
        case .english: return Locale(identifier: "en_US")
        case .chinese: return Locale(identifier: "zh_Hans")
        }
    }
}

/// Resolve one app-localized string from code that does not own the manager.
@MainActor
func appLocalized(_ key: String) -> String {
    LocalizationManager.shared.string(key)
}
