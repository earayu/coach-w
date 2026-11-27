import CoachKit
import Foundation

/// What the token API hands out for one coach session (server/src/coachw/api/app.py).
struct SessionGrant: Decodable, Sendable {
    let serverUrl: String
    let room: String
    let token: String
    let maxSessionS: Int
}

/// One voice provider reported by `POST /v1/providers`.
struct ServerProvider: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let kind: String
    let configured: Bool
    let missingEnv: String
}

/// Available voice providers and server default from `POST /v1/providers`.
struct ProviderCatalog: Decodable, Sendable, Equatable {
    let defaultProvider: String
    let providers: [ServerProvider]
}

private struct ErrorBody: Decodable {
    let detail: String?
}

enum TokenError: LocalizedError {
    case invalidBaseURL
    case unknownInvite
    case quotaExhausted
    case providerUnavailable(String)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "服务器地址无效"
        case .unknownInvite: "邀请码无效"
        case .quotaExhausted: "今天的语音分钟已经用完"
        case .providerUnavailable(let detail): "语音模型未就绪：\(detail)"
        case .server(let code): "服务器错误（\(code)）"
        }
    }
}

enum TokenClient {
    static func requestSession(
        baseURL: String,
        inviteCode: String,
        athleteID: String,
        cueWriter: String = "",
        voiceProvider: String = ""
    ) async throws -> SessionGrant {
        // http / https only: anything else would send the invite code somewhere unexpected
        guard let base = ServerAddress.parse(baseURL) else { throw TokenError.invalidBaseURL }
        var request = URLRequest(url: base.appending(path: "v1/session"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "invite_code": inviteCode.trimmedForSettings,
            "athlete_id": athleteID,
            "cue_writer": cueWriter,
            "voice_provider": voiceProvider,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(SessionGrant.self, from: data)
        case 400:
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data).detail) ?? "服务端未配置该语音模型"
            throw TokenError.providerUnavailable(detail)
        case 401: throw TokenError.unknownInvite
        case 429: throw TokenError.quotaExhausted
        default: throw TokenError.server(status)
        }
    }

    static func fetchProviders(baseURL: String, inviteCode: String) async throws -> ProviderCatalog {
        guard let base = ServerAddress.parse(baseURL) else { throw TokenError.invalidBaseURL }
        var request = URLRequest(url: base.appending(path: "v1/providers"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "invite_code": inviteCode.trimmedForSettings,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(ProviderCatalog.self, from: data)
        case 401: throw TokenError.unknownInvite
        default: throw TokenError.server(status)
        }
    }
}
