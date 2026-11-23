import Foundation
import Testing

@testable import CoachKit

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../../protocol/fixtures")

@Test func coachStatusFixtureDecodes() throws {
    let data = try Data(contentsOf: fixtures.appendingPathComponent("coach_status_v1_full.json"))
    let status = try CoachStatus.decode(data)
    #expect(status.coachStatus == .online)
    #expect(status.expiresAt - status.ts == 90_000)
}

@Test func coachStatusRoundTripsAndExpires() throws {
    let now = Date(timeIntervalSince1970: 1_763_726_400)
    let status = CoachStatus(.offline, at: now)
    #expect(try CoachStatus.decode(status.encoded()) == status)
    #expect(!status.isExpired(at: now + 89))
    #expect(status.isExpired(at: now + 90))
}

@Test func coachStatusAndCueAreToldApart() throws {
    // both travel on the same phone → watch channel (spec 6.3)
    let status = try CoachStatus(.online, at: .now).encoded()
    #expect(throws: (any Error).self) { try CoachCue.decode(status) }
    let cue = try CoachCue(id: "cue-1", ts: 1, expiresAt: 2, priority: .milestone).encoded()
    #expect(throws: (any Error).self) { try CoachStatus.decode(cue) }
}

@Test func unknownCoachStateReadsAsNoCoach() throws {
    let raw = #"{"v":1,"ts":1,"expires_at":2,"coach_status":"sleeping"}"#
    #expect(try CoachStatus.decode(Data(raw.utf8)).coachStatus == .off)
}
