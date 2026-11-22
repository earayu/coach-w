import CoachKit
import HealthKit

/// Converts live workout statistics into wire-unit readings.
enum HealthReadings {
    private static let perMinute = HKUnit.count().unitDivided(by: .minute())
    private static let metersPerSecond = HKUnit.meter().unitDivided(by: .second())

    static func reading(from statistics: HKStatistics, derivesCadenceFromSteps: Bool) -> MetricReading? {
        let recent = statistics.mostRecentQuantity()
        let sum = statistics.sumQuantity()
        switch statistics.quantityType {
        case HKQuantityType(.heartRate):
            return recent.map { .heartRate(bpm: $0.doubleValue(for: perMinute)) }
        case HKQuantityType(.activeEnergyBurned):
            return sum.map { .activeEnergy(kilocalories: $0.doubleValue(for: .kilocalorie())) }
        case HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling):
            return sum.map { .distance(meters: $0.doubleValue(for: .meter())) }
        case HKQuantityType(.runningSpeed), HKQuantityType(.cyclingSpeed):
            return recent.map { .speed(metersPerSecond: $0.doubleValue(for: metersPerSecond)) }
        case HKQuantityType(.stepCount):
            guard derivesCadenceFromSteps else { return nil }
            return sum.map { .steps(count: $0.doubleValue(for: .count())) }
        case HKQuantityType(.cyclingCadence):
            return recent.map { .cadence(perMinute: $0.doubleValue(for: perMinute)) }
        case HKQuantityType(.runningPower), HKQuantityType(.cyclingPower):
            return recent.map { .power(watts: $0.doubleValue(for: .watt())) }
        case HKQuantityType(.runningStrideLength):
            return recent.map { .strideLength(meters: $0.doubleValue(for: .meter())) }
        case HKQuantityType(.runningGroundContactTime):
            return recent.map { .groundContactTime(milliseconds: $0.doubleValue(for: .secondUnit(with: .milli))) }
        case HKQuantityType(.runningVerticalOscillation):
            return recent.map { .verticalOscillation(centimeters: $0.doubleValue(for: .meterUnit(with: .centi))) }
        default:
            return nil
        }
    }
}

extension HKWorkoutSessionState {
    var wireState: WorkoutState {
        switch self {
        case .running: .running
        case .stopped, .ended: .ended
        default: .paused
        }
    }

    var isActive: Bool { self != .notStarted && self != .ended }

    /// For diagnostics.
    var label: String {
        switch self {
        case .notStarted: "notStarted"
        case .prepared: "prepared"
        case .running: "running"
        case .paused: "paused"
        case .stopped: "stopped"
        case .ended: "ended"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}
