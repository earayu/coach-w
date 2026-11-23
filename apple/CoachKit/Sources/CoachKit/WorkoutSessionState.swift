import Foundation

/// Platform-independent counterpart of HealthKit's `HKWorkoutSessionState`, so the watch and
/// phone workout state machines live in `CoachKit` and run under `swift test`.
public enum WorkoutSessionState: Equatable, Sendable {
    case notStarted
    case prepared
    case running
    case paused
    case stopped
    case ended

    public var isActive: Bool {
        switch self {
        case .prepared, .running, .paused, .stopped: true
        case .notStarted, .ended: false
        }
    }
}
