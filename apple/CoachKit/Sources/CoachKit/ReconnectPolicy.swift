import Foundation

/// When to try the voice coach again after the link dropped (docs/spec.md 7.4).
public struct ReconnectPolicy: Sendable {
    public enum Drop: Sendable, Equatable {
        /// Network trouble or a server hiccup: try again.
        case network
        /// The server ended the session on purpose (time cap, removed) or refused it (bad invite,
        /// daily minutes used up): retrying would not help.
        case final
    }

    public let delays: [TimeInterval]

    public init(delays: [TimeInterval] = [1, 2, 5, 10, 20, 30]) {
        self.delays = delays.isEmpty ? [30] : delays
    }

    /// Delay before retry number `attempt` (0-based); the last delay repeats.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        delays[min(max(0, attempt), delays.count - 1)]
    }

    public func shouldRetry(_ drop: Drop) -> Bool { drop == .network }

    /// Token API answers: 401 / 422 / 429 are final, anything else (5xx, no answer) is network.
    public static func drop(forHTTPStatus status: Int) -> Drop {
        (400..<500).contains(status) && status != 408 ? .final : .network
    }
}
