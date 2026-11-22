import Foundation
import Testing

@testable import CoachKit

private func frame(
    seq: Int = 1, ts: Int64 = 0, state: WorkoutState = .running, elapsed: Double = 29, phoneTs: Int64? = 100_000
) -> MetricsFrame {
    MetricsFrame(seq: seq, ts: ts, activity: "running", state: state, elapsedS: elapsed, phoneTs: phoneTs)
}

private func at(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

@Test func runningClockKeepsCountingAfterTheLastFrame() {
    let f = frame()
    #expect(f.elapsed(at: at(ms: 100_000)) == 29)
    #expect(f.elapsed(at: at(ms: 131_000)) == 60)
    #expect(f.isStale(at: at(ms: 104_000)) == false)
    #expect(f.isStale(at: at(ms: 106_000)))
}

@Test func pausedClockStopsAndIsNeverStale() {
    let f = frame(state: .paused)
    #expect(f.elapsed(at: at(ms: 200_000)) == 29)
    #expect(f.isStale(at: at(ms: 200_000)) == false)
}

@Test func unstampedFrameShowsItsOwnTime() {
    let f = frame(phoneTs: nil)
    #expect(f.elapsed(at: at(ms: 200_000)) == 29)
    #expect(f.silence(at: at(ms: 200_000)) == nil)
}

@Test func newerByWatchTimeEvenWhenSeqRestarts() {
    let before = frame(seq: 40, ts: 40_000)
    let afterRelaunch = frame(seq: 1, ts: 41_000)
    #expect(afterRelaunch.isNewer(than: before))
    #expect(before.isNewer(than: afterRelaunch) == false)
    #expect(before.isNewer(than: nil))
}
