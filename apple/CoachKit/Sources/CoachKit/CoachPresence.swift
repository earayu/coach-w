import Foundation

/// When the voice coach comes and goes around a workout (docs/spec.md 7.6): the coach follows
/// the workout, so the athlete only starts and ends workouts and never manages the connection.
///
/// Pure bookkeeping: the app reports what happened and asks whether to hang up or rejoin.
public struct CoachPresence: Sendable, Equatable {
    /// After a workout the coach stays for the summary and a chat, and leaves once nobody has
    /// spoken for this long.
    public static let quietAfterWorkout: TimeInterval = 2 * 60
    /// ...and in any case this long after the workout ended.
    public static let maxAfterWorkout: TimeInterval = 10 * 60
    /// Connected before a workout that never starts, with nobody speaking.
    public static let quietBeforeWorkout: TimeInterval = 10 * 60
    /// A session the server ends sooner than this after it connected was removed or refused
    /// (e.g. a duplicate identity), not cut by the length cap: rejoining would loop.
    public static let minSessionToRejoin: TimeInterval = 2 * 60

    public enum Stage: Sendable, Equatable {
        /// The coach is not connected.
        case off
        /// Connected, no workout yet.
        case beforeWorkout(since: Date)
        case workout
        case afterWorkout(endedAt: Date)
    }

    public private(set) var stage: Stage = .off
    public private(set) var workoutActive = false
    private var connectedAt: Date?
    private var lastTalkAt: Date?

    public init() {}

    /// A voice session connected (also after a network reconnect).
    public mutating func coachConnected(at now: Date) {
        if connectedAt == nil { connectedAt = now }
        if stage == .off { stage = workoutActive ? .workout : .beforeWorkout(since: now) }
    }

    /// The voice session ended for good (the user hung up, the server ended it, hang-up).
    public mutating func coachStopped() {
        connectedAt = nil
        stage = .off
    }

    public mutating func workoutStarted() {
        workoutActive = true
        if stage != .off { stage = .workout }
    }

    public mutating func workoutEnded(at now: Date) {
        workoutActive = false
        if stage != .off { stage = .afterWorkout(endedAt: now) }
    }

    /// The athlete or the coach said something.
    public mutating func talked(at now: Date) {
        lastTalkAt = now
    }

    /// Whether the phone should hang the coach up now.
    public func shouldHangUp(at now: Date) -> Bool {
        switch stage {
        case .off, .workout:
            return false
        case .beforeWorkout(let since):
            return now.timeIntervalSince(latest(since, lastTalkAt)) >= Self.quietBeforeWorkout
        case .afterWorkout(let endedAt):
            return now.timeIntervalSince(endedAt) >= Self.maxAfterWorkout
                || now.timeIntervalSince(latest(endedAt, lastTalkAt)) >= Self.quietAfterWorkout
        }
    }

    /// The server ended the session on purpose: rejoin while the workout goes on, unless that
    /// session hardly lasted. Ask before `coachStopped()`.
    public func shouldRejoin(at now: Date) -> Bool {
        guard workoutActive, let connectedAt else { return false }
        return now.timeIntervalSince(connectedAt) >= Self.minSessionToRejoin
    }

    private func latest(_ date: Date, _ other: Date?) -> Date {
        guard let other else { return date }
        return max(date, other)
    }
}
