import Foundation
import Testing

@testable import CoachKit

// MARK: - WorkoutTracker

@Test func trackerInterpolatesKilometreMarks() {
    var w = SynthWorkout()
    w.run(700, speed: 1000 / 300.0)  // 5'00" per km
    #expect(w.tracker.kmMarks.count == 2)
    #expect(abs(w.tracker.kmMarks[0] - 300) < 0.01 && abs(w.tracker.kmMarks[1] - 600) < 0.01)
    #expect(w.tracker.kmSplits.map { $0.rounded() } == [300, 300])
}

@Test func trackerIgnoresLateFramesAndPausedTime() {
    var w = SynthWorkout()
    w.run(10, hr: 150)
    w.run(30, hr: 99, state: .paused)
    let late = MetricsFrame(seq: 3, ts: 0, activity: "running", state: .running, elapsedS: 3, hrBpm: 200)
    let accepted = w.tracker.ingest(late)
    #expect(!accepted)
    #expect(w.tracker.samples == 10)
    #expect(w.tracker.mean("hr_bpm") == 150)
    #expect(w.tracker.maxHrBpm == 150)
}

@Test func trackerResumeSummarisesWithoutCoordinates() throws {
    var w = SynthWorkout()
    w.run(400, speed: 1000 / 300.0, hr: 150, lat: 39.9)
    let resume = try #require(w.tracker.resume(at: Date(timeIntervalSince1970: 1_763_727_000)))
    #expect(resume.activity == "running" && resume.state == .running)
    #expect(resume.elapsedS == 400 && resume.samples == 400)
    #expect(resume.kmMarksS?.count == 1)
    #expect(resume.means?["hr_bpm"] == 150 && resume.means?["power_w"] == nil)
    let json = try #require(String(data: resume.encoded(), encoding: .utf8))
    #expect(!json.contains("lat") && !json.contains("39.9"))
}

@Test func noResumeBeforeAnyFrame() {
    #expect(WorkoutTracker().resume(at: .now) == nil)
}

@Test func recordKeepsWholeWorkoutNumbersAndLines() throws {
    var w = SynthWorkout()
    w.run(650, speed: 1000 / 320.0, hr: 148)
    w.run(2, state: .ended)
    let start = Date(timeIntervalSince1970: 1_763_726_400)
    let lines = [CoachLine(at: start + 5, text: "加油", source: .coach)]
    let record = try #require(w.tracker.record(startedAt: start, endedAt: start + 660, lines: lines))
    #expect(record.activity == "running" && record.durationS == 650)
    #expect(record.avgHrBpm == 148 && record.maxHrBpm == 148)
    #expect(record.kmSplitsS.count == 2 && record.fastestKm != nil)
    #expect(abs(record.energyKcal! - 130) < 0.01)
    let decoded = try WorkoutRecord.decode(record.encoded())
    #expect(decoded == record)
}

@Test func noRecordWithoutRunningFrames() {
    var w = SynthWorkout()
    w.run(5, state: .paused)
    #expect(w.tracker.record(startedAt: .now, endedAt: .now, lines: []) == nil)
}

// MARK: - LocalCoach

@Test func offlineCoachAnnouncesSplitsAndTheEnd() {
    var w = SynthWorkout()
    w.run(640, speed: 1000 / 300.0)
    w.run(1, state: .ended)
    #expect(w.kinds == ["split:1", "split:2", "end"])
    #expect(w.cues[0].speech == "第 1 公里，这一公里用时 5 分。")
    #expect(w.cues[0].cue.priority == .milestone && w.cues[0].cue.haptic == .success)
    #expect(w.cues[0].cue.text == "第 1 公里")
    #expect(w.cues[2].speech.hasPrefix("运动结束了，用时 10 分 40 秒，距离 2.13 公里"))
}

@Test func offlineCoachHeartRateNeedsASustainedStreak() {
    var w = SynthWorkout(config: .init(splitKm: nil))
    w.run(60, hr: 150)
    w.run(10, hr: 190)
    w.run(5, hr: nil)  // a gap in the data breaks the streak
    w.run(14, hr: 190)
    #expect(w.kinds.isEmpty)
    w.run(5, hr: 190)
    #expect(w.kinds == ["hr_emergency"])
    let cue = w.cues[0]
    #expect(cue.cue.priority == .emergency && cue.cue.haptic == .failure && cue.cue.text == "心率过高")
    #expect(cue.speech.contains("190"))
    // cooldown: no repeat for 90 s of running
    w.run(60, hr: 190)
    #expect(w.kinds.count == 1)
    w.run(40, hr: 190)
    #expect(w.kinds.count == 2)
}

@Test func offlineCoachWithoutSensorsSaysNothing() {
    var w = SynthWorkout(activity: "other", config: .init(splitKm: nil))
    w.run(1800, speed: nil, hr: nil)
    #expect(w.kinds.isEmpty)
}

@Test func offlineCoachMarksTimeForActivitiesWithoutDistance() {
    var w = SynthWorkout(activity: "other", config: .init(splitKm: nil, timeMarkS: 600))
    w.run(1250, speed: nil, hr: 120)
    #expect(w.kinds == ["time:1", "time:2"])
    #expect(w.cues[1].speech == "已经运动 20 分钟了，继续加油。")
}

@Test func offlineCoachGroupsKilometresForLongSplits() {
    var w = SynthWorkout(activity: "cycling", config: .init(splitKm: 5))
    w.run(1500, speed: 7)  // 10.5 km
    #expect(w.kinds == ["split:1", "split:2"])
    #expect(w.cues[1].speech.hasPrefix("第 10 公里，这 5 公里用时"))
}

@Test func offlineCuesExpireLikeServerCues() throws {
    var w = SynthWorkout()
    w.run(301, speed: 1000 / 300.0)
    let cue = try #require(w.cues.first?.cue)
    #expect(cue.expiresAt - cue.ts == 20_000)
    #expect(cue.id.hasPrefix("local-"))
}

@Test func spokenFormats() {
    #expect(Spoken.duration(45) == "45 秒")
    #expect(Spoken.duration(750) == "12 分 30 秒")
    #expect(Spoken.duration(3903) == "1 小时 5 分 3 秒")
    #expect(Spoken.distance(850) == "850 米")
    #expect(Spoken.distance(3845.2) == "3.85 公里")
}

// MARK: - ReconnectPolicy

@Test func reconnectBacksOffAndCapsTheDelay() {
    let policy = ReconnectPolicy(delays: [1, 2, 5])
    #expect([0, 1, 2, 3, 10].map(policy.delay(forAttempt:)) == [1, 2, 5, 5, 5])
}

@Test func reconnectOnlyAfterNetworkDrops() {
    let policy = ReconnectPolicy()
    #expect(policy.shouldRetry(.network) && !policy.shouldRetry(.final))
    #expect(ReconnectPolicy.drop(forHTTPStatus: 401) == .final)
    #expect(ReconnectPolicy.drop(forHTTPStatus: 429) == .final)
    #expect(ReconnectPolicy.drop(forHTTPStatus: 502) == .network)
    #expect(ReconnectPolicy.drop(forHTTPStatus: 0) == .network)
}
