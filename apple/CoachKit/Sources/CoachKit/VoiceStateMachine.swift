import Foundation

/// Pure state machine for the iOS voice coach link (`VoiceSession`).
///
/// Separates connection lifecycle, LiveKit ICE reconnects, backoff retries, and generation-gated
/// async callbacks from LiveKit/Network I/O so illegal state combinations are unrepresentable and
/// every race condition can be verified deterministically.
public struct VoiceStateMachine: Sendable, Equatable {
    public struct ConnectedState: Equatable, Sendable {
        /// True while LiveKit is performing its own in-room ICE reconnect.
        public var liveKitReconnecting: Bool
        public var isCoachSpeaking: Bool
        public var isUserSpeaking: Bool

        public init(
            liveKitReconnecting: Bool = false,
            isCoachSpeaking: Bool = false,
            isUserSpeaking: Bool = false
        ) {
            self.liveKitReconnecting = liveKitReconnecting
            self.isCoachSpeaking = isCoachSpeaking
            self.isUserSpeaking = isUserSpeaking
        }
    }

    public enum FailureReason: Equatable, Sendable {
        /// Server deliberately ended the session (time cap, removed, duplicate identity).
        case sessionEndedByServer
        /// Non-retriable error (bad invite, quota exhausted, 4xx, etc.).
        case error(String)
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case requestingToken(attempt: Int, hasConnected: Bool)
        case connectingRoom(attempt: Int, hasConnected: Bool)
        case connected(ConnectedState)
        case waitingToRetry(attempt: Int, hasConnected: Bool)
        case failed(FailureReason)
    }

    public enum Event: Equatable, Sendable {
        case start
        case stop
        case tokenSucceeded(generation: Int)
        case tokenFailed(generation: Int, drop: ReconnectPolicy.Drop, message: String)
        /// Room connected, RPC/transcript handlers registered, and microphone configured.
        case roomReady(generation: Int)
        case roomConnectFailed(generation: Int, drop: ReconnectPolicy.Drop, message: String)
        /// LiveKit's internal connection state changed on an already-connected room.
        case liveKitConnectionChanged(generation: Int, reconnecting: Bool)
        /// Room disconnected unexpectedly (`isFatal` when ended intentionally by the server).
        case roomDisconnected(generation: Int, isFatal: Bool)
        /// Coach agent left the room while the phone stayed connected.
        case agentLeft(generation: Int)
        /// Heartbeat RPC missed the threshold.
        case heartbeatFailed(generation: Int)
        /// Backoff timer expired.
        case retryTimerFired(generation: Int)
        /// Network path became satisfied.
        case networkSatisfied
        /// Speaking participants changed in the active room.
        case speakingChanged(generation: Int, coach: Bool, user: Bool)
        /// Microphone mute state changed for the active room.
        case muteChanged(generation: Int, isMuted: Bool)
    }

    public enum Effect: Equatable, Sendable {
        case startPathMonitor
        case stopPathMonitor
        case requestToken(generation: Int)
        case connectRoom(generation: Int, micEnabled: Bool)
        case disconnectRoom
        case startHeartbeat(generation: Int)
        case stopHeartbeat
        case cancelSendTail
        case scheduleRetry(generation: Int, delay: TimeInterval)
        case cancelRetry
        case notifyConnected
        case notifyLinkLost
        case notifyStopped
    }

    public private(set) var phase: Phase = .idle
    /// Monotonically incremented on every transition that invalidates an in-flight attempt or room.
    public private(set) var generation: Int = 0
    /// Session-wide mute preference: reset on `start`, preserved across automatic reconnects.
    public private(set) var isMuted: Bool = false
    public private(set) var reconnects: Int = 0
    private let policy: ReconnectPolicy

    public init(policy: ReconnectPolicy = ReconnectPolicy()) {
        self.policy = policy
    }

    public var isActive: Bool {
        switch phase {
        case .requestingToken, .connectingRoom, .connected, .waitingToRetry: true
        case .idle, .failed: false
        }
    }

    /// True only when connected and not undergoing a LiveKit-internal reconnect.
    public var isConnected: Bool {
        if case .connected(let c) = phase { return !c.liveKitReconnecting }
        return false
    }

    /// The user wants the coach but cannot hear it right now: the phone speaks key cues itself.
    public var needsLocalFallback: Bool { isActive && !isConnected }

    public var isCoachSpeaking: Bool {
        if case .connected(let c) = phase { return c.isCoachSpeaking }
        return false
    }

    public var isUserSpeaking: Bool {
        if case .connected(let c) = phase { return c.isUserSpeaking }
        return false
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .start:
            guard !isActive else { return [] }
            isMuted = false
            reconnects = 0
            generation += 1
            phase = .requestingToken(attempt: 0, hasConnected: false)
            return [.startPathMonitor, .requestToken(generation: generation)]

        case .stop:
            switch phase {
            case .idle:
                return []
            case .failed:
                phase = .idle
                return []
            case .requestingToken, .connectingRoom, .connected, .waitingToRetry:
                generation += 1
                phase = .idle
                return [
                    .cancelRetry,
                    .stopHeartbeat,
                    .stopPathMonitor,
                    .cancelSendTail,
                    .disconnectRoom,
                    .notifyStopped,
                ]
            }

        case .tokenSucceeded(let gen):
            guard gen == generation, case .requestingToken(let attempt, let hasConnected) = phase else {
                return []
            }
            phase = .connectingRoom(attempt: attempt, hasConnected: hasConnected)
            return [.connectRoom(generation: gen, micEnabled: !isMuted)]

        case .tokenFailed(let gen, let drop, let message):
            guard gen == generation, case .requestingToken(let attempt, let hasConnected) = phase else {
                return []
            }
            return handleConnectFailure(attempt: attempt, hasConnected: hasConnected, drop: drop, message: message)

        case .roomReady(let gen):
            guard gen == generation, case .connectingRoom(let attempt, _) = phase else {
                return []
            }
            if attempt > 0 { reconnects += 1 }
            phase = .connected(ConnectedState())
            return [.startHeartbeat(generation: gen), .notifyConnected]

        case .roomConnectFailed(let gen, let drop, let message):
            guard gen == generation, case .connectingRoom(let attempt, let hasConnected) = phase else {
                return []
            }
            return handleConnectFailure(attempt: attempt, hasConnected: hasConnected, drop: drop, message: message)

        case .liveKitConnectionChanged(let gen, let reconnecting):
            guard gen == generation, case .connected(var c) = phase else { return [] }
            c.liveKitReconnecting = reconnecting
            phase = .connected(c)
            return []

        case .roomDisconnected(let gen, let isFatal):
            guard gen == generation else { return [] }
            switch phase {
            case .connected:
                return handleDrop(attempt: 0, notifyLinkLost: true, isFatal: isFatal)
            case .connectingRoom(let attempt, let hasConnected):
                // Disconnected mid-handshake before ever reaching `.connected`: retry without
                // announcing a drop unless we had already connected earlier in this session.
                return handleDrop(attempt: attempt, notifyLinkLost: false, hasConnectedAfter: hasConnected, isFatal: isFatal)
            default:
                return []
            }

        case .agentLeft(let gen):
            guard gen == generation else { return [] }
            switch phase {
            case .connected:
                return handleDrop(attempt: 0, notifyLinkLost: true, isFatal: false)
            default:
                return []
            }

        case .heartbeatFailed(let gen):
            guard gen == generation, case .connected = phase else { return [] }
            return handleDrop(attempt: 0, notifyLinkLost: true, isFatal: false)

        case .retryTimerFired(let gen):
            guard gen == generation, case .waitingToRetry(let attempt, let hasConnected) = phase else {
                return []
            }
            return beginRetry(attempt: attempt, hasConnected: hasConnected)

        case .networkSatisfied:
            guard case .waitingToRetry(let attempt, let hasConnected) = phase else { return [] }
            return beginRetry(attempt: attempt, hasConnected: hasConnected)

        case .speakingChanged(let gen, let coach, let user):
            guard gen == generation, case .connected(var c) = phase else { return [] }
            c.isCoachSpeaking = coach
            c.isUserSpeaking = user
            phase = .connected(c)
            return []

        case .muteChanged(let gen, let muted):
            guard gen == generation, case .connected = phase else { return [] }
            isMuted = muted
            return []
        }
    }

    private mutating func beginRetry(attempt: Int, hasConnected: Bool) -> [Effect] {
        generation += 1
        phase = .requestingToken(attempt: attempt, hasConnected: hasConnected)
        return [.cancelRetry, .requestToken(generation: generation)]
    }

    private mutating func handleConnectFailure(
        attempt: Int, hasConnected: Bool, drop: ReconnectPolicy.Drop, message: String
    ) -> [Effect] {
        generation += 1
        if policy.shouldRetry(drop) {
            let delay = policy.delay(forAttempt: attempt)
            phase = .waitingToRetry(attempt: attempt + 1, hasConnected: hasConnected)
            return [
                .disconnectRoom,
                .scheduleRetry(generation: generation, delay: delay),
            ]
        } else {
            phase = .failed(.error(message))
            return [
                .cancelRetry,
                .stopHeartbeat,
                .stopPathMonitor,
                .cancelSendTail,
                .disconnectRoom,
                .notifyStopped,
            ]
        }
    }

    private mutating func handleDrop(
        attempt: Int, notifyLinkLost: Bool, hasConnectedAfter: Bool = true, isFatal: Bool
    ) -> [Effect] {
        generation += 1
        if isFatal {
            phase = .failed(.sessionEndedByServer)
            return [
                .cancelRetry,
                .stopHeartbeat,
                .stopPathMonitor,
                .cancelSendTail,
                .disconnectRoom,
                .notifyStopped,
            ]
        }
        let delay = policy.delay(forAttempt: attempt)
        phase = .waitingToRetry(attempt: attempt + 1, hasConnected: hasConnectedAfter)
        var effects: [Effect] = [.stopHeartbeat, .cancelSendTail, .disconnectRoom]
        if notifyLinkLost { effects.append(.notifyLinkLost) }
        effects.append(.scheduleRetry(generation: generation, delay: delay))
        return effects
    }
}
