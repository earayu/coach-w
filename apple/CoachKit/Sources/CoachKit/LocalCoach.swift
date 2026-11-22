import Foundation

/// A line the phone says on its own while the voice coach is unreachable, and the cue the watch
/// buzzes for it (docs/spec.md 7.4).
public struct LocalCue: Equatable, Sendable {
    /// Spoken by `AVSpeechSynthesizer`; may contain numbers, all from the watch.
    public let speech: String
    public let cue: CoachCue
}

/// Spoken Chinese for local announcements, matching the server's wording.
public enum Spoken {
    /// "1 小时 5 分 3 秒", "12 分 30 秒", "45 秒".
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) 小时") }
        if m > 0 || h > 0 { parts.append("\(m) 分") }
        if s > 0 || parts.isEmpty { parts.append("\(s) 秒") }
        return parts.joined(separator: " ")
    }

    public static func distance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f 公里", meters / 1000) : String(format: "%.0f 米", meters)
    }
}

/// The phone's lightweight rule engine for when the voice coach is offline (docs/spec.md 7.4).
///
/// Only emergency and milestone cues: heart rate held above the safety limit, kilometre splits,
/// time marks, and the end. It runs on every frame, online or not, so that going offline never
/// replays old milestones; the app decides whether to speak. Pure logic, no platform types.
public struct LocalCoach: Sendable {
    public struct Config: Equatable, Sendable {
        /// Heart rate above this for `hrSustainS` is an emergency.
        public var hrEmergencyBpm: Double
        public var hrSustainS: Double
        public var hrCooldownS: Double
        /// Announce every this many kilometres; nil for activities without distance.
        public var splitKm: Int?
        /// Announce every this much running time; nil for none.
        public var timeMarkS: Double?
        /// A cue not spoken within this long is dropped.
        public var ttlS: Double

        public init(
            hrEmergencyBpm: Double = 184,
            hrSustainS: Double = 15,
            hrCooldownS: Double = 90,
            splitKm: Int? = 1,
            timeMarkS: Double? = nil,
            ttlS: Double = 20
        ) {
            self.hrEmergencyBpm = hrEmergencyBpm
            self.hrSustainS = hrSustainS
            self.hrCooldownS = hrCooldownS
            self.splitKm = splitKm
            self.timeMarkS = timeMarkS
            self.ttlS = ttlS
        }
    }

    public let config: Config
    private var hrAboveSince: Double?
    private var lastHrAlert: Double?
    private var splitsAnnounced = 0
    private var marksAnnounced = 0
    private var endAnnounced = false
    private var primed = false
    private var firstTimedSplit = 1
    private var nextID = 1

    /// A coach whose first frame is later than this joined a workout under way (the app was
    /// relaunched mid-workout): what already passed is not announced.
    static let joinedLateAfterS: Double = 60

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Call after `tracker.ingest(frame)` accepted the frame.
    public mutating func evaluate(_ frame: MetricsFrame, tracker: WorkoutTracker) -> [LocalCue] {
        if !primed {
            primed = true
            if frame.elapsedS > Self.joinedLateAfterS {
                // the tracker interpolated the early kilometres from the start: not real splits
                if let every = config.splitKm, every > 0 {
                    splitsAnnounced = tracker.kmMarks.count / every
                    // the split under way started before this coach saw the workout: not timed
                    firstTimedSplit = splitsAnnounced + 2
                }
                if let mark = config.timeMarkS, mark > 0 { marksAnnounced = Int(frame.elapsedS / mark) }
            }
        }
        if frame.state == .ended {
            guard !endAnnounced, tracker.samples > 0 else { return [] }
            endAnnounced = true
            var parts = ["用时 \(Spoken.duration(tracker.elapsedS))"]
            if let meters = tracker.distanceM, meters > 0 { parts.append("距离 \(Spoken.distance(meters))") }
            return [make(frame, .milestone, "end", .stop, "运动结束", "运动结束了，\(parts.joined(separator: "，"))。辛苦了！")]
        }
        guard frame.state == .running else {
            hrAboveSince = nil
            return []
        }
        return [heartRate(frame), split(frame, tracker), timeMark(frame)].compactMap { $0 }
    }

    private mutating func heartRate(_ frame: MetricsFrame) -> LocalCue? {
        // a missing reading breaks the streak: no data is never evidence
        guard let hr = frame.hrBpm, hr > config.hrEmergencyBpm else {
            hrAboveSince = nil
            return nil
        }
        let since = hrAboveSince ?? frame.elapsedS
        hrAboveSince = since
        guard frame.elapsedS - since >= config.hrSustainS else { return nil }
        if let last = lastHrAlert, frame.elapsedS - last < config.hrCooldownS { return nil }
        lastHrAlert = frame.elapsedS
        return make(
            frame, .emergency, "hr_emergency", .failure, "心率过高",
            "心率 \(Int(hr.rounded()))，太高了，马上放慢，必要时停下来走一走。"
        )
    }

    private mutating func split(_ frame: MetricsFrame, _ tracker: WorkoutTracker) -> LocalCue? {
        guard let every = config.splitKm, every > 0 else { return nil }
        let count = tracker.kmMarks.count / every
        guard count > splitsAnnounced else { return nil }
        splitsAnnounced = count
        let km = count * every
        let end = tracker.kmMarks[km - 1]
        let start = km > every ? tracker.kmMarks[km - every - 1] : 0
        let span = every == 1 ? "这一公里" : "这 \(every) 公里"
        let speech = count < firstTimedSplit
            ? "第 \(km) 公里，继续保持。"
            : "第 \(km) 公里，\(span)用时 \(Spoken.duration(end - start))。"
        return make(frame, .milestone, "split:\(count)", .success, "第 \(km) 公里", speech)
    }

    private mutating func timeMark(_ frame: MetricsFrame) -> LocalCue? {
        guard let mark = config.timeMarkS, mark > 0 else { return nil }
        let count = Int(frame.elapsedS / mark)
        guard count > marksAnnounced else { return nil }
        marksAnnounced = count
        let minutes = Int((Double(count) * mark / 60).rounded())
        return make(frame, .milestone, "time:\(count)", .success, "\(minutes) 分钟", "已经运动 \(minutes) 分钟了，继续加油。")
    }

    private mutating func make(
        _ frame: MetricsFrame, _ priority: CuePriority, _ kind: String, _ haptic: CueHaptic, _ text: String,
        _ speech: String
    ) -> LocalCue {
        defer { nextID += 1 }
        let cue = CoachCue(
            id: String(format: "local-%06d", nextID),
            ts: frame.ts,
            expiresAt: frame.ts + Int64(config.ttlS * 1000),
            priority: priority,
            kind: kind,
            haptic: haptic,
            text: text
        )
        return LocalCue(speech: speech, cue: cue)
    }
}
