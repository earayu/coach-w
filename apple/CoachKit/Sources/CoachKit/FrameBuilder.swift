import Foundation

/// A metric reading taken from the workout builder, already converted to wire units.
public enum MetricReading: Sendable, Equatable {
    case heartRate(bpm: Double)
    case distance(meters: Double)
    case speed(metersPerSecond: Double)
    /// Cumulative step count for the workout; cadence is derived from it.
    case steps(count: Double)
    /// Cadence reported directly by a sensor (cycling).
    case cadence(perMinute: Double)
    case power(watts: Double)
    case strideLength(meters: Double)
    case groundContactTime(milliseconds: Double)
    case verticalOscillation(centimeters: Double)
    case activeEnergy(kilocalories: Double)
}

/// Merges readings as they arrive and emits throttled metrics frames.
///
/// Pure value type so the watch app stays thin and the logic is testable on the command line.
public struct FrameBuilder: Sendable {
    public let activity: String
    /// Minimum time between two emitted frames, seconds.
    public let minInterval: TimeInterval
    /// Window used to derive cadence from cumulative steps, seconds.
    public let cadenceWindow: TimeInterval

    private var seq = 0
    private var lastEmit: Date?
    private var latest = MetricsFrame(seq: 0, ts: 0, activity: "", state: .running, elapsedS: 0)
    private var stepHistory: [(at: Date, count: Double)] = []

    public init(activity: String, minInterval: TimeInterval = 1, cadenceWindow: TimeInterval = 15) {
        self.activity = activity
        self.minInterval = minInterval
        self.cadenceWindow = cadenceWindow
    }

    public mutating func apply(_ reading: MetricReading, at date: Date) {
        switch reading {
        case .heartRate(let bpm): latest.hrBpm = bpm
        case .distance(let m): latest.distanceM = m
        case .speed(let mps): latest.speedMps = mps
        case .cadence(let spm): latest.cadenceSpm = spm
        case .power(let w): latest.powerW = w
        case .strideLength(let m): latest.strideM = m
        case .groundContactTime(let ms): latest.gctMs = ms
        case .verticalOscillation(let cm): latest.voCm = cm
        case .activeEnergy(let kcal): latest.energyKcal = kcal
        case .steps(let count): recordSteps(count, at: date)
        }
    }

    /// Returns a frame when one is due: always for state changes, otherwise at most every `minInterval`.
    public mutating func frame(
        state: WorkoutState, elapsed: TimeInterval, at date: Date, force: Bool = false
    ) -> MetricsFrame? {
        let stateChanged = state != latest.state
        if !force, !stateChanged, let lastEmit, date.timeIntervalSince(lastEmit) < minInterval {
            return nil
        }
        seq += 1
        lastEmit = date
        latest.seq = seq
        latest.ts = Int64((date.timeIntervalSince1970 * 1000).rounded())
        latest.activity = activity
        latest.state = state
        latest.elapsedS = elapsed
        return latest
    }

    private mutating func recordSteps(_ count: Double, at date: Date) {
        let window = cadenceWindow
        stepHistory.append((date, count))
        stepHistory.removeAll { date.timeIntervalSince($0.at) > window }
        guard let first = stepHistory.first, first.at < date else { return }
        let minutes = date.timeIntervalSince(first.at) / 60
        latest.cadenceSpm = max(0, (count - first.count) / minutes)
    }
}
