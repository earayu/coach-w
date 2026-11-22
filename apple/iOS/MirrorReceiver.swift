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
        lastError = nil
        do {
            try await healthStore.startWatchApp(toHandle: activity.configuration())
        } catch {
            log.error("startWatchApp failed: \(error.localizedDescription)")
            lastError = "无法从手机启动手表：\(error.localizedDescription)\n请抬腕解锁手表，或直接在手表上打开 coach-w 开始，手机会自动接上。"
        }
    }

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
        log.info("pause requested, state \(self.state.rawValue, privacy: .public)")
        guard let session else { return lostWatch() }
        session.pause()
    }

    func resume() {
        log.info("resume requested, state \(self.state.rawValue, privacy: .public)")
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
        log.info("end requested, state \(self.state.rawValue, privacy: .public)")
        guard let session else {
            close(error: "手表已断开，已在手机上结束本次记录。手表上的运动请在手表上结束。")
            return
        }
        session.stopActivity(with: .now)
        Task { [weak self] in
            try? await Task.sleep(for: Self.endTimeout)
            guard let self, self.session === session, self.state != .ended else { return }
            log.error("watch did not confirm the end; closing the workout on the phone")
            self.close(error: "手表没有响应，已在手机上结束。手表上的运动请在手表上结束。")
        }
    }

    private func close(error: String?) {
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
        log.info(
            "mirrored session attached, state \(mirrored.state.rawValue, privacy: .public), continuing \(continuing, privacy: .public)"
        )
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
            log.info("frames resumed after \(Int(silence), privacy: .public)s of silence")
        }
        if latest == nil { log.info("first frame received") }
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
            log.info("watch reports the workout ended")
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
        log.info("mirrored state \(fromState.rawValue, privacy: .public) -> \(toState.rawValue, privacy: .public)")
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
        log.error("mirrored session failed: \(Self.describe(error), privacy: .public)")
        Task { @MainActor in self.lastError = message }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        log.error("mirrored session disconnected: \(error.map(Self.describe) ?? "no error", privacy: .public)")
        // This session will not answer pause or end any more. Keep the dashboard (the watch may
        // mirror again, which hands over a new session), but let "end" close it on the phone.
        let message = error?.localizedDescription ?? "unknown"
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.session = nil
            self.lastError = "与手表断开：\(message)"
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
