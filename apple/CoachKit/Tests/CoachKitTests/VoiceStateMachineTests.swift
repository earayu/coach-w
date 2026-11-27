import Foundation
import Testing

@testable import CoachKit

@Test func voiceHappyPathAndCleanStop() {
    var sm = VoiceStateMachine()
    #expect(sm.phase == .idle && !sm.isActive && !sm.isConnected && !sm.needsLocalFallback)

    let startEffects = sm.handle(.start)
    let g1 = sm.generation
    #expect(g1 == 1)
    #expect(sm.phase == .requestingToken(attempt: 0, hasConnected: false))
    #expect(sm.isActive && !sm.isConnected && sm.needsLocalFallback)
    #expect(startEffects == [.startPathMonitor, .requestToken(generation: g1)])

    let tokenEffects = sm.handle(.tokenSucceeded(generation: g1))
    #expect(sm.phase == .connectingRoom(attempt: 0, hasConnected: false))
    #expect(tokenEffects == [.connectRoom(generation: g1, micEnabled: true)])

    let readyEffects = sm.handle(.roomReady(generation: g1))
    #expect(sm.isConnected && !sm.needsLocalFallback && sm.reconnects == 0)
    #expect(readyEffects == [.startHeartbeat(generation: g1), .notifyConnected])

    let stopEffects = sm.handle(.stop)
    #expect(sm.phase == .idle && !sm.isActive && sm.generation == g1 + 1)
    #expect(stopEffects == [
        .cancelRetry, .stopHeartbeat, .stopPathMonitor, .cancelSendTail, .disconnectRoom, .notifyStopped,
    ])
    // Stopping again when idle is a no-op
    #expect(sm.handle(.stop).isEmpty)
}

@Test func voiceLiveKitStateChangeDuringHandshakeDoesNotPrematurelyConnect() {
    var sm = VoiceStateMachine()
    sm.handle(.start)
    let g1 = sm.generation
    sm.handle(.tokenSucceeded(generation: g1))
    #expect(sm.phase == .connectingRoom(attempt: 0, hasConnected: false))

    // LiveKit fires connectionState = .connected before transcripts/mic setup completes.
    let effects = sm.handle(.liveKitConnectionChanged(generation: g1, reconnecting: false))
    #expect(effects.isEmpty)
    #expect(!sm.isConnected)
    #expect(sm.phase == .connectingRoom(attempt: 0, hasConnected: false))
}

@Test func voiceDisconnectMidHandshakeBumpsGenerationAndDoesNotDoubleRetryOrAnnounceDrop() {
    var sm = VoiceStateMachine(policy: ReconnectPolicy(delays: [1, 2, 5]))
    sm.handle(.start)
    let g1 = sm.generation
    sm.handle(.tokenSucceeded(generation: g1))

    // Room disconnects while still in connectingRoom (never reached .connected).
    let dropEffects = sm.handle(.roomDisconnected(generation: g1, isFatal: false))
    let g2 = sm.generation
    #expect(g2 > g1)
    #expect(sm.phase == .waitingToRetry(attempt: 1, hasConnected: false))
    // Never connected before, so notifyLinkLost must NOT fire.
    #expect(!dropEffects.contains(.notifyLinkLost))
    #expect(dropEffects == [.stopHeartbeat, .cancelSendTail, .disconnectRoom, .scheduleRetry(generation: g2, delay: 1)])

    // The in-flight connect task subsequently finishes or fails with stale g1: must be ignored!
    #expect(sm.handle(.roomConnectFailed(generation: g1, drop: .network, message: "closed")).isEmpty)
    #expect(sm.handle(.roomReady(generation: g1)).isEmpty)
    #expect(sm.phase == .waitingToRetry(attempt: 1, hasConnected: false))
    #expect(sm.generation == g2)
}

@Test func voiceAgentLeavingDuringLiveKitReconnectTriggersDropAndPreservesMute() {
    var sm = VoiceStateMachine(policy: ReconnectPolicy(delays: [1, 2]))
    sm.handle(.start)
    let g1 = sm.generation
    sm.handle(.tokenSucceeded(generation: g1))
    sm.handle(.roomReady(generation: g1))
    sm.handle(.muteChanged(generation: g1, isMuted: true))
    #expect(sm.isMuted)

    // LiveKit starts an internal ICE reconnect.
    sm.handle(.liveKitConnectionChanged(generation: g1, reconnecting: true))
    #expect(sm.isActive && !sm.isConnected && sm.needsLocalFallback)

    // Coach leaves while ICE is reconnecting.
    let dropEffects = sm.handle(.agentLeft(generation: g1))
    let g2 = sm.generation
    #expect(g2 > g1)
    #expect(dropEffects == [
        .stopHeartbeat, .cancelSendTail, .disconnectRoom, .notifyLinkLost, .scheduleRetry(generation: g2, delay: 1),
    ])
    #expect(sm.phase == .waitingToRetry(attempt: 1, hasConnected: true))

    // Stale disconnect/mute/speaking events from g1 are ignored.
    #expect(sm.handle(.roomDisconnected(generation: g1, isFatal: false)).isEmpty)
    #expect(sm.handle(.muteChanged(generation: g1, isMuted: false)).isEmpty)
    #expect(sm.isMuted)

    // Network returns immediately -> cancels retry timer, requests token, preserves mute on reconnect.
    let netEffects = sm.handle(.networkSatisfied)
    let g3 = sm.generation
    #expect(g3 > g2)
    #expect(netEffects == [.cancelRetry, .requestToken(generation: g3)])
    // Duplicate networkSatisfied and stale retry timer are both ignored.
    #expect(sm.handle(.networkSatisfied).isEmpty)
    #expect(sm.handle(.retryTimerFired(generation: g2)).isEmpty)

    let connectEffects = sm.handle(.tokenSucceeded(generation: g3))
    #expect(connectEffects == [.connectRoom(generation: g3, micEnabled: false)])
    sm.handle(.roomReady(generation: g3))
    #expect(sm.isConnected && sm.isMuted && sm.reconnects == 1)
}

@Test func voiceFatalDisconnectAndNonRetriableErrorsStopRetrying() {
    var sm = VoiceStateMachine()
    sm.handle(.start)
    let g1 = sm.generation
    let failEffects = sm.handle(.tokenFailed(generation: g1, drop: .final, message: "401"))
    #expect(sm.phase == .failed(.error("401")))
    #expect(!sm.isActive && !sm.needsLocalFallback)
    #expect(failEffects.contains(.stopPathMonitor) && failEffects.contains(.notifyStopped))

    // Starting again from `.failed` resets state cleanly.
    sm.handle(.start)
    let g2 = sm.generation
    sm.handle(.tokenSucceeded(generation: g2))
    sm.handle(.roomReady(generation: g2))
    let fatalEffects = sm.handle(.roomDisconnected(generation: g2, isFatal: true))
    #expect(sm.phase == .failed(.sessionEndedByServer))
    #expect(!sm.isActive && fatalEffects.contains(.notifyStopped))
    #expect(!fatalEffects.contains(.notifyLinkLost))
}

@Test func voiceStateMachineInvariantsHoldAcrossEventSequences() {
    var sm = VoiceStateMachine(policy: ReconnectPolicy(delays: [1, 2, 5]))
    var prevGen = sm.generation

    func checkInvariants() {
        #expect(sm.generation >= prevGen)
        prevGen = sm.generation
        if !sm.isActive {
            #expect(!sm.isConnected)
            #expect(!sm.needsLocalFallback)
            #expect(!sm.isCoachSpeaking)
            #expect(!sm.isUserSpeaking)
        }
        if sm.isConnected {
            #expect(sm.isActive && !sm.needsLocalFallback)
        }
    }

    let script: [(VoiceStateMachine) -> VoiceStateMachine.Event] = [
        { _ in .start },
        { .tokenSucceeded(generation: $0.generation) },
        { .speakingChanged(generation: $0.generation, coach: true, user: true) },
        { .roomReady(generation: $0.generation) },
        { .speakingChanged(generation: $0.generation, coach: true, user: false) },
        { .heartbeatFailed(generation: $0.generation) },
        { .retryTimerFired(generation: $0.generation) },
        { .tokenFailed(generation: $0.generation, drop: .network, message: "timeout") },
        { _ in .networkSatisfied },
        { .tokenSucceeded(generation: $0.generation) },
        { .roomReady(generation: $0.generation) },
        { _ in .stop },
        { .roomDisconnected(generation: $0.generation - 1, isFatal: true) },
    ]
    for makeEvent in script {
        sm.handle(makeEvent(sm))
        checkInvariants()
    }
    #expect(sm.phase == .idle)
}

@Test func heartbeatErrorActionDistinguishesLinkLossFromAppErrors() {
    #expect(HeartbeatErrorAction.forRpcCode(1400) == .disable)
    #expect(HeartbeatErrorAction.forRpcCode(1500) == .ignore)
    #expect(HeartbeatErrorAction.forRpcCode(1504) == .ignore)
    for code in [1501, 1502, 1503, 1505, 1401] {
        #expect(HeartbeatErrorAction.forRpcCode(code) == .countMiss)
    }
}

@Test func workoutHistorySummaryFiltersLimitsAndExcludesPrivateData() throws {
    let tz = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let t1 = Date(timeIntervalSince1970: 1_795_590_000)
    let t2 = t1.addingTimeInterval(86_400)
    let run = WorkoutRecord(
        activity: "running",
        startedAt: t2,
        endedAt: t2.addingTimeInterval(1800),
        durationS: 1800,
        distanceM: 5000,
        avgHrBpm: 150.4,
        maxHrBpm: 168.0,
        avgSpeedMps: 5000.0 / 1800.0,
        avgCadenceSpm: 172.0,
        kmSplitsS: [355, 360, 365, 360, 360],
        lines: [CoachLine(at: t2, text: "private chat", source: .athlete)]
    )
    let ride = WorkoutRecord(
        activity: "cycling",
        startedAt: t1,
        endedAt: t1.addingTimeInterval(3600),
        durationS: 3600,
        distanceM: 20_000,
        avgSpeedMps: 20_000.0 / 3600.0
    )

    let allJSON = WorkoutHistory.summaryJSON(from: [ride, run], limit: 5, timeZone: tz)
    #expect(!allJSON.contains("private chat"))
    let obj = try #require(JSONSerialization.jsonObject(with: Data(allJSON.utf8)) as? [String: Any])
    #expect(obj["available"] as? Bool == true)
    #expect(obj["count"] as? Int == 2)
    let rows = try #require(obj["records"] as? [[String: Any]])
    #expect(rows[0]["activity"] as? String == "running")
    #expect(rows[0]["avg_pace_s_per_km"] as? Int == 360)
    #expect(rows[1]["activity"] as? String == "cycling")
    #expect(rows[1]["avg_pace_s_per_km"] == nil)

    let runsOnly = WorkoutHistory.summaryJSON(from: [ride, run], activity: "running", limit: 1, timeZone: tz)
    let filtered = try #require(JSONSerialization.jsonObject(with: Data(runsOnly.utf8)) as? [String: Any])
    #expect(filtered["count"] as? Int == 1)
}
