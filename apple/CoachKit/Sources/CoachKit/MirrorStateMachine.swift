import Foundation

/// Pure state machine for the iPhone workout mirror (`MirrorReceiver`).
///
/// Replaces the scattered flags (`state`, `isStartingWatch`, `awaitingActivity`,
/// `isWatchSlowToStart`, `startAttempt`, `sessionStart`, detached timer Tasks) with a single
/// explicit phase sum type and generation-gated timers/callbacks.
public struct MirrorStateMachine: Sendable, Equatable {
    public enum RunState: Equatable, Sendable {
        case prepared
        case running
        case paused
        case stopping
    }

    public struct ActiveWorkout: Equatable, Sendable {
        public var activity: String
        public var startedAt: Date?
        public var runState: RunState
        /// True after the user tapped End on the phone and we are waiting for the watch to confirm.
        public var ending: Bool

        public init(activity: String, startedAt: Date?, runState: RunState, ending: Bool = false) {
            self.activity = activity
            self.startedAt = startedAt
            self.runState = runState
            self.ending = ending
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// `startWatchApp` is in flight; waiting for the watch to accept the request.
        case launchingWatch(activity: String, slow: Bool)
        /// Watch accepted `startWatchApp`; dashboard is visible while waiting for HealthKit to mirror.
        case awaitingMirror(activity: String)
        /// A mirrored `HKWorkoutSession` is attached.
        case active(ActiveWorkout)
        /// The mirrored session disconnected; dashboard stays visible while waiting for re-mirror.
        case disconnected(ActiveWorkout)
    }

    public enum TimerID: Hashable, Sendable {
        case slowStart
        case attachTimeout
        case endTimeout
        case reattachTimeout
    }

    public enum Notice: Equatable, Sendable {
        case watchLaunchFailed(String)
        case watchAttachTimedOut
        case sessionFailed(String)
        case disconnected(String)
        case controlsUnavailableWhileDisconnected
        case endedWhileAwaitingMirror
        case endedWhileDisconnected
        case watchDidNotConfirmEnd
        case reattachTimedOut
    }

    public enum Event: Equatable, Sendable {
        case startOnWatch(activity: String)
        case slowStartTimerFired(generation: Int)
        case attachTimerFired(generation: Int)
        case watchAppStarted(generation: Int)
        case watchAppStartFailed(generation: Int, message: String)
        case cancelStart
        case sessionAttached(activity: String, startedAt: Date?, state: WorkoutSessionState)
        case sessionStateChanged(generation: Int, state: WorkoutSessionState)
        case sessionFailed(generation: Int, message: String)
        case sessionDisconnected(generation: Int, message: String)
        case framesReceived(generation: Int, latestState: WorkoutState)
        case pauseRequested
        case resumeRequested
        case endRequested
        case endTimerFired(generation: Int)
        case reattachTimerFired(generation: Int)
    }

    public enum Effect: Equatable, Sendable {
        case callStartWatchApp(activity: String, generation: Int)
        case scheduleTimer(TimerID, generation: Int)
        case cancelTimer(TimerID)
        case sendPause
        case sendResume
        case sendStop
        case detachSession
        case attachIncomingSession(generation: Int)
        case resetMetrics
        case notifySessionStarted(activity: String)
        case notifySessionEnded
    }

    public private(set) var phase: Phase = .idle
    public private(set) var notice: Notice? = nil
    /// Gates `startWatchApp` completions and launch timers.
    public private(set) var startGeneration: Int = 0
    /// Gates attached session delegate callbacks, end timeout, and reattach timeout.
    public private(set) var sessionGeneration: Int = 0

    public init() {}

    /// True while a mirrored workout is in progress (connected or temporarily disconnected).
    public var isActive: Bool {
        switch phase {
        case .active, .disconnected: true
        case .idle, .launchingWatch, .awaitingMirror: false
        }
    }

    /// True while the workout dashboard should be shown (active, disconnected, or awaiting first mirror).
    public var isWorkoutVisible: Bool {
        switch phase {
        case .awaitingMirror, .active, .disconnected: true
        case .idle, .launchingWatch: false
        }
    }

    /// True while waiting on `startWatchApp` or the initial mirrored session.
    public var isStartingWatch: Bool {
        switch phase {
        case .launchingWatch, .awaitingMirror: true
        case .idle, .active, .disconnected: false
        }
    }

    public var isWatchSlowToStart: Bool {
        if case .launchingWatch(_, let slow) = phase { return slow }
        return false
    }

    /// The activity the phone asked the watch to start, until the watch has it.
    public var startingActivity: String? {
        switch phase {
        case .launchingWatch(let activity, _), .awaitingMirror(let activity): activity
        case .idle, .active, .disconnected: nil
        }
    }

    public var awaitingActivity: String? {
        if case .awaitingMirror(let activity) = phase { return activity }
        return nil
    }

    public var activeActivity: String? {
        switch phase {
        case .active(let w), .disconnected(let w): w.activity
        case .idle, .launchingWatch, .awaitingMirror: nil
        }
    }

    public var isRunning: Bool {
        switch phase {
        case .active(let w), .disconnected(let w): w.runState == .running
        default: false
        }
    }

    public var isPaused: Bool {
        switch phase {
        case .active(let w), .disconnected(let w): w.runState == .paused
        default: false
        }
    }

    public var isFinishing: Bool {
        switch phase {
        case .active(let w), .disconnected(let w): w.runState == .stopping
        default: false
        }
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .startOnWatch(let activity):
            guard case .idle = phase else { return [] }
            notice = nil
            startGeneration += 1
            phase = .launchingWatch(activity: activity, slow: false)
            return [
                .scheduleTimer(.slowStart, generation: startGeneration),
                .scheduleTimer(.attachTimeout, generation: startGeneration),
                .callStartWatchApp(activity: activity, generation: startGeneration),
            ]

        case .slowStartTimerFired(let gen):
            guard gen == startGeneration, case .launchingWatch(let activity, slow: false) = phase else {
                return []
            }
            phase = .launchingWatch(activity: activity, slow: true)
            return []

        case .watchAppStarted(let gen):
            guard gen == startGeneration, case .launchingWatch(let activity, _) = phase else {
                return []
            }
            phase = .awaitingMirror(activity: activity)
            return [.cancelTimer(.slowStart)]

        case .watchAppStartFailed(let gen, let message):
            guard gen == startGeneration else { return [] }
            switch phase {
            case .launchingWatch, .awaitingMirror:
                startGeneration += 1
                phase = .idle
                notice = .watchLaunchFailed(message)
                return [.cancelTimer(.slowStart), .cancelTimer(.attachTimeout)]
            default:
                return []
            }

        case .attachTimerFired(let gen):
            guard gen == startGeneration else { return [] }
            switch phase {
            case .launchingWatch, .awaitingMirror:
                startGeneration += 1
                phase = .idle
                notice = .watchAttachTimedOut
                return [.cancelTimer(.slowStart)]
            default:
                return []
            }

        case .cancelStart:
            guard case .launchingWatch = phase else { return [] }
            startGeneration += 1
            phase = .idle
            return [.cancelTimer(.slowStart), .cancelTimer(.attachTimeout)]

        case .sessionAttached(let activity, let startedAt, let state):
            return handleAttach(activity: activity, startedAt: startedAt, state: state)

        case .sessionStateChanged(let gen, let state):
            guard gen == sessionGeneration, case .active(var w) = phase else { return [] }
            if state == .ended {
                sessionGeneration += 1
                phase = .idle
                return [.cancelTimer(.endTimeout), .detachSession, .notifySessionEnded]
            }
            w.runState = Self.runState(for: state)
            phase = .active(w)
            return []

        case .sessionFailed(let gen, let message):
            guard gen == sessionGeneration, case .active = phase else { return [] }
            notice = .sessionFailed(message)
            return []

        case .sessionDisconnected(let gen, let message):
            guard gen == sessionGeneration, case .active(let w) = phase else { return [] }
            sessionGeneration += 1
            if w.ending {
                phase = .idle
                notice = .endedWhileDisconnected
                return [.cancelTimer(.endTimeout), .detachSession, .notifySessionEnded]
            }
            phase = .disconnected(w)
            notice = .disconnected(message)
            return [
                .cancelTimer(.endTimeout),
                .detachSession,
                .scheduleTimer(.reattachTimeout, generation: sessionGeneration),
            ]

        case .framesReceived(let gen, let latestState):
            guard gen == sessionGeneration, case .active(var w) = phase else { return [] }
            switch latestState {
            case .running where w.runState == .paused || w.runState == .prepared:
                w.runState = .running
                phase = .active(w)
                return []
            case .paused where w.runState == .running || w.runState == .prepared:
                w.runState = .paused
                phase = .active(w)
                return []
            case .ended:
                sessionGeneration += 1
                phase = .idle
                notice = nil
                return [.cancelTimer(.endTimeout), .detachSession, .notifySessionEnded]
            default:
                return []
            }

        case .pauseRequested:
            switch phase {
            case .active:
                return [.sendPause]
            case .disconnected, .awaitingMirror:
                notice = .controlsUnavailableWhileDisconnected
                return []
            case .idle, .launchingWatch:
                return []
            }

        case .resumeRequested:
            switch phase {
            case .active:
                return [.sendResume]
            case .disconnected, .awaitingMirror:
                notice = .controlsUnavailableWhileDisconnected
                return []
            case .idle, .launchingWatch:
                return []
            }

        case .endRequested:
            switch phase {
            case .awaitingMirror:
                startGeneration += 1
                phase = .idle
                notice = .endedWhileAwaitingMirror
                return [.cancelTimer(.slowStart), .cancelTimer(.attachTimeout)]
            case .disconnected:
                sessionGeneration += 1
                phase = .idle
                notice = .endedWhileDisconnected
                return [.cancelTimer(.reattachTimeout), .cancelTimer(.endTimeout), .notifySessionEnded]
            case .active(var w):
                w.ending = true
                phase = .active(w)
                return [.sendStop, .scheduleTimer(.endTimeout, generation: sessionGeneration)]
            case .idle, .launchingWatch:
                return []
            }

        case .endTimerFired(let gen):
            guard gen == sessionGeneration else { return [] }
            switch phase {
            case .active, .disconnected:
                sessionGeneration += 1
                phase = .idle
                notice = .watchDidNotConfirmEnd
                return [.cancelTimer(.reattachTimeout), .detachSession, .notifySessionEnded]
            default:
                return []
            }

        case .reattachTimerFired(let gen):
            guard gen == sessionGeneration, case .disconnected = phase else { return [] }
            sessionGeneration += 1
            phase = .idle
            notice = .reattachTimedOut
            return [.cancelTimer(.endTimeout), .notifySessionEnded]
        }
    }

    private mutating func handleAttach(
        activity: String, startedAt: Date?, state: WorkoutSessionState
    ) -> [Effect] {
        var effects: [Effect] = []

        // Check whether this mirrored session continues the currently tracked workout.
        switch phase {
        case .active(var existing), .disconnected(var existing):
            if let currentStart = existing.startedAt, currentStart == startedAt {
                effects.append(.cancelTimer(.reattachTimeout))
                if state == .ended {
                    sessionGeneration += 1
                    phase = .idle
                    notice = nil
                    effects.append(.cancelTimer(.endTimeout))
                    effects.append(.detachSession)
                    effects.append(.notifySessionEnded)
                    return effects
                }
                sessionGeneration += 1
                existing.runState = Self.runState(for: state)
                phase = .active(existing)
                notice = nil
                effects.append(.detachSession)
                effects.append(.attachIncomingSession(generation: sessionGeneration))
                return effects
            }
            // Different workout attached while an older one was still open: close the old one first.
            effects.append(.cancelTimer(.endTimeout))
            effects.append(.cancelTimer(.reattachTimeout))
            effects.append(.detachSession)
            effects.append(.notifySessionEnded)

        case .launchingWatch, .awaitingMirror:
            startGeneration += 1
            effects.append(.cancelTimer(.slowStart))
            effects.append(.cancelTimer(.attachTimeout))

        case .idle:
            break
        }

        // Never start a brand-new workout from an already-ended mirrored session.
        if state == .ended {
            sessionGeneration += 1
            phase = .idle
            notice = nil
            effects.append(.detachSession)
            return effects
        }

        sessionGeneration += 1
        notice = nil
        phase = .active(ActiveWorkout(activity: activity, startedAt: startedAt, runState: Self.runState(for: state)))
        effects.append(.resetMetrics)
        effects.append(.attachIncomingSession(generation: sessionGeneration))
        effects.append(.notifySessionStarted(activity: activity))
        return effects
    }

    private static func runState(for state: WorkoutSessionState) -> RunState {
        switch state {
        case .notStarted, .prepared: .prepared
        case .running: .running
        case .paused: .paused
        case .stopped, .ended: .stopping
        }
    }
}
