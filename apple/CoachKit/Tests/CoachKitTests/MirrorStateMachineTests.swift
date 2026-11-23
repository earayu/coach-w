import Foundation
import Testing

@testable import CoachKit

@Test func mirrorLaunchFlowAndSlowPrompt() {
    var sm = MirrorStateMachine()
    #expect(sm.phase == .idle && !sm.isActive && !sm.isWorkoutVisible && !sm.isStartingWatch)

    let startEffects = sm.handle(.startOnWatch(activity: "running"))
    let sg = sm.startGeneration
    #expect(sm.phase == .launchingWatch(activity: "running", slow: false))
    #expect(sm.isStartingWatch && !sm.isWatchSlowToStart && !sm.isWorkoutVisible)
    #expect(startEffects == [
        .scheduleTimer(.slowStart, generation: sg),
        .scheduleTimer(.attachTimeout, generation: sg),
        .callStartWatchApp(activity: "running", generation: sg),
    ])

    // Duplicate start while launching is ignored.
    #expect(sm.handle(.startOnWatch(activity: "cycling")).isEmpty)

    sm.handle(.slowStartTimerFired(generation: sg))
    #expect(sm.isWatchSlowToStart)

    let startedEffects = sm.handle(.watchAppStarted(generation: sg))
    #expect(sm.phase == .awaitingMirror(activity: "running"))
    #expect(sm.isWorkoutVisible && !sm.isActive && !sm.isWatchSlowToStart && sm.awaitingActivity == "running")
    #expect(startedEffects == [.cancelTimer(.slowStart)])

    // Cancelling after watch already took the start is ignored.
    #expect(sm.handle(.cancelStart).isEmpty)

    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    let attachEffects = sm.handle(.sessionAttached(activity: "running", startedAt: t0, state: .running))
    let g1 = sm.sessionGeneration
    #expect(sm.isActive && sm.isRunning && !sm.isStartingWatch && sm.awaitingActivity == nil)
    #expect(attachEffects == [
        .cancelTimer(.slowStart),
        .cancelTimer(.attachTimeout),
        .resetMetrics,
        .attachIncomingSession(generation: g1),
        .notifySessionStarted(activity: "running"),
    ])

    // Late start timers from before attach are ignored.
    #expect(sm.handle(.attachTimerFired(generation: sg)).isEmpty)
    #expect(sm.handle(.watchAppStartFailed(generation: sg, message: "late")).isEmpty)
}

@Test func mirrorEndWhileAwaitingMirrorDoesNotNotifySessionEnded() {
    var sm = MirrorStateMachine()
    sm.handle(.startOnWatch(activity: "running"))
    sm.handle(.watchAppStarted(generation: sm.startGeneration))
    #expect(sm.phase == .awaitingMirror(activity: "running"))

    let effects = sm.handle(.endRequested)
    #expect(sm.phase == .idle)
    #expect(sm.notice == .endedWhileAwaitingMirror)
    #expect(effects == [.cancelTimer(.slowStart), .cancelTimer(.attachTimeout)])
    #expect(!effects.contains(.notifySessionEnded))
}

@Test func mirrorFollowsRunningFrameFromPreparedAndPausedStates() {
    var sm = MirrorStateMachine()
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    sm.handle(.sessionAttached(activity: "running", startedAt: t0, state: .prepared))
    let g = sm.sessionGeneration
    #expect(sm.isActive && !sm.isRunning && !sm.isPaused)

    // Running frame rescues a session stuck in `.prepared` when HealthKit dropped the state callback.
    sm.handle(.framesReceived(generation: g, latestState: .running))
    #expect(sm.isRunning)

    sm.handle(.framesReceived(generation: g, latestState: .paused))
    #expect(sm.isPaused)

    sm.handle(.framesReceived(generation: g, latestState: .running))
    #expect(sm.isRunning)

    let endEffects = sm.handle(.framesReceived(generation: g, latestState: .ended))
    #expect(sm.phase == .idle && !sm.isActive)
    #expect(endEffects == [.cancelTimer(.endTimeout), .detachSession, .notifySessionEnded])
}

@Test func mirrorDisconnectReattachContinuationAndGenerationScopedTimers() {
    var sm = MirrorStateMachine()
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    sm.handle(.sessionAttached(activity: "running", startedAt: t0, state: .running))
    let g1 = sm.sessionGeneration

    let discEffects = sm.handle(.sessionDisconnected(generation: g1, message: "bt lost"))
    let gDisc = sm.sessionGeneration
    #expect(gDisc > g1)
    #expect(sm.isActive && sm.isRunning)
    #expect(sm.notice == .disconnected("bt lost"))
    #expect(discEffects == [
        .cancelTimer(.endTimeout),
        .detachSession,
        .scheduleTimer(.reattachTimeout, generation: gDisc),
    ])

    // Controls show notice while disconnected.
    #expect(sm.handle(.pauseRequested).isEmpty)
    #expect(sm.notice == .controlsUnavailableWhileDisconnected)

    // HealthKit re-mirrors the same workout: continues without resetMetrics or notifySessionStarted.
    let reattachEffects = sm.handle(.sessionAttached(activity: "running", startedAt: t0, state: .running))
    let g2 = sm.sessionGeneration
    #expect(g2 > gDisc && sm.notice == nil && sm.isActive)
    #expect(reattachEffects == [
        .cancelTimer(.reattachTimeout),
        .detachSession,
        .attachIncomingSession(generation: g2),
    ])

    // Stale reattach timer from gDisc is ignored even if it fires late.
    #expect(sm.handle(.reattachTimerFired(generation: gDisc)).isEmpty)
    #expect(sm.isActive)
}

@Test func mirrorNilStartDateDoesNotLetOldReattachTimerKillNewWorkout() {
    var sm = MirrorStateMachine()
    sm.handle(.sessionAttached(activity: "running", startedAt: nil, state: .running))
    sm.handle(.sessionDisconnected(generation: sm.sessionGeneration, message: "lost"))
    let oldDiscGen = sm.sessionGeneration

    // A brand-new workout (also with nil startDate) attaches before the old reattach timer fires.
    let effects = sm.handle(.sessionAttached(activity: "walking", startedAt: nil, state: .running))
    #expect(effects.contains(.notifySessionEnded))
    #expect(effects.contains(.notifySessionStarted(activity: "walking")))
    #expect(sm.activeActivity == "walking")

    // The old reattach timer fires: must NOT close the new walking workout!
    #expect(sm.handle(.reattachTimerFired(generation: oldDiscGen)).isEmpty)
    #expect(sm.isActive && sm.activeActivity == "walking")
}

@Test func mirrorNeverStartsZombieWorkoutFromAlreadyEndedSession() {
    var sm = MirrorStateMachine()
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    let effects = sm.handle(.sessionAttached(activity: "running", startedAt: t0, state: .ended))
    #expect(sm.phase == .idle && !sm.isActive)
    #expect(effects == [.detachSession])
    #expect(!effects.contains(.notifySessionStarted(activity: "running")))
}

@Test func mirrorDisconnectWhileEndingClosesImmediately() {
    var sm = MirrorStateMachine()
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    sm.handle(.sessionAttached(activity: "running", startedAt: t0, state: .running))
    let g = sm.sessionGeneration

    let endEffects = sm.handle(.endRequested)
    #expect(endEffects == [.sendStop, .scheduleTimer(.endTimeout, generation: g)])

    // Watch disconnects before confirming end: close immediately rather than waiting 120s.
    let discEffects = sm.handle(.sessionDisconnected(generation: g, message: "gone"))
    #expect(sm.phase == .idle && sm.notice == .endedWhileDisconnected)
    #expect(discEffects == [.cancelTimer(.endTimeout), .detachSession, .notifySessionEnded])
}
