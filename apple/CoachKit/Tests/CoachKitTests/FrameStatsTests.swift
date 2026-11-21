import Testing

@testable import CoachKit

private func frame(_ seq: Int, ts: Int64, phoneTs: Int64? = nil) -> MetricsFrame {
    MetricsFrame(seq: seq, ts: ts, activity: "running", state: .running, elapsedS: 0, phoneTs: phoneTs)
}

@Test func countsMissingFramesAndMeanInterval() {
    var stats = FrameStats()
    stats.record(frame(1, ts: 0))
    stats.record(frame(2, ts: 1000))
    stats.record(frame(5, ts: 4000, phoneTs: 4120))
    #expect(stats.received == 3)
    #expect(stats.missing == 2)
    #expect(stats.meanInterval == 2)
    #expect(stats.lastDelayMs == 120)
}

@Test func lateFramesAreCountedButIgnored() {
    var stats = FrameStats()
    stats.record(frame(3, ts: 3000))
    stats.record(frame(2, ts: 2000))
    stats.record(frame(4, ts: 4000))
    #expect(stats.outOfOrder == 1)
    #expect(stats.missing == 0)
    #expect(stats.meanInterval == 1)
}
