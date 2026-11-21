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
            lastError = "无法启动手表 App：\(error.localizedDescription)"
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

    func pause() { session?.pause() }
    func resume() { session?.resume() }
    func end() { session?.stopActivity(with: .now) }

    private func attach(_ mirrored: HKWorkoutSession) {
        log.info("mirrored session attached")
        session = mirrored
        mirrored.delegate = self
        state = mirrored.state
        activity = WorkoutActivity(healthKitType: mirrored.workoutConfiguration.activityType)
        latest = nil
        stats = FrameStats()
        lastError = nil
        if let activity { onSessionStarted?(activity) }
    }

    private func receive(_ frames: [MetricsFrame]) {
        for frame in frames {
            stats.record(frame)
            if frame.seq > latest?.seq ?? 0 { latest = frame }
        }
        onFrames?(frames)
    }
}

extension MirrorReceiver: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            self.state = toState
            if toState == .ended {
                self.session = nil
                self.onSessionEnded?()
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        log.error("mirrored session failed: \(message)")
        Task { @MainActor in self.lastError = message }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        let message = error?.localizedDescription ?? "unknown"
        log.error("mirrored session disconnected: \(message)")
        Task { @MainActor in self.lastError = "与手表断开：\(message)" }
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
