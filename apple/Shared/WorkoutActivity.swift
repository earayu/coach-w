import CoachKit
import HealthKit

/// Activities offered in the UI, and how each maps to HealthKit and the wire protocol.
///
/// This is a data table, not coaching logic: coaching differences live in server-side profiles.
enum WorkoutActivity: String, CaseIterable, Identifiable, Sendable {
    case running
    case walking
    case hiking
    case cycling
    case other

    var id: String { rawValue }

    /// Name sent as `activity` in metrics frames (docs/spec.md 6.3).
    var wireName: String { rawValue }

    var title: String {
        switch self {
        case .running: "跑步"
        case .walking: "步行"
        case .hiking: "徒步"
        case .cycling: "骑行"
        case .other: "其他"
        }
    }

    var symbol: String {
        switch self {
        case .running: "figure.run"
        case .walking: "figure.walk"
        case .hiking: "figure.hiking"
        case .cycling: "figure.outdoor.cycle"
        case .other: "figure.mixed.cardio"
        }
    }

    /// Concise display tagline shown on the iOS activity selector cards.
    var subtitle: String {
        switch self {
        case .running: "配速 · 跑姿 · 语音陪跑"
        case .walking: "轻松陪伴 · 每公里报时"
        case .hiking: "户外海拔 · 坡度陪伴"
        case .cycling: "时速播报 · 安全优先"
        case .other: "心率 · 时长 · 能量"
        }
    }

    /// Compact subtitle for Apple Watch workout cards.
    var watchSubtitle: String {
        switch self {
        case .running: "配速 · 跑姿"
        case .walking: "轻松陪伴"
        case .hiking: "海拔 · 徒步"
        case .cycling: "时速 · 骑行"
        case .other: "心率 · 能量"
        }
    }

    var speedTitle: String { readsSpeedAsPace ? "配速" : "速度" }
    var averageSpeedTitle: String { readsSpeedAsPace ? "平均配速" : "平均速度" }
    var speedUnit: String { readsSpeedAsPace ? "/km" : "km/h" }
    var cadenceTitle: String { readsSpeedAsPace ? "步频" : "踏频" }

    var healthKitType: HKWorkoutActivityType {
        switch self {
        case .running: .running
        case .walking: .walking
        case .hiking: .hiking
        case .cycling: .cycling
        case .other: .other
        }
    }

    /// Whether cadence should be derived from the step count (on foot) rather than a sensor.
    var derivesCadenceFromSteps: Bool {
        switch self {
        case .running, .walking, .hiking: true
        case .cycling, .other: false
        }
    }

    /// Whether speed reads as pace per km (on foot) or km/h (on wheels), as in the server profiles.
    var readsSpeedAsPace: Bool { self != .cycling }

    /// Cadence unit for display: steps on foot, crank revolutions on a bike.
    var cadenceUnit: String { readsSpeedAsPace ? "spm" : "rpm" }

    /// Whether the watch records a GPS route for this activity (docs/spec.md 6.3, 11).
    var usesGPS: Bool { self != .other }

    /// How the phone's offline announcements pace themselves (docs/spec.md 7.4). Mirrors the
    /// server profiles' split lengths; coaching itself stays on the server.
    var offlineCoach: LocalCoach.Config {
        switch self {
        case .running, .walking, .hiking: LocalCoach.Config(splitKm: 1)
        case .cycling: LocalCoach.Config(splitKm: 5)
        case .other: LocalCoach.Config(splitKm: nil, timeMarkS: 600)
        }
    }

    /// Activity of a record or frame; unknown names show as "other".
    init(wireName: String) {
        self = Self(rawValue: wireName) ?? .other
    }

    init(healthKitType: HKWorkoutActivityType) {
        self = Self.allCases.first { $0.healthKitType == healthKitType } ?? .other
    }

    func configuration() -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = healthKitType
        configuration.locationType = .outdoor
        return configuration
    }
}

enum HealthTypes {
    static let share: Set<HKSampleType> = [HKQuantityType.workoutType(), HKSeriesType.workoutRoute()]

    static let read: Set<HKObjectType> = [
        HKQuantityType(.heartRate),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.distanceCycling),
        HKQuantityType(.stepCount),
        HKQuantityType(.runningSpeed),
        HKQuantityType(.runningPower),
        HKQuantityType(.runningStrideLength),
        HKQuantityType(.runningGroundContactTime),
        HKQuantityType(.runningVerticalOscillation),
        HKQuantityType(.cyclingSpeed),
        HKQuantityType(.cyclingPower),
        HKQuantityType(.cyclingCadence),
        HKQuantityType.workoutType(),
        HKSeriesType.workoutRoute(),
    ]
}
