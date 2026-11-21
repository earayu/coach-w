@testable import CoachKit

/// A synthetic workout, one frame per second. All data here is made up.
struct SynthWorkout {
    var activity = "running"
    var seq = 0
    var elapsed = 0.0
    var distance = 0.0
    var energy = 0.0
    var tracker = WorkoutTracker()
    var coach: LocalCoach
    var cues: [LocalCue] = []

    init(activity: String = "running", config: LocalCoach.Config = .init()) {
        self.activity = activity
        coach = LocalCoach(config: config)
    }

    mutating func run(
        _ seconds: Int, speed: Double? = 3, hr: Double? = 150, kcalPerS: Double = 0.2,
        state: WorkoutState = .running, lat: Double? = nil
    ) {
        for _ in 0..<seconds {
            if state == .running {
                elapsed += 1
                distance += speed ?? 0
                energy += kcalPerS
            }
            seq += 1
            let frame = MetricsFrame(
                seq: seq, ts: 1_763_726_400_000 + Int64(elapsed * 1000), activity: activity, state: state,
                elapsedS: elapsed, hrBpm: hr, distanceM: speed == nil ? nil : distance, speedMps: speed,
                energyKcal: energy, lat: lat, lon: lat
            )
            guard tracker.ingest(frame) else { continue }
            cues += coach.evaluate(frame, tracker: tracker)
        }
    }

    var kinds: [String] { cues.compactMap(\.cue.kind) }
}
