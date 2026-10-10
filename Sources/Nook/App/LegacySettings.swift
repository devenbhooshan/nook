import Foundation

/// Pre-release builds used the bundle ID `app.nook.mail`, so their preferences live in that defaults domain.
/// Copy them over once, so switching identifiers doesn't reset anyone's setup. Mail lives in Application
/// Support/Nook either way and needs no migration.
enum LegacySettings {
    static let legacyDomain = "app.nook.mail"
    static let migratedKey = "migratedFromLegacyDomain"

    static func migrateIfNeeded(into defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defer { defaults.set(true, forKey: migratedKey) }
        guard let legacy = UserDefaults(suiteName: legacyDomain)?.persistentDomain(forName: legacyDomain) else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil && !key.hasPrefix("NS") && !key.hasPrefix("com.apple") {
            defaults.set(value, forKey: key)
        }
    }
}
