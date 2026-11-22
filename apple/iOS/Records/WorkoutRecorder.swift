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
    @ObservationIgnored private var dropped = 0
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
        if !finished {
            // e.g. the link dropped before the old workout's end reached the phone: keep what it has
            diag("recorder", "new workout while one was still open; saving the open one first")
            finish()
        }
        diag("recorder", "begin \(activity.wireName)")
        tracker = WorkoutTracker()
        coach = LocalCoach(config: activity.offlineCoach)
        lines = []
        lastRecord = nil
        lateLinesUntil = nil
        dropped = 0
        startedAt = .now
        finished = false
    }

    func ingest(_ frames: [MetricsFrame]) {
        guard !finished else { return }
        for frame in frames.sorted(by: { ($0.ts, $0.seq) < ($1.ts, $1.seq) }) {
            guard tracker.ingest(frame) else {
                dropped += 1
                // first one and then one in 60: shows a stream the tracker keeps rejecting
                if dropped % 60 == 1 { diag("recorder", "ignoring an older frame (\(dropped) so far)") }
                continue
            }
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
            diag("recorder", "finish: nothing to save (running samples \(tracker.samples), lines \(lines.count))")
            return
        }
        diag("recorder", "finish: saved record, \(Int(record.durationS))s, \(record.lines.count) lines")
        store.save(record)
        lastRecord = record
        lateLinesUntil = .now + Self.lateLinesWindow
    }
}
