import CoachKit
import HealthKit
import Observation
import os

private let log = Logger(subsystem: "com.earayu.coachw.watch", category: "workout")

/// Owns the primary workout session on the watch and streams metrics frames to the iPhone.
@MainActor
@Observable
final class WorkoutController: NSObject {
    static let shared = WorkoutController()

    let healthStore = HKHealthStore()

    private(set) var state: HKWorkoutSessionState = .notStarted
    private(set) var activity: WorkoutActivity?
    private(set) var latest: MetricsFrame?
    private(set) var lastError: String?

    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var frames: FrameBuilder?
    /// Sends a frame every second while running, so elapsed time stays fresh and a missing
    /// stream means a broken link rather than "no new samples".
    @ObservationIgnored private var heartbeat: Task<Void, Never>?

    func requestAuthorization() async {
        do {
            try await healthStore.requestAuthorization(toShare: HealthTypes.share, read: HealthTypes.read)
        } catch {
            lastError = "健康权限请求失败：\(error.localizedDescription)"
        }
    }

    func start(_ activity: WorkoutActivity) async {
        await start(activity.configuration())
    }

    /// Starts a workout, either from the watch UI or from the iPhone via `startWatchApp(toHandle:)`.
    func start(_ configuration: HKWorkoutConfiguration) async {
        guard session == nil else {
            log.info("ignoring start: a workout is already running")
            return
        }
        let activity = WorkoutActivity(healthKitType: configuration.activityType)
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            session.delegate = self
            builder.delegate = self
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            self.session = session
            self.builder = builder
            self.activity = activity
            frames = FrameBuilder(activity: activity.wireName, minInterval: 0.9)
            lastError = nil

            try await session.startMirroringToCompanionDevice()
            let startDate = Date()
            session.startActivity(with: startDate)
            try await builder.beginCollection(at: startDate)
        } catch {
            log.error("failed to start workout: \(error.localizedDescription)")
            lastError = "开始运动失败：\(error.localizedDescription)"
            reset()
        }
    }

    func pause() { session?.pause() }
    func resume() { session?.resume() }
    func end() { session?.stopActivity(with: .now) }

    private func updateHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
        guard state == .running else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.ingest([], elapsed: self.builder?.elapsedTime ?? 0)
            }
        }
    }

    private func reset() {
        heartbeat?.cancel()
        heartbeat = nil
        session = nil
        builder = nil
        frames = nil
        activity = nil
        latest = nil
        state = .notStarted
    }

    private func ingest(_ readings: [MetricReading], elapsed: TimeInterval, force: Bool = false) {
        guard var frames else { return }
        let now = Date()
        for reading in readings { frames.apply(reading, at: now) }
        let frame = frames.frame(state: state.wireState, elapsed: elapsed, at: now, force: force)
        self.frames = frames
        guard let frame else { return }
        latest = frame
        send(frame)
    }

    private func send(_ frame: MetricsFrame) {
        guard let session, let data = try? frame.encoded() else { return }
        Task {
            do {
                try await session.sendToRemoteWorkoutSession(data: data)
            } catch {
                log.error("failed to send frame \(frame.seq): \(error.localizedDescription)")
            }
        }
    }

    private func handleStateChange(to newState: HKWorkoutSessionState, at date: Date) async {
        state = newState
        updateHeartbeat()
        ingest([], elapsed: builder?.elapsedTime(at: date) ?? 0, force: true)
        switch newState {
        case .stopped:
            guard let builder, let session else { return }
            do {
                try await builder.endCollection(at: date)
                _ = try await builder.finishWorkout()
                session.end()
            } catch {
                log.error("failed to finish workout: \(error.localizedDescription)")
                lastError = "保存运动失败：\(error.localizedDescription)"
            }
        case .ended:
            reset()
        default:
            break
        }
    }
}

extension WorkoutController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in await self.handleStateChange(to: toState, at: date) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        log.error("workout session failed: \(message)")
        Task { @MainActor in self.lastError = message }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        // Coach cues from the iPhone arrive here from M3 on.
    }
}

extension WorkoutController: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let derivesCadence = WorkoutActivity(
            healthKitType: workoutBuilder.workoutConfiguration.activityType
        ).derivesCadenceFromSteps
        let readings = collectedTypes
            .compactMap { $0 as? HKQuantityType }
            .compactMap { workoutBuilder.statistics(for: $0) }
            .compactMap { HealthReadings.reading(from: $0, derivesCadenceFromSteps: derivesCadence) }
        let elapsed = workoutBuilder.elapsedTime
        Task { @MainActor in self.ingest(readings, elapsed: elapsed) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
