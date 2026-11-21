import Foundation

/// Follows one workout on the iPhone from the frames the watch sends.
///
/// Feeds three things that must work without the server: the `coach.resume` summary for a new
/// coach session, the offline `LocalCoach`, and the local workout record. Like the server, only
/// running frames count, time is the watch's `elapsedS`, and coordinates are never kept.
public struct WorkoutTracker: Sendable {
    /// Fields averaged over the workout; the same set the server samples.
    public static let sampledFields: [(name: String, value: @Sendable (MetricsFrame) -> Double?)] = [
        ("hr_bpm", { $0.hrBpm }),
        ("speed_mps", { $0.speedMps }),
        ("cadence_spm", { $0.cadenceSpm }),
        ("power_w", { $0.powerW }),
        ("stride_m", { $0.strideM }),
        ("gct_ms", { $0.gctMs }),
        ("vo_cm", { $0.voCm }),
        ("alt_m", { $0.altM }),
    ]

    public private(set) var latest: MetricsFrame?
    /// Workout time at which each whole kilometre was completed.
    public private(set) var kmMarks: [Double] = []
    public private(set) var maxHrBpm: Double?
    /// Running frames seen.
    public private(set) var samples = 0

    private var sums: [String: Double] = [:]
    private var counts: [String: Int] = [:]
    private var lastSampleElapsed: Double?
    private var lastDistance: (elapsed: Double, meters: Double)?

    public init() {}

    public var activity: String? { latest?.activity }
    public var elapsedS: Double { latest?.elapsedS ?? 0 }
    public var distanceM: Double? { lastDistance?.meters }
    public var energyKcal: Double? { latest?.energyKcal }
    public var hasEnded: Bool { latest?.state == .ended }

    /// Takes `frame` if it is newer than the last one. Returns false for late or repeated frames.
    @discardableResult
    public mutating func ingest(_ frame: MetricsFrame) -> Bool {
        if let latest, frame.seq <= latest.seq { return false }
        var frame = frame
        // the last reading stays meaningful when a frame happens to lack it (e.g. the final one)
        if frame.energyKcal == nil { frame.energyKcal = latest?.energyKcal }
        latest = frame
        if frame.state == .running { sample(frame) }
        return true
    }

    public func mean(_ field: String) -> Double? {
        guard let count = counts[field], count > 0, let sum = sums[field] else { return nil }
        return sum / Double(count)
    }

    /// Duration of each completed kilometre, in order.
    public var kmSplits: [Double] {
        zip(kmMarks, [0] + kmMarks).map { $0 - $1 }
    }

    /// The summary a new coach session continues from; nil before the first frame.
    public func resume(at date: Date) -> CoachResume? {
        guard let latest else { return nil }
        var means: [String: Double] = [:]
        for (name, _) in Self.sampledFields { means[name] = mean(name) }
        return CoachResume(
            ts: Int64((date.timeIntervalSince1970 * 1000).rounded()),
            activity: latest.activity,
            state: latest.state,
            elapsedS: latest.elapsedS,
            distanceM: distanceM,
            energyKcal: energyKcal,
            kmMarksS: kmMarks,
            means: means,
            samples: samples > 0 ? samples : nil
        )
    }

    private mutating func sample(_ frame: MetricsFrame) {
        if let lastSampleElapsed, frame.elapsedS <= lastSampleElapsed { return }
        lastSampleElapsed = frame.elapsedS
        samples += 1
        for (name, value) in Self.sampledFields {
            guard let v = value(frame) else { continue }
            sums[name, default: 0] += v
            counts[name, default: 0] += 1
        }
        if let hr = frame.hrBpm { maxHrBpm = max(maxHrBpm ?? hr, hr) }
        if let meters = frame.distanceM { trackKilometres(elapsed: frame.elapsedS, meters: meters) }
    }

    private mutating func trackKilometres(elapsed: Double, meters: Double) {
        // A tracker that joins late interpolates the early kilometres from the start; the phone
        // normally follows the workout from its first frame.
        let previous = lastDistance ?? (0, 0)
        lastDistance = (elapsed, meters)
        while meters >= Double(kmMarks.count + 1) * 1000 {
            let boundary = Double(kmMarks.count + 1) * 1000
            let cross: Double
            if meters > previous.meters, previous.meters < boundary {
                let fraction = (boundary - previous.meters) / (meters - previous.meters)
                cross = previous.elapsed + fraction * (elapsed - previous.elapsed)
            } else {
                cross = elapsed
            }
            kmMarks.append(cross)
        }
    }
}
