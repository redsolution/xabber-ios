import Foundation

/// Desired registration policy. Partial payloads use the XEP-PUSH `summary` value.
enum PushPayloadMode: String, CaseIterable {
    case full
    case summary
}

/// Both payload formats remain valid regardless of the preference or server support.
enum PushPayloadPreferences {
    static let key = "notification_push_payload_mode"

    static var current: PushPayloadMode {
        read(defaults: sharedDefaults)
    }

    static func read(defaults: UserDefaults?) -> PushPayloadMode {
        defaults?.string(forKey: key).flatMap(PushPayloadMode.init(rawValue:)) ?? .summary
    }

    static func set(_ mode: PushPayloadMode) {
        set(mode, defaults: sharedDefaults) {
            for account in AccountManager.shared.users {
                account.action { account, _ in account.refreshPushHTTPGrantIfNeeded() }
            }
        }
    }

    static func set(_ mode: PushPayloadMode, defaults: UserDefaults?, refreshRegistrations: () -> Void) {
        guard let defaults, read(defaults: defaults) != mode else { return }
        defaults.set(mode.rawValue, forKey: key)
        refreshRegistrations()
    }

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: CredentialsManager.uniqueAccessGroup())
    }
}
