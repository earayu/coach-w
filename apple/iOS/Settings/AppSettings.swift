import CoachKit
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

    /// As typed. Stored, compared and sent trimmed: pasted codes often carry a trailing newline.
    var inviteCode: String {
        didSet { Keychain.set("invite_code", inviteCode.trimmedForSettings) }
    }

    /// Token API base URL, e.g. `https://coach.example.com` or `http://192.168.1.10:8000` in development.
    var apiBaseURL: String {
        didSet { UserDefaults.standard.set(apiBaseURL.trimmedForSettings, forKey: "api_base_url") }
    }

    /// Voice provider chosen by the athlete (`""` = server default `COACHW_PROVIDER`).
    var voiceProvider: String {
        didSet { UserDefaults.standard.set(voiceProvider, forKey: "voice_provider") }
    }

    /// Developer setting (testing phase, spec 4.2.1): the text model that writes the coach's
    /// cues before the realtime model speaks them; "" lets the realtime model speak alone.
    var cueWriter: String {
        didSet { UserDefaults.standard.set(cueWriter, forKey: "cue_writer") }
    }

    /// The coach connects by itself when a workout starts (spec 7.6). Off: the watch records and
    /// buzzes only, and the coach comes when called.
    var coachJoinsWorkouts: Bool {
        didSet { UserDefaults.standard.set(coachJoinsWorkouts, forKey: "coach_joins_workouts") }
    }

    /// Whether starting a workout should bring the coach along right now.
    var wantsCoachForWorkout: Bool { coachJoinsWorkouts && isConfigured }

    /// Fallback voice provider list when offline or talking to an older server
    /// (`server/src/coachw/providers/__init__.py` PROVIDER_SPECS).
    static let voiceProviders: [(id: String, title: String, detail: String)] = [
        ("qwen", "Qwen Realtime", "通义千问原生实时语音（DashScope）"),
        ("openrouter", "OpenRouter 语音", "用 OpenRouter Key 跑 STT + LLM + TTS（OpenRouter 无 /v1/realtime）"),
        ("openai", "OpenAI Realtime", "OpenAI 原生实时语音（支持自定义 Base URL）"),
        ("gemini", "Gemini Live", "Google 原生实时语音"),
        ("xai", "xAI Grok Voice", "Grok 原生实时语音"),
    ]

    /// What the server offers (`server/src/coachw/session.py` DEFAULT_WRITER_MODELS).
    static let cueWriters: [(id: String, title: String, detail: String)] = [
        ("", "实时模型直接说", "最快，但不太会结合常识看数据"),
        ("qwen3.8-flash", "Qwen3.8 Flash 先写稿", "约慢 1 秒，懂常识"),
        ("qwen3.8-max", "Qwen3.8 Max 先写稿", "约慢 1.5 秒，最懂常识"),
        ("deepseek-v4.1-flash", "DeepSeek V4.1 Flash 先写稿", "约慢 0.6 秒"),
    ]
    static let defaultCueWriter = "qwen3.8-flash"

    var trimmedInviteCode: String { inviteCode.trimmedForSettings }

    /// Only `http` / `https` with a host counts as configured.
    var serverURL: URL? { ServerAddress.parse(apiBaseURL) }

    var isConfigured: Bool { !trimmedInviteCode.isEmpty && serverURL != nil }

    /// Drops surrounding whitespace from the in-memory values too, e.g. when the settings close.
    func normalize() {
        if inviteCode != trimmedInviteCode { inviteCode = trimmedInviteCode }
        let url = apiBaseURL.trimmedForSettings
        if apiBaseURL != url { apiBaseURL = url }
    }

    private init() {
        if let existing = Keychain.get("athlete_id") {
            athleteID = existing
        } else {
            athleteID = UUID().uuidString.lowercased()
            Keychain.set("athlete_id", athleteID)
        }
        inviteCode = (Keychain.get("invite_code") ?? "").trimmedForSettings
        apiBaseURL = (UserDefaults.standard.string(forKey: "api_base_url") ?? "").trimmedForSettings
        voiceProvider = UserDefaults.standard.string(forKey: "voice_provider") ?? ""
        cueWriter = UserDefaults.standard.string(forKey: "cue_writer") ?? Self.defaultCueWriter
        coachJoinsWorkouts = UserDefaults.standard.object(forKey: "coach_joins_workouts") as? Bool ?? true
        #if DEBUG
        // Development builds can be configured at launch, e.g.
        // `xcrun devicectl device process launch --environment-variables '{"COACHW_API_BASE_URL": "..."}'`
        let env = ProcessInfo.processInfo.environment
        if let url = env["COACHW_API_BASE_URL"]?.trimmedForSettings {
            apiBaseURL = url
            UserDefaults.standard.set(url, forKey: "api_base_url")
        }
        if let code = env["COACHW_INVITE_CODE"]?.trimmedForSettings {
            inviteCode = code
            Keychain.set("invite_code", code)
        }
        if let provider = env["COACHW_VOICE_PROVIDER"]?.trimmedForSettings {
            voiceProvider = provider
            UserDefaults.standard.set(provider, forKey: "voice_provider")
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
