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

    var isActive: Bool { state != .notStarted && state != .ended }

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
    }

    private func receive(_ frames: [MetricsFrame]) {
        for frame in frames {
            stats.record(frame)
            if frame.seq > latest?.seq ?? 0 { latest = frame }
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
        Task { @MainActor in
            self.state = toState
            if toState == .ended { self.session = nil }
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
