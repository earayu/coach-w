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

    private struct Recording {
        let id: UUID
        let startedAt: Date
        var lastCheckpoint: Date
        var tracker: WorkoutTracker
        var coach: LocalCoach
        var dropped: Int = 0
    }

    private enum Phase {
        case idle
        case recording(Recording)
        /// Finished workout; late coach closing lines keep landing in the saved record until `lateLinesUntil`.
        case finished(record: WorkoutRecord?, lateLinesUntil: Date?)
    }

    private(set) var lines: [CoachLine] = []

    /// Called with each offline cue the phone could speak; the app decides whether to.
    @ObservationIgnored var onLocalCue: (@MainActor (LocalCue) -> Void)?

    @ObservationIgnored private let store: WorkoutStore
    private var phase: Phase = .idle

    static let lateLinesWindow: TimeInterval = 90
    /// A run whose end never reaches the phone (COCH-15: the watch link dropped at the end of a
    /// one-hour run and the app was suspended) must not lose its record: save it as it goes.
    static let checkpointInterval: TimeInterval = 60

    init(store: WorkoutStore) {
        self.store = store
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// The record just saved, shown until the next workout starts.
    var lastRecord: WorkoutRecord? {
        if case .finished(let record, _) = phase { return record }
        return nil
    }

    /// A mirrored workout session started on the watch.
    func begin(_ activity: WorkoutActivity) {
        if case .recording = phase {
            // e.g. the link dropped before the old workout's end reached the phone: keep what it has
            diag("recorder", "new workout while one was still open; saving the open one first")
            finish()
        }
        diag("recorder", "begin \(activity.wireName)")
        let now = Date.now
        lines = []
        phase = .recording(
            Recording(
                id: UUID(),
                startedAt: now,
                lastCheckpoint: now,
                tracker: WorkoutTracker(),
                coach: LocalCoach(config: activity.offlineCoach)
            )
        )
    }

    func ingest(_ frames: [MetricsFrame]) {
        guard case .recording(var current) = phase else { return }
        for frame in frames.sorted(by: { ($0.ts, $0.seq) < ($1.ts, $1.seq) }) {
            guard current.tracker.ingest(frame) else {
                current.dropped += 1
                // first one and then one in 60: shows a stream the tracker keeps rejecting
                if current.dropped % 60 == 1 {
                    diag("recorder", "ignoring an older frame (\(current.dropped) so far)")
                }
                continue
            }
            let cues = current.coach.evaluate(frame, tracker: current.tracker)
            phase = .recording(current)
            for cue in cues { onLocalCue?(cue) }
            // a callback could theoretically have called begin/finish; re-read before continuing
            guard case .recording(let updated) = phase, updated.id == current.id else { return }
            current = updated
            if frame.state == .ended {
                finish()
                return
            }
        }
        checkpoint(&current)
        phase = .recording(current)
    }

    /// Saves the open workout so far, at most once per `checkpointInterval`.
    private func checkpoint(_ current: inout Recording) {
        let now = Date.now
        guard now.timeIntervalSince(current.lastCheckpoint) >= Self.checkpointInterval,
              let record = current.tracker.record(id: current.id, startedAt: current.startedAt, endedAt: now, lines: lines)
        else { return }
        current.lastCheckpoint = now
        store.save(record)
    }

    func addLine(_ text: String, source: CoachLine.Source) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let line = CoachLine(at: .now, text: text, source: source)
        switch phase {
        case .idle:
            break
        case .recording:
            lines.append(line)
        case .finished(var record?, let until?) where line.at < until:
            lines.append(line)
            record.lines.append(line)
            store.save(record)
            phase = .finished(record: record, lateLinesUntil: until)
        case .finished:
            break
        }
    }

    /// What a new coach session continues from (`coach.resume`); nil without a workout.
    func resume() -> CoachResume? {
        guard case .recording(let current) = phase else { return nil }
        return current.tracker.resume(at: .now)
    }

    /// The workout ended (final frame or the mirrored session ended). Saves once.
    func finish() {
        guard case .recording(let current) = phase else { return }
        guard let record = current.tracker.record(id: current.id, startedAt: current.startedAt, endedAt: .now, lines: lines) else {
            diag("recorder", "finish: nothing to save (running samples \(current.tracker.samples), lines \(lines.count))")
            phase = .finished(record: nil, lateLinesUntil: nil)
            return
        }
        diag("recorder", "finish: saved record, \(Int(record.durationS))s, \(record.lines.count) lines")
        store.save(record)
        phase = .finished(record: record, lateLinesUntil: .now + Self.lateLinesWindow)
    }
}
