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

@Test func decodesFullResumeFixture() throws {
    let resume = try CoachResume.decode(fixture("coach_resume_v1_full.json"))
    #expect(resume.activity == "running")
    #expect(resume.state == .running)
    #expect(resume.elapsedS == 1260.5)
    #expect(resume.kmMarksS == [318.4, 640.1, 965.8])
    #expect(resume.means?["hr_bpm"] == 151.3)
    #expect(resume.samples == 1180)
}

@Test func minimalResumeHasNoOptionalFields() throws {
    let resume = try CoachResume.decode(fixture("coach_resume_v1_minimal.json"))
    #expect(resume.state == .paused)
    #expect(resume.distanceM == nil && resume.kmMarksS == nil && resume.means == nil && resume.samples == nil)
}

@Test func everyResumeFixtureRoundTrips() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.path)
        .filter { $0.hasPrefix("coach_resume_") && $0.hasSuffix(".json") }
    #expect(names.count == 2)
    for name in names {
        let resume = try CoachResume.decode(fixture(name))
        #expect(try CoachResume.decode(resume.encoded()) == resume)
    }
}

@Test func emptyCollectionsAreLeftOutOnTheWire() throws {
    let resume = CoachResume(ts: 1, activity: "yoga", state: .running, elapsedS: 3)
    let json = try #require(String(data: resume.encoded(), encoding: .utf8))
    #expect(!json.contains("km_marks_s") && !json.contains("means") && !json.contains("lat"))
}

@Test func rejectsUnknownResumeVersion() throws {
    var data = try JSONSerialization.jsonObject(with: fixture("coach_resume_v1_minimal.json")) as! [String: Any]
    data["v"] = 2
    let raw = try JSONSerialization.data(withJSONObject: data)
    #expect(throws: ProtocolError.unsupportedVersion(2)) { try CoachResume.decode(raw) }
}
