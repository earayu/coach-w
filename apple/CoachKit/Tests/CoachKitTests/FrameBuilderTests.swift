import Foundation
import Testing

@testable import CoachKit

private let t0 = Date(timeIntervalSince1970: 1_763_726_400)

@Test func firstFrameIsEmittedImmediately() throws {
    var builder = FrameBuilder(activity: "running")
    builder.apply(.heartRate(bpm: 150), at: t0)
    let emitted = builder.frame(state: .running, elapsed: 3, at: t0)
    let frame = try #require(emitted)
    #expect(frame.seq == 1)
    #expect(frame.ts == 1_763_726_400_000)
    #expect(frame.activity == "running")
    #expect(frame.hrBpm == 150)
    #expect(frame.distanceM == nil)
}

@Test func framesAreThrottled() {
    var builder = FrameBuilder(activity: "running", minInterval: 1)
    let first = builder.frame(state: .running, elapsed: 0, at: t0)
    let tooSoon = builder.frame(state: .running, elapsed: 0.5, at: t0 + 0.5)
    let due = builder.frame(state: .running, elapsed: 1, at: t0 + 1)
    #expect(first != nil)
    #expect(tooSoon == nil)
    #expect(due?.seq == 2)
}

@Test func stateChangeAndForceBypassThrottle() {
    var builder = FrameBuilder(activity: "cycling", minInterval: 1)
    _ = builder.frame(state: .running, elapsed: 0, at: t0)
    let paused = builder.frame(state: .paused, elapsed: 0.2, at: t0 + 0.2)
    let forced = builder.frame(state: .paused, elapsed: 0.3, at: t0 + 0.3, force: true)
    #expect(paused?.state == .paused)
    #expect(forced?.seq == 3)
}

@Test func cadenceIsDerivedFromCumulativeSteps() throws {
    var builder = FrameBuilder(activity: "running", cadenceWindow: 15)
    builder.apply(.steps(count: 100), at: t0)
    builder.apply(.steps(count: 115), at: t0 + 5)
    builder.apply(.steps(count: 130), at: t0 + 10)
    let emitted = builder.frame(state: .running, elapsed: 10, at: t0 + 10)
    let frame = try #require(emitted)
    #expect(frame.cadenceSpm == 180)
}

@Test func cadenceWindowDropsOldSamples() throws {
    var builder = FrameBuilder(activity: "running", cadenceWindow: 10)
    builder.apply(.steps(count: 0), at: t0)
    builder.apply(.steps(count: 100), at: t0 + 20)
    builder.apply(.steps(count: 130), at: t0 + 30)
    let emitted = builder.frame(state: .running, elapsed: 30, at: t0 + 30)
    let frame = try #require(emitted)
    #expect(frame.cadenceSpm == 180)
}

@Test func latestReadingsCarryOver() throws {
    var builder = FrameBuilder(activity: "running")
    builder.apply(.power(watts: 240), at: t0)
    _ = builder.frame(state: .running, elapsed: 0, at: t0)
    builder.apply(.heartRate(bpm: 160), at: t0 + 1)
    let emitted = builder.frame(state: .running, elapsed: 1, at: t0 + 1)
    let frame = try #require(emitted)
    #expect(frame.powerW == 240)
    #expect(frame.hrBpm == 160)
}

@Test func locationFillsCoordinatesAndAltitude() throws {
    var builder = FrameBuilder(activity: "hiking")
    builder.apply(.location(latitude: 39.9042, longitude: 116.4074, altitudeMeters: 845), at: t0)
    let first = builder.frame(state: .running, elapsed: 1, at: t0)
    let frame = try #require(first)
    #expect(frame.lat == 39.9042 && frame.lon == 116.4074 && frame.altM == 845)
    // a fix without valid altitude keeps the last altitude
    builder.apply(.location(latitude: 39.9043, longitude: 116.4075, altitudeMeters: nil), at: t0 + 2)
    let second = builder.frame(state: .running, elapsed: 3, at: t0 + 2)
    let next = try #require(second)
    #expect(next.lat == 39.9043 && next.altM == 845)
}
