import Foundation

/// `coach.status`, wire protocol v1 (docs/spec.md 6.3): iPhone → watch only, over the mirrored
/// workout session. Tells the watch whether the voice coach is with the athlete (spec 7.6).
///
/// The phone sends it on every change and again every 15 seconds; a status past
/// `expiresAt` means the phone went quiet and the watch no longer knows.
public struct CoachStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Connected: the coach hears the athlete.
        case online
        /// Getting a token, joining or rejoining.
        case connecting
        /// The link is down; the phone speaks key cues itself (spec 7.4).
        case offline
        /// No coach: not connected, hung up or refused.
        case off

        /// A state this build does not know yet reads as no coach.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .off
        }
    }

    public static let lifetime: TimeInterval = 90

    public var v: Int
    /// Phone time, Unix milliseconds.
    public var ts: Int64
    /// Phone time, Unix milliseconds.
    public var expiresAt: Int64
    public var coachStatus: State

    public init(_ state: State, at date: Date) {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        self.v = MetricsFrame.protocolVersion
        self.ts = ms
        self.expiresAt = ms + Int64(Self.lifetime * 1000)
        self.coachStatus = state
    }

    enum CodingKeys: String, CodingKey {
        case v, ts
        case expiresAt = "expires_at"
        case coachStatus = "coach_status"
    }

    public func isExpired(at date: Date) -> Bool {
        Int64((date.timeIntervalSince1970 * 1000).rounded()) >= expiresAt
    }
}

extension CoachStatus {
    public static func decode(_ data: Data) throws -> CoachStatus {
        let status = try JSONDecoder().decode(CoachStatus.self, from: data)
        guard status.v == MetricsFrame.protocolVersion else { throw ProtocolError.unsupportedVersion(status.v) }
        return status
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
