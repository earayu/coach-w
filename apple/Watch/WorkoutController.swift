import CoachKit
import CoreLocation
import HealthKit
import Observation
import WatchKit
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
    /// The coach cue on screen, if any (spec 4.1: key cues also buzz the watch).
    private(set) var cue: CoachCue?

    var isRunning: Bool { state == .running }
    var isPaused: Bool { state == .paused }

    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var frames: FrameBuilder?
    /// Sends a frame every second while running, so elapsed time stays fresh and a missing
    /// stream means a broken link rather than "no new samples".
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var cueDismissal: Task<Void, Never>?
    /// GPS for outdoor activities: the route goes to HealthKit with the workout, the latest fix
    /// into the frames (docs/spec.md 6.3, 11).
    @ObservationIgnored private let locationFeed = LocationFeed()
    @ObservationIgnored private var routeBuilder: HKWorkoutRouteBuilder?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var stoppedAt: Date?
    @ObservationIgnored private var sendFailures = 0

    /// A cue stays on screen at most this long, and never past its expiry.
    static let cueDisplaySeconds: TimeInterval = 4

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
        let wanted = WorkoutActivity(healthKitType: configuration.activityType).wireName
        diag("watch", "start \(wanted) requested, state \(state.label), session \(session.map { $0.state.label } ?? "none")")
        guard !starting else {
            diag("watch", "ignoring start: another start is in progress")
            return
        }
        if let session {
            // A session that already stopped or ended but never reached `reset()` (a finish that
            // failed or hung) used to swallow every later start silently (COCH-13).
            guard !session.state.isActive || session.state == .stopped else {
                diag("watch", "ignoring start: a \(activity?.wireName ?? "?") workout is \(session.state.label)")
                lastError = "已有一场运动在进行，请先结束它。"
                return
            }
            if session.state == .stopped, let stoppedAt, Date().timeIntervalSince(stoppedAt) < Self.finishTimeout.seconds {
                diag("watch", "ignoring start: the last workout is still saving")
                lastError = "上一场运动正在保存，请稍候再开始。"
                return
            }
            diag("watch", "discarding a leftover \(session.state.label) session before starting")
            session.end()
            reset()
        }
        starting = true
        defer { starting = false }
        let began = Date()
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = adopt(session)
            let startDate = Date()
            session.startActivity(with: startDate)
            try await builder.beginCollection(at: startDate)
            diag("watch", "workout \(wanted) started in \(Self.ms(since: began)) ms")
            if activity?.usesGPS == true { startRoute(builder) }
            // Mirroring waits on the iPhone; it used to run before `startActivity` and block the
            // start when the phone was slow or away. The workout must not depend on it (AGENTS.md 1).
            startMirroring(session)
        } catch {
            diag("watch", "start \(wanted) failed after \(Self.ms(since: began)) ms: \(error.localizedDescription)")
            log.error("failed to start workout: \(error.localizedDescription)")
            lastError = "开始运动失败：\(error.localizedDescription)"
            // a half-started session would keep running (and mirroring) with nobody feeding it
            session?.end()
            reset()
        }
    }

    private func startMirroring(_ session: HKWorkoutSession) {
        Task { [weak self] in
            let began = Date()
            do {
                try await session.startMirroringToCompanionDevice()
                diag("watch", "mirroring to iPhone started in \(Self.ms(since: began)) ms")
            } catch {
                diag("watch", "mirroring to iPhone failed after \(Self.ms(since: began)) ms: \(error.localizedDescription)")
                guard let self, self.session === session else { return }
                self.lastError = "未连上 iPhone：\(error.localizedDescription)。运动照常记录。"
            }
        }
    }

    /// Picks up the workout that was running when the app quit or crashed. watchOS relaunches the
    /// app for it; without this the session keeps running but no frame reaches the iPhone again.
    func recover() async {
        guard session == nil else { return }
        do {
            guard let session = try await healthStore.recoverActiveWorkoutSession() else {
                diag("watch", "recovery: no active workout")
                return
            }
            diag("watch", "recovered active workout, state \(session.state.label)")
            log.info("recovered active workout session")
            let builder = adopt(session)
            state = session.state
            if session.state == .stopped {
                // the app quit while saving: no state change will come to finish it, and the
                // workout would never reach HealthKit (AGENTS.md 1)
                diag("watch", "recovered a stopped workout; saving it now")
                await finish(at: session.endDate ?? .now)
                return
            }
            updateHeartbeat()
            if activity?.usesGPS == true { startRoute(builder) }
            do {
                try await session.startMirroringToCompanionDevice()
            } catch {
                // still mirroring from before the relaunch
                log.info("mirroring after recovery: \(error.localizedDescription, privacy: .public)")
            }
            ingest([], elapsed: builder.elapsedTime, force: true)
        } catch {
            diag("watch", "workout recovery failed: \(error.localizedDescription)")
            log.error("workout recovery failed: \(error.localizedDescription, privacy: .public)")
            lastError = "恢复运动失败：\(error.localizedDescription)"
        }
    }

    private func adopt(_ session: HKWorkoutSession) -> HKLiveWorkoutBuilder {
        let configuration = session.workoutConfiguration
        let activity = WorkoutActivity(healthKitType: configuration.activityType)
        let builder = session.associatedWorkoutBuilder()
        session.delegate = self
        builder.delegate = self
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        self.session = session
        self.builder = builder
        self.activity = activity
        frames = FrameBuilder(activity: activity.wireName, minInterval: 0.9)
        lastError = nil
        return builder
    }

    private func startRoute(_ builder: HKLiveWorkoutBuilder) {
        // associated with the workout builder: finished and saved together with the workout
        routeBuilder = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder
        locationFeed.start { [weak self] locations in self?.receive(locations) }
    }

    private func receive(_ locations: [CLLocation]) {
        guard state.isActive, let last = locations.last else { return }
        if let routeBuilder {
            Task {
                do {
                    try await routeBuilder.insertRouteData(locations)
                } catch {
                    log.error("route insert failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        let altitude = last.verticalAccuracy >= 0 ? last.altitude : nil
        let reading = MetricReading.location(
            latitude: last.coordinate.latitude, longitude: last.coordinate.longitude, altitudeMeters: altitude
        )
        ingest([reading], elapsed: builder?.elapsedTime ?? 0)
    }

    func pause() {
        diag("watch", "pause tapped, state \(state.label), session \(session != nil)")
        session?.pause()
    }

    func resume() {
        diag("watch", "resume tapped, state \(state.label), session \(session != nil)")
        session?.resume()
    }

    /// How long saving may take after a stop before the watch gives up waiting and ends the session.
    static let finishTimeout: Duration = .seconds(15)

    func end() {
        diag("watch", "end tapped, state \(state.label), session \(session.map { $0.state.label } ?? "none")")
        guard let session else {
            // the UI is showing a workout the controller no longer has
            reset()
            return
        }
        if session.state == .stopped {
            // already stopped and still saving: a second tap must not be a no-op (COCH-13)
            diag("watch", "end tapped while saving: ending the session now")
            session.end()
            return
        }
        session.stopActivity(with: .now)
        Task { [weak self] in
            try? await Task.sleep(for: Self.finishTimeout)
            guard let self, self.session === session, session.state != .ended else { return }
            diag("watch", "workout did not end \(Self.finishTimeout) after stop (state \(session.state.label)); ending it")
            session.end()
            try? await Task.sleep(for: .seconds(2))
            if self.session === session { self.reset() }
        }
    }

    var isFinishing: Bool { state == .stopped }

    /// Buzzes and shows a cue from the coach. Expired cues are dropped: a late buzz misleads.
    func present(_ cue: CoachCue) {
        let now = Date()
        guard state.isActive, !cue.isExpired(at: now) else {
            log.info("dropping cue \(cue.id, privacy: .public): expired or no workout")
            return
        }
        if let haptic = cue.haptic { WKInterfaceDevice.current().play(haptic.watchKit) }
        self.cue = cue
        cueDismissal?.cancel()
        let shown = min(Self.cueDisplaySeconds, cue.remaining(at: now))
        cueDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(shown))
            guard !Task.isCancelled, self?.cue?.id == cue.id else { return }
            self?.cue = nil
        }
    }

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
        locationFeed.stop()
        routeBuilder = nil
        heartbeat?.cancel()
        heartbeat = nil
        session = nil
        builder = nil
        frames = nil
        activity = nil
        latest = nil
        cueDismissal?.cancel()
        cue = nil
        sendFailures = 0
        stoppedAt = nil
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
                await MainActor.run {
                    self.sendFailures += 1
                    // first failure and then one in 30: enough to see a dead link, not a flood
                    if self.sendFailures % 30 == 1 {
                        diag("watch", "sending frame \(frame.seq) failed (\(self.sendFailures) so far): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func handleStateChange(to newState: HKWorkoutSessionState, at date: Date) async {
        diag("watch", "session \(state.label) -> \(newState.label)")
        state = newState
        updateHeartbeat()
        ingest([], elapsed: builder?.elapsedTime(at: date) ?? 0, force: true)
        switch newState {
        case .stopped:
            await finish(at: date)
        case .ended:
            reset()
        default:
            break
        }
    }

    /// Saves the stopped workout to HealthKit, then ends the session.
    private func finish(at date: Date) async {
        stoppedAt = .now
        locationFeed.stop()
        guard let builder, let session else {
            diag("watch", "stopped without a builder or session")
            return
        }
        let began = Date()
        do {
            try await builder.endCollection(at: date)
            _ = try await builder.finishWorkout()
            diag("watch", "workout saved in \(Self.ms(since: began)) ms")
        } catch {
            diag("watch", "saving workout failed after \(Self.ms(since: began)) ms: \(error.localizedDescription)")
            log.error("failed to finish workout: \(error.localizedDescription)")
            lastError = "保存运动失败：\(error.localizedDescription)"
        }
        // Always end: a session left in `stopped` kept the dial up with a dead "end" button and
        // made every later start a silent no-op (COCH-13).
        session.end()
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
        diag("watch", "workout session failed: \(message)")
        log.error("workout session failed: \(message)")
        Task { @MainActor in self.lastError = message }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        // The iPhone sends only coach cues on this channel (spec 6.3).
        let cues = data.compactMap { try? CoachCue.decode($0) }
        if cues.count < data.count { log.error("dropping \(data.count - cues.count) undecodable cue(s)") }
        Task { @MainActor in cues.forEach(self.present) }
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

extension WorkoutController {
    static func ms(since date: Date) -> Int { Int((Date().timeIntervalSince(date) * 1000).rounded()) }
}

extension Duration {
    var seconds: TimeInterval { TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18 }
}

extension CueHaptic {
    var watchKit: WKHapticType {
        switch self {
        case .notification: .notification
        case .directionUp: .directionUp
        case .directionDown: .directionDown
        case .success: .success
        case .failure: .failure
        case .retry: .retry
        case .start: .start
        case .stop: .stop
        case .click: .click
        }
    }
}
