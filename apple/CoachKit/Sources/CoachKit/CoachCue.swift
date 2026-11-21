import Foundation

/// How urgent a cue is, highest first (docs/spec.md 4.5).
public enum CuePriority: String, Codable, Sendable {
    case emergency
    case correction
    case milestone
    case companion
}

/// Watch haptic for a cue. Mirrors `WKHapticType` without importing WatchKit.
public enum CueHaptic: String, Codable, Sendable {
    case notification
    case directionUp = "direction_up"
    case directionDown = "direction_down"
    case success
    case failure
    case retry
    case start
    case stop
    case click

    /// A haptic this build does not know yet falls back to the generic one.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CueHaptic(rawValue: raw) ?? .notification
    }
}

/// `coach.cue`, wire protocol v1 (docs/spec.md 6.3): server → iPhone → watch.
///
/// The watch buzzes and shows `text` briefly. Cues past `expiresAt` are dropped, never played late.
public struct CoachCue: Codable, Equatable, Sendable {
    /// LiveKit data channel topic, server → iPhone.
    public static let topic = "coach.cue"

    public var v: Int
    public var id: String
    /// Server time, Unix milliseconds.
    public var ts: Int64
    /// Server time, Unix milliseconds. Receivers drop the cue from this moment on.
    public var expiresAt: Int64
    public var priority: CuePriority
    public var kind: String?
    public var haptic: CueHaptic?
    /// Short display copy for the watch.
    public var text: String?

    public init(
        id: String,
        ts: Int64,
        expiresAt: Int64,
        priority: CuePriority,
        kind: String? = nil,
        haptic: CueHaptic? = nil,
        text: String? = nil
    ) {
        self.v = MetricsFrame.protocolVersion
        self.id = id
        self.ts = ts
        self.expiresAt = expiresAt
        self.priority = priority
        self.kind = kind
        self.haptic = haptic
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case v, id, ts, priority, kind, haptic, text
        case expiresAt = "expires_at"
    }

    public func isExpired(at date: Date) -> Bool {
        Int64((date.timeIntervalSince1970 * 1000).rounded()) >= expiresAt
    }

    /// How long the cue may still be shown, never negative.
    public func remaining(at date: Date) -> TimeInterval {
        max(0, Double(expiresAt) / 1000 - date.timeIntervalSince1970)
    }
}

extension CoachCue {
    public static func decode(_ data: Data) throws -> CoachCue {
        let cue = try JSONDecoder().decode(CoachCue.self, from: data)
        guard cue.v == MetricsFrame.protocolVersion else { throw ProtocolError.unsupportedVersion(cue.v) }
        return cue
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
