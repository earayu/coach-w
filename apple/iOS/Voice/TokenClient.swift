import Foundation

/// What the token API hands out for one coach session (server/src/coachw/api/app.py).
struct SessionGrant: Decodable, Sendable {
    let serverUrl: String
    let room: String
    let token: String
    let maxSessionS: Int
}

enum TokenError: LocalizedError {
    case invalidBaseURL
    case unknownInvite
    case quotaExhausted
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "服务器地址无效"
        case .unknownInvite: "邀请码无效"
        case .quotaExhausted: "今天的语音分钟已经用完"
        case .server(let code): "服务器错误（\(code)）"
        }
    }
}

enum TokenClient {
    static func requestSession(baseURL: String, inviteCode: String, athleteID: String) async throws -> SessionGrant {
        guard let base = URL(string: baseURL), base.host != nil else { throw TokenError.invalidBaseURL }
        var request = URLRequest(url: base.appending(path: "v1/session"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["invite_code": inviteCode, "athlete_id": athleteID])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(SessionGrant.self, from: data)
        case 401: throw TokenError.unknownInvite
        case 429: throw TokenError.quotaExhausted
        default: throw TokenError.server(status)
        }
    }
}
