import Foundation
import Testing

@testable import CoachKit

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../../protocol/fixtures")
    .standardized

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
}

@Test func decodesFullCueFixture() throws {
    let cue = try CoachCue.decode(fixture("coach_cue_v1_full.json"))
    #expect(cue.id == "cue-000017")
    #expect(cue.priority == .emergency)
    #expect(cue.haptic == .failure)
    #expect(cue.kind == "hr_emergency")
    #expect(cue.text == "心率过高，放慢")
    #expect(cue.expiresAt - cue.ts == 15_000)
}

@Test func minimalCueHasNoOptionalFields() throws {
    let cue = try CoachCue.decode(fixture("coach_cue_v1_minimal.json"))
    #expect(cue.priority == .milestone)
    #expect(cue.haptic == nil)
    #expect(cue.text == nil)
    #expect(cue.kind == nil)
}

@Test func everyCueFixtureRoundTrips() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
        .filter { $0.hasPrefix("coach_cue_") && $0.hasSuffix(".json") }
    #expect(!names.isEmpty)
    for name in names {
        let cue = try CoachCue.decode(fixture(name))
        #expect(try CoachCue.decode(cue.encoded()) == cue)
    }
}

@Test func cueExpiry() {
    let cue = CoachCue(id: "c", ts: 1_000, expiresAt: 11_000, priority: .correction)
    #expect(!cue.isExpired(at: Date(timeIntervalSince1970: 10.999)))
    #expect(cue.isExpired(at: Date(timeIntervalSince1970: 11)))
    #expect(cue.remaining(at: Date(timeIntervalSince1970: 8)) == 3)
    #expect(cue.remaining(at: Date(timeIntervalSince1970: 20)) == 0)
}

@Test func unknownHapticFallsBack() throws {
    let json = #"{"v":1,"id":"c","ts":0,"expires_at":1,"priority":"milestone","haptic":"rumble"}"#
    #expect(try CoachCue.decode(Data(json.utf8)).haptic == .notification)
}

@Test func rejectsUnknownCueVersion() throws {
    var cue = CoachCue(id: "c", ts: 0, expiresAt: 1, priority: .companion)
    cue.v = 2
    #expect(throws: ProtocolError.unsupportedVersion(2)) {
        try CoachCue.decode(cue.encoded())
    }
}

@Test func cueIsNotAMetricsFrame() throws {
    #expect(throws: (any Error).self) {
        try MetricsFrame.decode(fixture("coach_cue_v1_full.json"))
    }
}
