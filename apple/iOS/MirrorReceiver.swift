import CoachKit
import HealthKit
import Observation
import os

private let log = Logger(subsystem: "com.earayu.coachw", category: "mirror")

/// Receives the workout session mirrored from the watch and the metrics frames it sends.
@MainActor
@Observable
final class MirrorReceiver: NSObject {
    static let shared = MirrorReceiver()

    let healthStore = HKHealthStore()

    private(set) var state: HKWorkoutSessionState = .notStarted
    private(set) var activity: WorkoutActivity?
    private(set) var latest: MetricsFrame?
    private(set) var stats = FrameStats()
    private(set) var lastError: String?
    /// Between "start on watch" and the watch's session arriving here; drives the button state.
    private(set) var isStartingWatch = false
    /// The watch took the start request but its data has not arrived yet. Mirroring took about a
    /// minute on device (COCH-15) while the watch was already running: show the workout meanwhile.
    private(set) var awaitingActivity: WorkoutActivity?
    /// The watch has not taken the start request after `slowStartAfter`. `startWatchApp` only
    /// returns once the request reached the watch: 59 s on device with the watch asleep (COCH-17).
    private(set) var isWatchSlowToStart = false
    @ObservationIgnored private var startAttempt = 0

    @ObservationIgnored private var session: HKWorkoutSession?
    /// Start of the workout being shown: a re-attached session with the same start continues it.
    @ObservationIgnored private var sessionStart: Date?
    /// Called with every batch of received frames, e.g. to forward them to the coach.
    @ObservationIgnored var onFrames: (@MainActor ([MetricsFrame]) -> Void)?
    /// Called when a workout session from the watch attaches, and when it ends.
    @ObservationIgnored var onSessionStarted: (@MainActor (WorkoutActivity) -> Void)?
    @ObservationIgnored var onSessionEnded: (@MainActor () -> Void)?

    var isActive: Bool { state != .notStarted && state != .ended }
    var isRunning: Bool { state == .running }
    var isPaused: Bool { state == .paused }

    /// Must run at launch: HealthKit may launch the app in the background to hand over a session.
    func install() {
        healthStore.workoutSessionMirroringStartHandler = { [weak self] mirrored in
            Task { @MainActor in self?.attach(mirrored) }
        }
    }

    func requestAuthorization() async {
        do {
            try await healthStore.requestAuthorization(toShare: HealthTypes.share, read: HealthTypes.read)
        } catch {
            lastError = "健康权限请求失败：\(error.localizedDescription)"
        }
    }

    /// Launches the watch app and asks it to start the workout; the session then mirrors back here.
    func startOnWatch(_ activity: WorkoutActivity) async {
        diag("phone", "start on watch requested: \(activity.wireName), state \(state.label), session \(session != nil)")
        guard !isStartingWatch else {
            diag("phone", "ignoring start: already waiting for the watch")
            return
        }
        lastError = nil
        isStartingWatch = true
        isWatchSlowToStart = false
        startAttempt += 1
        let attempt = startAttempt
        let began = Date()
        // Both timers run from the tap: `startWatchApp` itself can hang for as long as the watch
        // is unreachable, and the button must not look dead meanwhile (COCH-13, COCH-17).
        Task { [weak self] in
            try? await Task.sleep(for: Self.slowStartAfter)
            guard let self, attempt == self.startAttempt, self.isStartingWatch, self.awaitingActivity == nil else { return }
            diag("phone", "watch has not taken the start \(Self.slowStartAfter) after the tap")
            self.isWatchSlowToStart = true
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.attachTimeout)
            guard let self, attempt == self.startAttempt, self.isStartingWatch else { return }
            diag("phone", "no mirrored session \(Self.attachTimeout) after the tap")
            self.stopWaiting()
            self.lastError = "手表没有开始运动。请抬腕看看手表上的 coach-w：如果还停在上一场运动，先在手表上结束它；也可以直接在手表上开始。"
        }
        do {
            try await healthStore.startWatchApp(toHandle: activity.configuration())
            diag("phone", "startWatchApp returned after \(Self.ms(since: began)) ms; waiting for the watch to mirror")
            if attempt == startAttempt, isStartingWatch {
                isWatchSlowToStart = false
                awaitingActivity = activity
            }
        } catch {
            diag("phone", "startWatchApp failed after \(Self.ms(since: began)) ms: \(Self.describe(error))")
            log.error("startWatchApp failed: \(error.localizedDescription)")
            guard attempt == startAttempt, isStartingWatch else { return }
            stopWaiting()
            lastError = "无法从手机启动手表：\(error.localizedDescription)\n请抬腕解锁手表，或直接在手表上打开 coach-w 开始，手机会自动接上。"
        }
    }

    /// Stops waiting for a start the watch has not taken yet. The request may still reach the
    /// watch later; a workout it starts then still mirrors here and shows up.
    func cancelStart() {
        guard isStartingWatch, awaitingActivity == nil else { return }
        diag("phone", "start on watch cancelled while waiting for the watch")
        startAttempt += 1
        stopWaiting()
    }

    private func stopWaiting() {
        isStartingWatch = false
        isWatchSlowToStart = false
        awaitingActivity = nil
    }

    /// When the phone starts telling the athlete to wake the watch or start on it instead.
    static let slowStartAfter: Duration = .seconds(4)
    /// How long the phone waits for the watch's session after asking it to start.
    static let attachTimeout: Duration = .seconds(120)

    static func ms(since date: Date) -> Int { Int((Date().timeIntervalSince(date) * 1000).rounded()) }

    /// Forwards a coach cue to the watch over the mirrored session; expired cues are dropped.
    func sendToWatch(_ cue: CoachCue) {
        guard let session else { return }
        guard !cue.isExpired(at: .now), let data = try? cue.encoded() else {
            log.info("not forwarding cue \(cue.id, privacy: .public): expired or unencodable")
            return
        }
        Task {
            do {
                try await session.sendToRemoteWorkoutSession(data: data)
            } catch {
                log.error("forwarding cue to watch failed: \(error.localizedDescription)")
            }
        }
    }

    /// How long the watch gets to confirm an end before the phone closes the workout on its own.
    static let endTimeout: Duration = .seconds(5)

    func pause() {
        diag("phone", "pause requested, state \(state.label), session \(session != nil)")
        guard let session else { return lostWatch() }
        session.pause()
    }

    func resume() {
        diag("phone", "resume requested, state \(state.label), session \(session != nil)")
        guard let session else { return lostWatch() }
        session.resume()
    }

    private func lostWatch() {
        lastError = "手表已断开，暂停和继续请在手表上操作；点「结束」可在手机上结束本次记录。"
    }

    /// Asks the watch to end the workout. A watch that has gone away never answers, which left the
    /// phone stuck on the dashboard (COCH-12): then the phone closes the workout itself. The watch
    /// still owns and saves the HealthKit workout.
    func end() {
        diag("phone", "end requested, state \(state.label), session \(session.map { $0.state.label } ?? "none")")
        guard let session else {
            close(error: awaitingActivity != nil
                ? "手机不再等手表的数据。手表上已经开始的运动请在手表上结束。"
                : "手表已断开，已在手机上结束本次记录。手表上的运动请在手表上结束。")
            return
        }
        session.stopActivity(with: .now)
        Task { [weak self] in
            try? await Task.sleep(for: Self.endTimeout)
            guard let self, self.session === session, self.state != .ended else { return }
            diag("phone", "watch did not confirm the end within \(Self.endTimeout) (state \(self.state.label)); closing on the phone")
            self.close(error: "手表没有响应，已在手机上结束。手表上的运动请在手表上结束。")
        }
    }

    private func close(error: String?) {
        diag("phone", "workout closed on the phone\(error == nil ? "" : " with a message")")
        stopWaiting()
        session?.delegate = nil
        session = nil
        state = .ended
        lastError = error
        onSessionEnded?()
    }

    private func attach(_ mirrored: HKWorkoutSession) {
        // HealthKit hands over a new session for the same workout after the watch link drops and
        // comes back (measured on device 2026-11-22: ~15 s later). That is not a new workout: keep
        // its record and numbers going.
        let continuing = isActive && sessionStart != nil && mirrored.startDate == sessionStart
        diag("phone", "mirrored session attached, state \(mirrored.state.label), continuing \(continuing)")
        stopWaiting()
        session = mirrored
        mirrored.delegate = self
        state = mirrored.state
        lastError = nil
        guard !continuing else { return }
        sessionStart = mirrored.startDate
        activity = WorkoutActivity(healthKitType: mirrored.workoutConfiguration.activityType)
        latest = nil
        stats = FrameStats()
        if let activity { onSessionStarted?(activity) }
    }

    private func receive(_ frames: [MetricsFrame]) {
        if let latest, latest.isStale(at: .now), let silence = latest.silence(at: .now) {
            diag("phone", "frames resumed after \(Int(silence))s of silence")
        }
        if latest == nil { diag("phone", "first frame received") }
        for frame in frames {
            stats.record(frame)
            if frame.isNewer(than: latest) { latest = frame }
        }
        onFrames?(frames)
        if let latest { follow(latest.state) }
    }

    /// The watch's own state, from its newest frame. The mirrored session's state callbacks do not
    /// always arrive (on device, a pause from the phone paused the watch but the phone never heard
    /// of it), which left the pause button and "end" looking dead (COCH-12).
    private func follow(_ watchState: WorkoutState) {
        switch watchState {
        case .running where state == .paused: state = .running
        case .paused where state == .running: state = .paused
        case .ended where isActive:
            diag("phone", "watch reports the workout ended")
            close(error: nil)
        default: break
        }
    }
}

extension MirrorReceiver: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        diag("phone", "mirrored state \(fromState.label) -> \(toState.label)")
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.state = toState
            if toState == .ended {
                self.session = nil
                self.onSessionEnded?()
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        diag("phone", "mirrored session failed: \(Self.describe(error))")
        Task { @MainActor in
            // a session this receiver already replaced must not put its error on the new workout
            guard self.session === workoutSession else { return }
            self.lastError = message
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        diag("phone", "mirrored session disconnected: \(error.map(Self.describe) ?? "no error")")
        // This session will not answer pause or end any more. Keep the dashboard (the watch may
        // mirror again, which hands over a new session), but let "end" close it on the phone.
        let message = error?.localizedDescription ?? "unknown"
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.session = nil
            self.lastError = "与手表断开：\(message)"
            self.closeIfNotReattached()
        }
    }

    /// How long a disconnected workout waits for the watch to mirror again before the phone closes
    /// it. HealthKit re-mirrors in about 15 s; a link that stays down past this means the workout
    /// ended on the watch without the phone hearing of it (COCH-15).
    static let reattachTimeout: Duration = .seconds(120)

    private func closeIfNotReattached() {
        let start = sessionStart
        Task { [weak self] in
            try? await Task.sleep(for: Self.reattachTimeout)
            guard let self, self.session == nil, self.isActive, self.sessionStart == start else { return }
            diag("phone", "watch did not mirror again within \(Self.reattachTimeout); closing on the phone")
            self.close(error: "与手表断开太久，已在手机上保存本次记录。手表上的运动请在手表上确认已结束。")
        }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
    }

    /// While the app is suspended HealthKit buffers frames and delivers them together on resume.
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        let receivedAt = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let frames = data.compactMap { raw -> MetricsFrame? in
            guard var frame = try? MetricsFrame.decode(raw) else {
                log.error("dropping undecodable frame (\(raw.count) bytes)")
                return nil
            }
            frame.phoneTs = receivedAt
            return frame
        }
        Task { @MainActor in self.receive(frames) }
    }
}

extension HKWorkoutSessionState {
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
