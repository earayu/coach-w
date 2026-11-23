import Foundation
import Testing

@testable import CoachKit

@Test func watchStartRunningPauseStopSaveAndEndLifecycle() {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    var sm = WatchWorkoutStateMachine(finishTimeoutSeconds: 15)
    #expect(sm.phase == .idle && !sm.isActive && !sm.isRunning)

    let startEffects = sm.handle(.startRequested(activity: "running", now: t0))
    let g1 = sm.generation
    #expect(sm.phase == .starting(activity: "running"))
    #expect(startEffects == [.startSession(activity: "running", generation: g1)])

    // Delegate delivers `.running` before `beginCollection` returns.
    let runEffects = sm.handle(.sessionStateChanged(generation: g1, state: .running, at: t0, now: t0))
    #expect(sm.phase == .active(activity: "running", runState: .running) && sm.isRunning)
    #expect(runEffects == [.startHeartbeat, .emitForcedFrame(state: .running, at: t0)])

    // `beginCollection` returns -> starts GPS route without clobbering `.running`.
    let okEffects = sm.handle(.startSucceeded(generation: g1))
    #expect(sm.isRunning && okEffects == [.startRouteIfGPS])

    // Pause -> stops heartbeat and emits paused frame.
    let pauseEffects = sm.handle(.sessionStateChanged(generation: g1, state: .paused, at: t0 + 10, now: t0 + 10))
    #expect(sm.isPaused && pauseEffects == [.stopHeartbeat, .emitForcedFrame(state: .paused, at: t0 + 10)])

    // User taps End -> stops activity and schedules finish timeout.
    let endEffects = sm.handle(.endRequested)
    #expect(endEffects == [.stopActivity, .scheduleTimer(.finishTimeout, generation: g1)])

    // HealthKit transitions to `.stopped` -> enters `.saving`, emits ended frame, begins saving.
    let stopEffects = sm.handle(.sessionStateChanged(generation: g1, state: .stopped, at: t0 + 12, now: t0 + 12))
    #expect(sm.isFinishing && sm.isActive)
    #expect(stopEffects == [
        .stopHeartbeat,
        .emitForcedFrame(state: .ended, at: t0 + 12),
        .beginSaving(generation: g1, at: t0 + 12),
        .scheduleTimer(.finishTimeout, generation: g1),
    ])

    // Save completes -> ends session and schedules force-reset fallback.
    let finishEffects = sm.handle(.finishCompleted(generation: g1))
    #expect(finishEffects == [.endSession, .scheduleTimer(.forceResetTimeout, generation: g1)])

    // HealthKit transitions to `.ended` -> emits ended frame BEFORE resetResources, cancels timers.
    let endedEffects = sm.handle(.sessionStateChanged(generation: g1, state: .ended, at: t0 + 13, now: t0 + 13))
    #expect(sm.phase == .idle && !sm.isActive && sm.generation > g1)
    #expect(endedEffects == [
        .cancelTimer(.finishTimeout),
        .cancelTimer(.forceResetTimeout),
        .stopHeartbeat,
        .emitForcedFrame(state: .ended, at: t0 + 13),
        .resetResources,
    ])
}

@Test func watchRecoveryAndStartAreMutuallyExclusive() {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    var sm = WatchWorkoutStateMachine()

    let recEffects = sm.handle(.recoverRequested)
    let g1 = sm.generation
    #expect(sm.phase == .recovering && recEffects == [.runRecovery(generation: g1)])

    // A start arriving while recovery is in flight cannot stomp on recovery.
    #expect(sm.handle(.startRequested(activity: "running", now: t0)).isEmpty)
    #expect(sm.phase == .recovering)

    // Recovery finds a stopped workout -> enters saving immediately.
    let foundEffects = sm.handle(.recoveryFoundSession(
        generation: g1, activity: "running", state: .stopped, endDate: t0 - 5, now: t0
    ))
    #expect(sm.phase == .saving(activity: "running", startedSavingAt: t0))
    #expect(foundEffects == [
        .stopHeartbeat,
        .beginSaving(generation: g1, at: t0 - 5),
        .scheduleTimer(.finishTimeout, generation: g1),
    ])

    // Recovery requested while active/saving is ignored.
    #expect(sm.handle(.recoverRequested).isEmpty)
}

@Test func watchStaleSaveFailureAfterForceEndDoesNotPolluteNewWorkout() {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    var sm = WatchWorkoutStateMachine(finishTimeoutSeconds: 15)
    sm.handle(.startRequested(activity: "running", now: t0))
    let g1 = sm.generation
    sm.handle(.sessionStateChanged(generation: g1, state: .running, at: t0, now: t0))
    sm.handle(.sessionStateChanged(generation: g1, state: .stopped, at: t0 + 30, now: t0 + 30))

    // Starting before finishTimeout is rejected cleanly with `.previousWorkoutStillSaving`.
    #expect(sm.handle(.startRequested(activity: "walking", now: t0 + 40)).isEmpty)
    #expect(sm.notice == .previousWorkoutStillSaving)

    // Second tap on End while saving force-ends without restarting save.
    let secondEnd = sm.handle(.endRequested)
    #expect(secondEnd == [.endSession, .scheduleTimer(.forceResetTimeout, generation: g1)])

    // Force-reset fires -> returns to `.idle` and bumps generation.
    sm.handle(.forceResetTimerFired(generation: g1))
    #expect(sm.phase == .idle && sm.generation > g1)

    // New workout starts.
    sm.handle(.startRequested(activity: "walking", now: t0 + 43))
    let g2 = sm.generation
    #expect(sm.phase == .starting(activity: "walking") && sm.notice == nil)

    // The old workout's `finishWorkout()` finally throws: must be completely ignored!
    #expect(sm.handle(.finishFailed(generation: g1, message: "old HK error")).isEmpty)
    #expect(sm.phase == .starting(activity: "walking") && sm.generation == g2 && sm.notice == nil)
}

@Test func watchStartAfterHungSaveTimeoutDiscardsOldSessionAndStartsFresh() {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    var sm = WatchWorkoutStateMachine(finishTimeoutSeconds: 15)
    sm.handle(.startRequested(activity: "running", now: t0))
    let g1 = sm.generation
    sm.handle(.sessionStateChanged(generation: g1, state: .stopped, at: t0 + 10, now: t0 + 10))

    // Past 15s timeout -> discards leftover session and starts new one.
    let effects = sm.handle(.startRequested(activity: "cycling", now: t0 + 30))
    let g2 = sm.generation
    #expect(g2 > g1 && sm.phase == .starting(activity: "cycling") && sm.notice == nil)
    #expect(effects == [
        .cancelTimer(.finishTimeout),
        .cancelTimer(.forceResetTimeout),
        .stopHeartbeat,
        .endSession,
        .resetResources,
        .startSession(activity: "cycling", generation: g2),
    ])
}

@Test func watchStartFailedAfterRunningTearsDownCleanly() {
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    var sm = WatchWorkoutStateMachine()
    sm.handle(.startRequested(activity: "running", now: t0))
    let g1 = sm.generation
    sm.handle(.sessionStateChanged(generation: g1, state: .running, at: t0, now: t0))

    let failEffects = sm.handle(.startFailed(generation: g1, message: "beginCollection denied"))
    #expect(sm.phase == .idle && sm.notice == .startFailed("beginCollection denied"))
    #expect(failEffects == [
        .cancelTimer(.finishTimeout),
        .cancelTimer(.forceResetTimeout),
        .stopHeartbeat,
        .endSession,
        .resetResources,
    ])
}
