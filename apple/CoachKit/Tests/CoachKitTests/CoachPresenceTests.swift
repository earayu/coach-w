import Foundation
import Testing

@testable import CoachKit

private let t0 = Date(timeIntervalSince1970: 1_763_726_400)

private func at(_ seconds: TimeInterval) -> Date { t0 + seconds }

@Test func presenceNeverHangsUpDuringAWorkout() {
    var p = CoachPresence()
    p.workoutStarted()
    p.coachConnected(at: at(0))
    #expect(p.stage == .workout)
    #expect(!p.shouldHangUp(at: at(5 * 3600)))
}

@Test func presenceHangsUpAfterAQuietSpellOnceTheWorkoutEnded() {
    var p = CoachPresence()
    p.coachConnected(at: at(0))
    p.workoutStarted()
    p.workoutEnded(at: at(1800))
    p.talked(at: at(1830))
    #expect(!p.shouldHangUp(at: at(1830 + 119)))
    #expect(p.shouldHangUp(at: at(1830 + 120)))
}

@Test func presenceHangsUpTenMinutesAfterTheWorkoutEvenWhileChatting() {
    var p = CoachPresence()
    p.coachConnected(at: at(0))
    p.workoutStarted()
    p.workoutEnded(at: at(1800))
    p.talked(at: at(1800 + 590))
    #expect(!p.shouldHangUp(at: at(1800 + 599)))
    #expect(p.shouldHangUp(at: at(1800 + 600)))
}

@Test func presenceHangsUpWhenTheWorkoutNeverStarts() {
    var p = CoachPresence()
    p.coachConnected(at: at(0))
    p.talked(at: at(300))
    #expect(!p.shouldHangUp(at: at(300 + 599)))
    #expect(p.shouldHangUp(at: at(300 + 600)))
    p.workoutStarted()
    #expect(!p.shouldHangUp(at: at(3600)))
}

@Test func presenceStartsAfreshWhenTheCoachIsCalledLongAfterAWorkout() {
    var p = CoachPresence()
    p.workoutStarted()
    p.workoutEnded(at: at(1800))  // the coach was not connected for this one
    p.coachConnected(at: at(7200))
    #expect(p.stage == .beforeWorkout(since: at(7200)))
    #expect(!p.shouldHangUp(at: at(7200 + 300)))
}

@Test func presenceKeepsTheAfterWorkoutClockAcrossANetworkReconnect() {
    var p = CoachPresence()
    p.coachConnected(at: at(0))
    p.workoutStarted()
    p.workoutEnded(at: at(1800))
    p.coachConnected(at: at(1850))  // LiveKit rejoined the same room
    #expect(p.stage == .afterWorkout(endedAt: at(1800)))
}

@Test func presenceRejoinsOnlyALongSessionCutDuringAWorkout() {
    var p = CoachPresence()
    p.coachConnected(at: at(0))
    #expect(!p.shouldRejoin(at: at(3600)))  // no workout: the cap simply ends it
    p.workoutStarted()
    #expect(p.shouldRejoin(at: at(3600)))
    #expect(!p.shouldRejoin(at: at(60)))  // ended right away: removed, not the cap
    p.coachStopped()
    #expect(!p.shouldRejoin(at: at(3600)))
    p.coachConnected(at: at(3605))
    #expect(p.stage == .workout)
    #expect(!p.shouldRejoin(at: at(3650)))
    #expect(p.shouldRejoin(at: at(3605 + 120)))
}
