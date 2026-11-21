import CoachKit
import Foundation
import Observation

/// Follows the current workout on the phone: the summary a new coach session resumes from, the
/// offline announcements, and the record saved when it ends (docs/spec.md 7.4, 2 step 6).
///
/// Fed by `MirrorReceiver`; knows nothing about HealthKit or LiveKit.
@MainActor
@Observable
final class WorkoutRecorder {
    static let shared = WorkoutRecorder(store: .shared)

    private(set) var lines: [CoachLine] = []
    /// The record just saved, shown until the next workout starts.
    private(set) var lastRecord: WorkoutRecord?

    /// Called with each offline cue the phone could speak; the app decides whether to.
    @ObservationIgnored var onLocalCue: (@MainActor (LocalCue) -> Void)?

    @ObservationIgnored private let store: WorkoutStore
    @ObservationIgnored private var tracker = WorkoutTracker()
    @ObservationIgnored private var coach = LocalCoach()
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var finished = true
    /// The coach's closing summary comes after the final frame: lines keep landing in the saved
    /// record until then.
    @ObservationIgnored private var lateLinesUntil: Date?

    static let lateLinesWindow: TimeInterval = 90

    init(store: WorkoutStore) {
        self.store = store
    }

    var isRecording: Bool { !finished }

    /// A mirrored workout session started on the watch.
    func begin(_ activity: WorkoutActivity) {
        tracker = WorkoutTracker()
        coach = LocalCoach(config: activity.offlineCoach)
        lines = []
        lastRecord = nil
        lateLinesUntil = nil
        startedAt = .now
        finished = false
    }

    func ingest(_ frames: [MetricsFrame]) {
        guard !finished else { return }
        for frame in frames.sorted(by: { $0.seq < $1.seq }) where tracker.ingest(frame) {
            for cue in coach.evaluate(frame, tracker: tracker) { onLocalCue?(cue) }
            if frame.state == .ended { finish() }
        }
    }

    func addLine(_ text: String, source: CoachLine.Source) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let line = CoachLine(at: .now, text: text, source: source)
        if !finished {
            lines.append(line)
        } else if var record = lastRecord, let until = lateLinesUntil, line.at < until {
            lines.append(line)
            record.lines.append(line)
            store.save(record)
            lastRecord = record
        }
    }

    /// What a new coach session continues from (`coach.resume`); nil without a workout.
    func resume() -> CoachResume? {
        finished ? nil : tracker.resume(at: .now)
    }

    /// The workout ended (final frame or the mirrored session ended). Saves once.
    func finish() {
        guard !finished else { return }
        finished = true
        guard let startedAt, let record = tracker.record(startedAt: startedAt, endedAt: .now, lines: lines) else {
            return
        }
        store.save(record)
        lastRecord = record
        lateLinesUntil = .now + Self.lateLinesWindow
    }
}
