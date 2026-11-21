import Foundation
import Observation
import Security

/// Small Keychain wrapper for the few secrets the app keeps (spec 3.1).
enum Keychain {
    private static let service = "com.earayu.coachw"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        // Readable while locked after first unlock: voice sessions run with the screen off.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// Who this athlete is and how to reach the server.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Generated once per install, kept in the Keychain. The only identity the server sees.
    let athleteID: String

    var inviteCode: String {
        didSet { Keychain.set("invite_code", inviteCode.trimmingCharacters(in: .whitespaces)) }
    }

    /// Token API base URL, e.g. `https://coach.example.com` or `http://192.168.1.10:8000` in development.
    var apiBaseURL: String {
        didSet { UserDefaults.standard.set(apiBaseURL, forKey: "api_base_url") }
    }

    var isConfigured: Bool { !inviteCode.isEmpty && URL(string: apiBaseURL)?.host != nil }

    private init() {
        if let existing = Keychain.get("athlete_id") {
            athleteID = existing
        } else {
            athleteID = UUID().uuidString.lowercased()
            Keychain.set("athlete_id", athleteID)
        }
        inviteCode = Keychain.get("invite_code") ?? ""
        apiBaseURL = UserDefaults.standard.string(forKey: "api_base_url") ?? ""
        #if DEBUG
        // Development builds can be configured at launch, e.g.
        // `xcrun devicectl device process launch --environment-variables '{"COACHW_API_BASE_URL": "..."}'`
        let env = ProcessInfo.processInfo.environment
        if let url = env["COACHW_API_BASE_URL"] {
            apiBaseURL = url
            UserDefaults.standard.set(url, forKey: "api_base_url")
        }
        if let code = env["COACHW_INVITE_CODE"] {
            inviteCode = code
            Keychain.set("invite_code", code)
        }
        #endif
    }

    #if DEBUG
    /// Development builds connect to the coach right after launch when this is set.
    var autoConnect: Bool { ProcessInfo.processInfo.environment["COACHW_AUTOCONNECT"] == "1" }
    #else
    var autoConnect: Bool { false }
    #endif
}
