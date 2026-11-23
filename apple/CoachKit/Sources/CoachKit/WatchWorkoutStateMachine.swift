import Foundation

/// Pure state machine for the Apple Watch workout controller (`WorkoutController`).
///
/// Serializes `recover()`, `start()`, HealthKit state transitions, `finishWorkout()` saving, and
/// hung-save timeouts behind a single explicit phase sum type and monotonic session generation.
public struct WatchWorkoutStateMachine: Sendable, Equatable {
    public enum RunState: Equatable, Sendable {
        case prepared
        case running
        case paused
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case recovering
        case starting(activity: String)
        case active(activity: String, runState: RunState)
        /// `stopActivity` completed; saving the workout to HealthKit before calling `session.end()`.
        case saving(activity: String, startedSavingAt: Date)
    }

    public enum TimerID: Hashable, Sendable {
        case finishTimeout
        case forceResetTimeout
    }

    public enum Notice: Equatable, Sendable {
        case alreadyActive
        case previousWorkoutStillSaving
        case startFailed(String)
        case recoveryFailed(String)
        case sessionFailed(String)
        case saveFailed(String)
    }

    public enum Event: Equatable, Sendable {
        case recoverRequested
        case recoveryFoundNone(generation: Int)
        case recoveryFoundSession(
            generation: Int, activity: String, state: WorkoutSessionState, endDate: Date, now: Date
        )
        case recoveryFailed(generation: Int, message: String)

        case startRequested(activity: String, now: Date)
        /// `beginCollection(at:)` succeeded.
        case startSucceeded(generation: Int)
        case startFailed(generation: Int, message: String)

        case sessionStateChanged(generation: Int, state: WorkoutSessionState, at: Date, now: Date)
        case sessionFailed(generation: Int, message: String)

        case pauseRequested
        case resumeRequested
        case endRequested

        case finishCompleted(generation: Int)
        case finishFailed(generation: Int, message: String)
        case finishTimerFired(generation: Int)
        case forceResetTimerFired(generation: Int)
    }

    public enum Effect: Equatable, Sendable {
        case runRecovery(generation: Int)
        case startSession(activity: String, generation: Int)
        case beginSaving(generation: Int, at: Date)
        case startRouteIfGPS
        case startMirroringAfterRecovery(generation: Int)
        case startHeartbeat
        case stopHeartbeat
        case pauseSession
        case resumeSession
        case stopActivity
        case endSession
        case emitForcedFrame(state: WorkoutState, at: Date)
        case scheduleTimer(TimerID, generation: Int)
        case cancelTimer(TimerID)
        case resetResources
    }

    public private(set) var phase: Phase = .idle
    public private(set) var generation: Int = 0
    public private(set) var notice: Notice? = nil
    public let finishTimeoutSeconds: TimeInterval

    public init(finishTimeoutSeconds: TimeInterval = 15) {
        self.finishTimeoutSeconds = finishTimeoutSeconds
    }

    public var isActive: Bool {
        switch phase {
        case .active, .saving: true
        case .idle, .recovering, .starting: false
        }
    }

    public var isRunning: Bool {
        if case .active(_, let runState) = phase { return runState == .running }
        return false
    }

    public var isPaused: Bool {
        if case .active(_, let runState) = phase { return runState == .paused }
        return false
    }

    public var isFinishing: Bool {
        if case .saving = phase { return true }
        return false
    }

    public var activity: String? {
        switch phase {
        case .starting(let a), .active(let a, _), .saving(let a, _): a
        case .idle, .recovering: nil
        }
    }

    public var wireState: WorkoutState {
        switch phase {
        case .idle, .recovering, .starting, .active(_, .prepared), .active(_, .paused): .paused
        case .active(_, .running): .running
        case .saving: .ended
        }
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .recoverRequested:
            guard case .idle = phase else { return [] }
            generation += 1
            phase = .recovering
            return [.runRecovery(generation: generation)]

        case .recoveryFoundNone(let gen):
            guard gen == generation, case .recovering = phase else { return [] }
            phase = .idle
            return []

        case .recoveryFailed(let gen, let message):
            guard gen == generation, case .recovering = phase else { return [] }
            phase = .idle
            notice = .recoveryFailed(message)
            return []

        case .recoveryFoundSession(let gen, let activity, let state, let endDate, let now):
            guard gen == generation, case .recovering = phase else { return [] }
            notice = nil
            switch state {
            case .stopped:
                phase = .saving(activity: activity, startedSavingAt: now)
                return [
                    .stopHeartbeat,
                    .beginSaving(generation: gen, at: endDate),
                    .scheduleTimer(.finishTimeout, generation: gen),
                ]
            case .ended, .notStarted:
                generation += 1
                phase = .idle
                return [.endSession, .resetResources]
            case .prepared, .running, .paused:
                let runState = Self.runState(for: state)
                phase = .active(activity: activity, runState: runState)
                var effects: [Effect] = [runState == .running ? .startHeartbeat : .stopHeartbeat]
                effects.append(.startRouteIfGPS)
                effects.append(.startMirroringAfterRecovery(generation: gen))
                effects.append(.emitForcedFrame(state: wireState, at: now))
                return effects
            }

        case .startRequested(let activity, let now):
            switch phase {
            case .recovering, .starting:
                return []
            case .active:
                notice = .alreadyActive
                return []
            case .saving(_, let since):
                if now.timeIntervalSince(since) < finishTimeoutSeconds {
                    notice = .previousWorkoutStillSaving
                    return []
                }
                // Hung save past timeout: discard the leftover session and start fresh.
                generation += 1
                notice = nil
                phase = .starting(activity: activity)
                return [
                    .cancelTimer(.finishTimeout),
                    .cancelTimer(.forceResetTimeout),
                    .stopHeartbeat,
                    .endSession,
                    .resetResources,
                    .startSession(activity: activity, generation: generation),
                ]
            case .idle:
                generation += 1
                notice = nil
                phase = .starting(activity: activity)
                return [.startSession(activity: activity, generation: generation)]
            }

        case .startSucceeded(let gen):
            guard gen == generation else { return [] }
            switch phase {
            case .starting(let activity):
                phase = .active(activity: activity, runState: .prepared)
                return [.startRouteIfGPS]
            case .active:
                // HealthKit already delivered `.running` before `beginCollection` returned.
                return [.startRouteIfGPS]
            default:
                return []
            }

        case .startFailed(let gen, let message):
            guard gen == generation else { return [] }
            switch phase {
            case .starting, .active:
                generation += 1
                phase = .idle
                notice = .startFailed(message)
                return [
                    .cancelTimer(.finishTimeout),
                    .cancelTimer(.forceResetTimeout),
                    .stopHeartbeat,
                    .endSession,
                    .resetResources,
                ]
            default:
                return []
            }

        case .sessionStateChanged(let gen, let state, let at, let now):
            guard gen == generation else { return [] }
            return handleSessionState(gen: gen, state: state, at: at, now: now)

        case .sessionFailed(let gen, let message):
            guard gen == generation else { return [] }
            switch phase {
            case .starting, .active, .saving:
                notice = .sessionFailed(message)
                return []
            case .idle, .recovering:
                return []
            }

        case .pauseRequested:
            guard case .active = phase else { return [] }
            return [.pauseSession]

        case .resumeRequested:
            guard case .active = phase else { return [] }
            return [.resumeSession]

        case .endRequested:
            switch phase {
            case .idle:
                return [.resetResources]
            case .recovering, .starting:
                return []
            case .active:
                return [.stopActivity, .scheduleTimer(.finishTimeout, generation: generation)]
            case .saving:
                // Second tap while saving: end the HealthKit session immediately instead of being a no-op.
                return [.endSession, .scheduleTimer(.forceResetTimeout, generation: generation)]
            }

        case .finishCompleted(let gen):
            guard gen == generation, case .saving = phase else { return [] }
            return [.endSession, .scheduleTimer(.forceResetTimeout, generation: gen)]

        case .finishFailed(let gen, let message):
            guard gen == generation, case .saving = phase else { return [] }
            notice = .saveFailed(message)
            return [.endSession, .scheduleTimer(.forceResetTimeout, generation: gen)]

        case .finishTimerFired(let gen):
            guard gen == generation else { return [] }
            switch phase {
            case .active, .saving:
                return [.endSession, .scheduleTimer(.forceResetTimeout, generation: gen)]
            default:
                return []
            }

        case .forceResetTimerFired(let gen):
            guard gen == generation else { return [] }
            switch phase {
            case .active, .saving:
                generation += 1
                phase = .idle
                return [
                    .cancelTimer(.finishTimeout),
                    .cancelTimer(.forceResetTimeout),
                    .stopHeartbeat,
                    .resetResources,
                ]
            default:
                return []
            }
        }
    }

    private mutating func handleSessionState(
        gen: Int, state: WorkoutSessionState, at date: Date, now: Date
    ) -> [Effect] {
        switch phase {
        case .starting(let activity):
            switch state {
            case .running:
                phase = .active(activity: activity, runState: .running)
                return [.startHeartbeat, .emitForcedFrame(state: .running, at: date)]
            case .paused:
                phase = .active(activity: activity, runState: .paused)
                return [.stopHeartbeat, .emitForcedFrame(state: .paused, at: date)]
            case .stopped:
                phase = .saving(activity: activity, startedSavingAt: now)
                return [
                    .stopHeartbeat,
                    .emitForcedFrame(state: .ended, at: date),
                    .beginSaving(generation: gen, at: date),
                    .scheduleTimer(.finishTimeout, generation: gen),
                ]
            case .ended:
                generation += 1
                phase = .idle
                return [
                    .cancelTimer(.finishTimeout),
                    .cancelTimer(.forceResetTimeout),
                    .stopHeartbeat,
                    .emitForcedFrame(state: .ended, at: date),
                    .resetResources,
                ]
            case .prepared, .notStarted:
                return []
            }

        case .active(let activity, _):
            switch state {
            case .running:
                phase = .active(activity: activity, runState: .running)
                return [.startHeartbeat, .emitForcedFrame(state: .running, at: date)]
            case .paused:
                phase = .active(activity: activity, runState: .paused)
                return [.stopHeartbeat, .emitForcedFrame(state: .paused, at: date)]
            case .prepared:
                phase = .active(activity: activity, runState: .prepared)
                return [.stopHeartbeat, .emitForcedFrame(state: .paused, at: date)]
            case .stopped:
                phase = .saving(activity: activity, startedSavingAt: now)
                return [
                    .stopHeartbeat,
                    .emitForcedFrame(state: .ended, at: date),
                    .beginSaving(generation: gen, at: date),
                    .scheduleTimer(.finishTimeout, generation: gen),
                ]
            case .ended:
                generation += 1
                phase = .idle
                return [
                    .cancelTimer(.finishTimeout),
                    .cancelTimer(.forceResetTimeout),
                    .stopHeartbeat,
                    .emitForcedFrame(state: .ended, at: date),
                    .resetResources,
                ]
            case .notStarted:
                return []
            }

        case .saving:
            if state == .ended {
                generation += 1
                phase = .idle
                return [
                    .cancelTimer(.finishTimeout),
                    .cancelTimer(.forceResetTimeout),
                    .stopHeartbeat,
                    .emitForcedFrame(state: .ended, at: date),
                    .resetResources,
                ]
            }
            return []

        case .idle, .recovering:
            return []
        }
    }

    private static func runState(for state: WorkoutSessionState) -> RunState {
        switch state {
        case .running: .running
        case .paused: .paused
        default: .prepared
        }
    }
}
