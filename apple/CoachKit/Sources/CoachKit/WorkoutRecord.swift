import Foundation

/// One line of the workout conversation, kept in the local record.
public struct CoachLine: Codable, Equatable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        /// The voice coach (server), from the agent's transcript.
        case coach
        /// The phone's own offline announcement (docs/spec.md 7.4).
        case local
        /// The user's own words, from the agent's transcript of their speech.
        case athlete
    }

    public var id: UUID
    public var at: Date
    public var text: String
    public var source: Source

    public init(id: UUID = UUID(), at: Date, text: String, source: Source) {
        self.id = id
        self.at = at
        self.text = text
        self.source = source
    }
}

/// One finished workout as the iPhone keeps it (docs/spec.md 2 step 6). Stored only on the phone;
/// the full workout lives in Apple Health. No coordinates.
public struct WorkoutRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Wire activity name, e.g. "running".
    public var activity: String
    public var startedAt: Date
    public var endedAt: Date
    public var durationS: Double
    public var distanceM: Double?
    public var energyKcal: Double?
    public var avgHrBpm: Double?
    public var maxHrBpm: Double?
    public var avgSpeedMps: Double?
    public var avgCadenceSpm: Double?
    public var avgPowerW: Double?
    /// Duration of each completed kilometre.
    public var kmSplitsS: [Double]
    public var lines: [CoachLine]

    public init(
        id: UUID = UUID(),
        activity: String,
        startedAt: Date,
        endedAt: Date,
        durationS: Double,
        distanceM: Double? = nil,
        energyKcal: Double? = nil,
        avgHrBpm: Double? = nil,
        maxHrBpm: Double? = nil,
        avgSpeedMps: Double? = nil,
        avgCadenceSpm: Double? = nil,
        avgPowerW: Double? = nil,
        kmSplitsS: [Double] = [],
        lines: [CoachLine] = []
    ) {
        self.id = id
        self.activity = activity
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationS = durationS
        self.distanceM = distanceM
        self.energyKcal = energyKcal
        self.avgHrBpm = avgHrBpm
        self.maxHrBpm = maxHrBpm
        self.avgSpeedMps = avgSpeedMps
        self.avgCadenceSpm = avgCadenceSpm
        self.avgPowerW = avgPowerW
        self.kmSplitsS = kmSplitsS
        self.lines = lines
    }

    /// Index (1-based) of the fastest kilometre, when there are at least two.
    public var fastestKm: Int? {
        guard kmSplitsS.count >= 2, let best = kmSplitsS.indices.min(by: { kmSplitsS[$0] < kmSplitsS[$1] }) else {
            return nil
        }
        return best + 1
    }
}

extension WorkoutTracker {
    /// The record of this workout; nil when no running frame was seen (nothing worth keeping).
    public func record(id: UUID = UUID(), startedAt: Date, endedAt: Date, lines: [CoachLine]) -> WorkoutRecord? {
        guard samples > 0, let activity else { return nil }
        return WorkoutRecord(
            id: id,
            activity: activity,
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: elapsedS,
            distanceM: distanceM.flatMap { $0 > 0 ? $0 : nil },
            energyKcal: energyKcal,
            avgHrBpm: mean("hr_bpm"),
            maxHrBpm: maxHrBpm,
            avgSpeedMps: mean("speed_mps"),
            avgCadenceSpm: mean("cadence_spm"),
            avgPowerW: mean("power_w"),
            kmSplitsS: kmSplits,
            lines: lines
        )
    }
}

extension WorkoutRecord {
    public static func decode(_ data: Data) throws -> WorkoutRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WorkoutRecord.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
