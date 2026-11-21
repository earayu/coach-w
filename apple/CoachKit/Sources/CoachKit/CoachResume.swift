import Foundation

/// `coach.resume`, wire protocol v1 (docs/spec.md 6.3): iPhone → server.
///
/// Sent when a coach session (re)joins a workout already under way, so the new session carries on
/// instead of starting over (docs/spec.md 7.4). Never carries coordinates.
public struct CoachResume: Codable, Equatable, Sendable {
    /// LiveKit data channel topic, iPhone → server.
    public static let topic = "coach.resume"

    public var v: Int
    /// Phone time, Unix milliseconds.
    public var ts: Int64
    public var activity: String
    public var state: WorkoutState
    public var elapsedS: Double
    public var distanceM: Double?
    public var energyKcal: Double?
    /// Workout time at which kilometre `i + 1` was completed.
    public var kmMarksS: [Double]?
    /// Whole-workout averages of sampled metrics, keyed by wire field name (e.g. `hr_bpm`).
    public var means: [String: Double]?
    /// Number of running frames the means are over.
    public var samples: Int?

    public init(
        ts: Int64,
        activity: String,
        state: WorkoutState,
        elapsedS: Double,
        distanceM: Double? = nil,
        energyKcal: Double? = nil,
        kmMarksS: [Double] = [],
        means: [String: Double] = [:],
        samples: Int? = nil
    ) {
        self.v = MetricsFrame.protocolVersion
        self.ts = ts
        self.activity = activity
        self.state = state
        self.elapsedS = elapsedS
        self.distanceM = distanceM
        self.energyKcal = energyKcal
        self.kmMarksS = kmMarksS.isEmpty ? nil : kmMarksS
        self.means = means.isEmpty ? nil : means
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case v, ts, activity, state, means, samples
        case elapsedS = "elapsed_s"
        case distanceM = "distance_m"
        case energyKcal = "energy_kcal"
        case kmMarksS = "km_marks_s"
    }
}

extension CoachResume {
    public static func decode(_ data: Data) throws -> CoachResume {
        let resume = try JSONDecoder().decode(CoachResume.self, from: data)
        guard resume.v == MetricsFrame.protocolVersion else { throw ProtocolError.unsupportedVersion(resume.v) }
        return resume
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
