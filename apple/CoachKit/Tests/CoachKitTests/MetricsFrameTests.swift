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

@Test func decodesFullFixture() throws {
    let frame = try MetricsFrame.decode(fixture("metrics_frame_v1_full.json"))
    #expect(frame.seq == 128)
    #expect(frame.activity == "running")
    #expect(frame.state == .running)
    #expect(frame.phoneTs == 1_763_726_400_180)
    #expect(frame.hrBpm == 152)
    #expect(frame.gctMs == 248)
    #expect(frame.altM == 45.2)
}

@Test func missingMetricsStayNil() throws {
    let frame = try MetricsFrame.decode(fixture("metrics_frame_v1_minimal.json"))
    #expect(frame.state == .paused)
    #expect(frame.hrBpm == nil)
    #expect(frame.powerW == nil)
    #expect(frame.lat == nil)
}

@Test func everyFixtureRoundTrips() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
        .filter { $0.hasPrefix("metrics_frame_") && $0.hasSuffix(".json") }
    #expect(!names.isEmpty)
    for name in names {
        let frame = try MetricsFrame.decode(fixture(name))
        #expect(try MetricsFrame.decode(frame.encoded()) == frame)
    }
}

@Test func rejectsUnknownVersion() throws {
    var frame = MetricsFrame(seq: 1, ts: 0, activity: "running", state: .running, elapsedS: 0)
    frame.v = 2
    #expect(throws: ProtocolError.unsupportedVersion(2)) {
        try MetricsFrame.decode(frame.encoded())
    }
}
