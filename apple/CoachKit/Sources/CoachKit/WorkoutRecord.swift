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

public enum WorkoutHistory {
    private static let maxLimit = 15
    private static let maxSplitsPerRecord = 25

    /// Compact JSON summary of recent finished workouts for the coach's `coach.history` RPC
    /// (spec 11). Never includes coordinates or conversation transcripts.
    public static func summaryJSON(
        from records: [WorkoutRecord],
        activity: String = "",
        limit: Int = 5,
        timeZone: TimeZone = .current
    ) -> String {
        let filter = activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let capped = max(1, min(limit > 0 ? limit : 5, maxLimit))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let matching = records
            .sorted { $0.startedAt > $1.startedAt }
            .filter { filter.isEmpty || $0.activity.lowercased() == filter }
            .prefix(capped)

        let items: [[String: Any]] = matching.map { r in
            var row: [String: Any] = [
                "date": formatter.string(from: r.startedAt),
                "activity": r.activity,
                "duration_s": Int(r.durationS.rounded()),
            ]
            if let d = r.distanceM, d > 0 { row["distance_m"] = Int(d.rounded()) }
            if let hr = r.avgHrBpm { row["avg_hr_bpm"] = Int(hr.rounded()) }
            if let maxHr = r.maxHrBpm { row["max_hr_bpm"] = Int(maxHr.rounded()) }
            if let speed = r.avgSpeedMps, speed > 0.3 {
                row["avg_speed_kmh"] = (speed * 36.0).rounded() / 10.0
                if r.activity != "cycling" {
                    row["avg_pace_s_per_km"] = Int((1000.0 / speed).rounded())
                }
            }
            if let cad = r.avgCadenceSpm { row["avg_cadence_spm"] = Int(cad.rounded()) }
            if let kcal = r.energyKcal, kcal > 0 { row["energy_kcal"] = Int(kcal.rounded()) }
            if !r.kmSplitsS.isEmpty {
                row["km_splits_s"] = r.kmSplitsS.prefix(maxSplitsPerRecord).map { Int($0.rounded()) }
            }
            return row
        }

        let payload: [String: Any] = [
            "available": true,
            "count": items.count,
            "records": items,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"available":false,"reason":"encode failed"}"#
        }
        return json
    }
}
