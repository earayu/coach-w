import CoachKit
import CoreLocation
import HealthKit
import Observation
import WatchKit
import os

private let log = Logger(subsystem: "com.earayu.coachw.watch", category: "workout")

/// Owns the primary workout session on the watch and streams metrics frames to the iPhone.
///
/// All lifecycle transitions (`recover`, `start`, HealthKit state changes, saving, timeouts) live
/// in `CoachKit`'s pure `WatchWorkoutStateMachine`; this class is the thin WatchKit/HealthKit shell.
@MainActor
@Observable
final class WorkoutController: NSObject {
    static let shared = WorkoutController()

    let healthStore = HKHealthStore()

    private var machine = WatchWorkoutStateMachine(finishTimeoutSeconds: 15)
    private(set) var latest: MetricsFrame?
    private var authError: String?
    private var mirrorError: String?
    /// The coach cue on screen, if any (spec 4.1: key cues also buzz the watch).
    private(set) var cue: CoachCue?
    /// Whether the voice coach is with the athlete, as the phone last said (spec 7.6).
    private(set) var coachStatus: CoachStatus?

    var state: HKWorkoutSessionState {
        switch machine.phase {
        case .idle, .recovering, .starting: .notStarted
        case .active(_, .prepared): .prepared
        case .active(_, .running): .running
        case .active(_, .paused): .paused
        case .saving: .stopped
        }
    }

    var activity: WorkoutActivity? { machine.activity.map(WorkoutActivity.init(wireName:)) }
    var isRunning: Bool { machine.isRunning }
    var isPaused: Bool { machine.isPaused }
    var isFinishing: Bool { machine.isFinishing }

    var lastError: String? {
        if let notice = machine.notice { return Self.message(for: notice) }
        return mirrorError ?? authError
    }

    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var sessionGeneration: Int?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var frames: FrameBuilder?
    @ObservationIgnored private var pendingConfiguration: HKWorkoutConfiguration?
    /// Sends a frame every second while running, so elapsed time stays fresh and a missing
    /// stream means a broken link rather than "no new samples".
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var cueDismissal: Task<Void, Never>?
    @ObservationIgnored private var timers: [WatchWorkoutStateMachine.TimerID: Task<Void, Never>] = [:]
    /// GPS for outdoor activities: the route goes to HealthKit with the workout, the latest fix
    /// into the frames (docs/spec.md 6.3, 11).
    @ObservationIgnored private let locationFeed = LocationFeed()
    @ObservationIgnored private var routeBuilder: HKWorkoutRouteBuilder?
    @ObservationIgnored private var sendFailures = 0

    /// A cue stays on screen at most this long, and never past its expiry.
    static let cueDisplaySeconds: TimeInterval = 4
    /// How long saving may take after a stop before the watch gives up waiting and ends the session.
    static let finishTimeout: Duration = .seconds(15)
    static let forceResetTimeout: Duration = .seconds(2)

    func requestAuthorization() async {
        do {
            try await healthStore.requestAuthorization(toShare: HealthTypes.share, read: HealthTypes.read)
            authError = nil
        } catch {
            authError = "健康权限请求失败：\(error.localizedDescription)"
        }
    }

    func start(_ activity: WorkoutActivity) async {
        await start(activity.configuration())
    }

    /// Starts a workout, either from the watch UI or from the iPhone via `startWatchApp(toHandle:)`.
    func start(_ configuration: HKWorkoutConfiguration) async {
        let wanted = WorkoutActivity(healthKitType: configuration.activityType).wireName
        diag("watch", "start \(wanted) requested, state \(state.label), session \(session.map { $0.state.label } ?? "none")")
        pendingConfiguration = configuration
        authError = nil
        mirrorError = nil
        dispatch(.startRequested(activity: wanted, now: .now))
    }

    /// Picks up the workout that was running when the app quit or crashed. watchOS relaunches the
    /// app for it; without this the session keeps running but no frame reaches the iPhone again.
    func recover() async {
        dispatch(.recoverRequested)
    }

    func pause() {
        diag("watch", "pause tapped, state \(state.label), session \(session != nil)")
        dispatch(.pauseRequested)
    }

    func resume() {
        diag("watch", "resume tapped, state \(state.label), session \(session != nil)")
        dispatch(.resumeRequested)
    }

    func end() {
        diag("watch", "end tapped, state \(state.label), session \(session.map { $0.state.label } ?? "none")")
        dispatch(.endRequested)
    }

    /// Buzzes and shows a cue from the coach. Expired cues are dropped: a late buzz misleads.
    func present(_ cue: CoachCue) {
        let now = Date()
        guard machine.isActive, !cue.isExpired(at: now) else {
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

    // MARK: - State Machine Effect Runner

    private func dispatch(_ event: WatchWorkoutStateMachine.Event) {
        let effects = machine.handle(event)
        for effect in effects { execute(effect) }
    }

    private func execute(_ effect: WatchWorkoutStateMachine.Effect) {
        switch effect {
        case .runRecovery(let gen):
            Task { [weak self] in await self?.runRecovery(generation: gen) }

        case .startSession(let wireName, let gen):
            let configuration = pendingConfiguration ?? WorkoutActivity(wireName: wireName).configuration()
            pendingConfiguration = nil
            Task { [weak self] in await self?.runStart(configuration: configuration, wanted: wireName, generation: gen) }

        case .beginSaving(let gen, let date):
            locationFeed.stop()
            Task { [weak self] in await self?.runFinish(generation: gen, at: date) }

        case .startRouteIfGPS:
            if activity?.usesGPS == true, routeBuilder == nil, let builder {
                startRoute(builder)
            }

        case .startMirroringAfterRecovery(let gen):
            guard let session, sessionGeneration == gen else { return }
            Task {
                do {
                    try await session.startMirroringToCompanionDevice()
                } catch {
                    // still mirroring from before the relaunch
                    log.info("mirroring after recovery: \(error.localizedDescription, privacy: .public)")
                }
            }

        case .startHeartbeat:
            startHeartbeat()

        case .stopHeartbeat:
            stopHeartbeat()

        case .pauseSession:
            session?.pause()

        case .resumeSession:
            session?.resume()

        case .stopActivity:
            session?.stopActivity(with: .now)

        case .endSession:
            session?.end()

        case .emitForcedFrame(let wireState, let date):
            ingest([], elapsed: builder?.elapsedTime(at: date) ?? 0, wireState: wireState, force: true)

        case .scheduleTimer(let id, let gen):
            scheduleTimer(id, generation: gen)

        case .cancelTimer(let id):
            timers[id]?.cancel()
            timers[id] = nil

        case .resetResources:
            resetResources()
        }
    }

    private func runStart(configuration: HKWorkoutConfiguration, wanted: String, generation gen: Int) async {
        guard machine.generation == gen else { return }
        let began = Date()
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = adopt(session, generation: gen)
            // Mirroring waits on the iPhone. Ask first, wait for nothing: the workout must not
            // depend on it (AGENTS.md 1, COCH-13, COCH-15).
            startMirroring(session, generation: gen)
            let startDate = Date()
            session.startActivity(with: startDate)
            try await builder.beginCollection(at: startDate)
            diag("watch", "workout \(wanted) started in \(Self.ms(since: began)) ms")
            dispatch(.startSucceeded(generation: gen))
        } catch {
            diag("watch", "start \(wanted) failed after \(Self.ms(since: began)) ms: \(error.localizedDescription)")
            log.error("failed to start workout: \(error.localizedDescription)")
            dispatch(.startFailed(generation: gen, message: error.localizedDescription))
        }
    }

    private func runRecovery(generation gen: Int) async {
        do {
            guard let session = try await healthStore.recoverActiveWorkoutSession() else {
                diag("watch", "recovery: no active workout")
                dispatch(.recoveryFoundNone(generation: gen))
                return
            }
            guard machine.generation == gen else { return }
            diag("watch", "recovered active workout, state \(session.state.label)")
            log.info("recovered active workout session")
            _ = adopt(session, generation: gen)
            let activity = WorkoutActivity(healthKitType: session.workoutConfiguration.activityType)
            if session.state == .stopped {
                diag("watch", "recovered a stopped workout; saving it now")
            }
            dispatch(.recoveryFoundSession(
                generation: gen,
                activity: activity.wireName,
                state: session.state.portable,
                endDate: session.endDate ?? .now,
                now: .now
            ))
        } catch {
            diag("watch", "workout recovery failed: \(error.localizedDescription)")
            log.error("workout recovery failed: \(error.localizedDescription, privacy: .public)")
            dispatch(.recoveryFailed(generation: gen, message: error.localizedDescription))
        }
    }

    private func runFinish(generation gen: Int, at date: Date) async {
        guard sessionGeneration == gen, let builder else {
            diag("watch", "stopped without a builder or session")
            dispatch(.finishCompleted(generation: gen))
            return
        }
        let began = Date()
        do {
            try await builder.endCollection(at: date)
            _ = try await builder.finishWorkout()
            diag("watch", "workout saved in \(Self.ms(since: began)) ms")
            dispatch(.finishCompleted(generation: gen))
        } catch {
            diag("watch", "saving workout failed after \(Self.ms(since: began)) ms: \(error.localizedDescription)")
            log.error("failed to finish workout: \(error.localizedDescription)")
            dispatch(.finishFailed(generation: gen, message: error.localizedDescription))
        }
    }

    private func startMirroring(_ session: HKWorkoutSession, generation gen: Int) {
        Task { [weak self] in
            let began = Date()
            do {
                try await session.startMirroringToCompanionDevice()
                diag("watch", "mirroring to iPhone started in \(Self.ms(since: began)) ms")
            } catch {
                diag("watch", "mirroring to iPhone failed after \(Self.ms(since: began)) ms: \(error.localizedDescription)")
                guard let self, self.session === session, self.sessionGeneration == gen else { return }
                self.mirrorError = "未连上 iPhone：\(error.localizedDescription)。运动照常记录。"
            }
        }
    }

    private func adopt(_ session: HKWorkoutSession, generation gen: Int) -> HKLiveWorkoutBuilder {
        let configuration = session.workoutConfiguration
        let activity = WorkoutActivity(healthKitType: configuration.activityType)
        let builder = session.associatedWorkoutBuilder()
        session.delegate = self
        builder.delegate = self
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        self.session = session
        self.sessionGeneration = gen
        self.builder = builder
        frames = FrameBuilder(activity: activity.wireName, minInterval: 0.9)
        mirrorError = nil
        return builder
    }

    private func startRoute(_ builder: HKLiveWorkoutBuilder) {
        routeBuilder = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder
        locationFeed.start { [weak self] locations in self?.receive(locations) }
    }

    private func receive(_ locations: [CLLocation]) {
        guard machine.isActive, let last = locations.last else { return }
        if let routeBuilder {
            Task {
                do {
                    try await routeBuilder.insertRouteData(locations)
                } catch {
                    log.error("inserting route data failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        let altitude = last.verticalAccuracy >= 0 ? last.altitude : nil
        let reading = MetricReading.location(
            latitude: last.coordinate.latitude, longitude: last.coordinate.longitude, altitudeMeters: altitude
        )
        ingest([reading], elapsed: builder?.elapsedTime ?? 0)
    }

    private func scheduleTimer(_ id: WatchWorkoutStateMachine.TimerID, generation gen: Int) {
        timers[id]?.cancel()
        let duration: Duration = switch id {
        case .finishTimeout: Self.finishTimeout
        case .forceResetTimeout: Self.forceResetTimeout
        }
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.timers[id] = nil
            switch id {
            case .finishTimeout:
                diag("watch", "workout did not end \(Self.finishTimeout) after stop (state \(self.state.label)); ending it")
                self.dispatch(.finishTimerFired(generation: gen))
            case .forceResetTimeout:
                self.dispatch(.forceResetTimerFired(generation: gen))
            }
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.ingest([], elapsed: self.builder?.elapsedTime ?? 0)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    private func resetResources() {
        locationFeed.stop()
        routeBuilder = nil
        stopHeartbeat()
        session?.delegate = nil
        session = nil
        sessionGeneration = nil
        builder?.delegate = nil
        builder = nil
        frames = nil
        latest = nil
        cueDismissal?.cancel()
        cue = nil
        coachStatus = nil
        sendFailures = 0
        mirrorError = nil
    }

    private func ingest(
        _ readings: [MetricReading],
        elapsed: TimeInterval,
        wireState: WorkoutState? = nil,
        force: Bool = false
    ) {
        guard var frames else { return }
        let now = Date()
        for reading in readings { frames.apply(reading, at: now) }
        let frame = frames.frame(state: wireState ?? machine.wireState, elapsed: elapsed, at: now, force: force)
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
                    guard self.session === session else { return }
                    self.sendFailures += 1
                    // first failure and then one in 30: enough to see a dead link, not a flood
                    if self.sendFailures % 30 == 1 {
                        diag("watch", "sending frame \(frame.seq) failed (\(self.sendFailures) so far): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private static func message(for notice: WatchWorkoutStateMachine.Notice) -> String {
        switch notice {
        case .alreadyActive: "已有一场运动在进行，请先结束它。"
        case .previousWorkoutStillSaving: "上一场运动正在保存，请稍候再开始。"
        case .startFailed(let message): "开始运动失败：\(message)"
        case .recoveryFailed(let message): "恢复运动失败：\(message)"
        case .sessionFailed(let message): message
        case .saveFailed(let message): "保存运动失败：\(message)"
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
        diag("watch", "session \(fromState.label) -> \(toState.label)")
        let portable = toState.portable
        Task { @MainActor in
            guard self.session === workoutSession, let gen = self.sessionGeneration else { return }
            self.dispatch(.sessionStateChanged(generation: gen, state: portable, at: date, now: .now))
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        diag("watch", "workout session failed: \(message)")
        log.error("workout session failed: \(message)")
        Task { @MainActor in
            guard self.session === workoutSession, let gen = self.sessionGeneration else { return }
            self.dispatch(.sessionFailed(generation: gen, message: message))
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        // The iPhone sends coach cues and the coach's status on this channel (spec 6.3).
        let cues = data.compactMap { try? CoachCue.decode($0) }
        let statuses = data.compactMap { try? CoachStatus.decode($0) }
        let unknown = data.count - cues.count - statuses.count
        if unknown > 0 { log.error("dropping \(unknown) undecodable message(s)") }
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            cues.forEach(self.present)
            if let status = statuses.max(by: { $0.ts < $1.ts }), status.ts >= self.coachStatus?.ts ?? 0 {
                self.coachStatus = status
            }
        }
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
        Task { @MainActor in
            guard self.builder === workoutBuilder else { return }
            self.ingest(readings, elapsed: elapsed)
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

extension WorkoutController {
    static func ms(since date: Date) -> Int { Int((Date().timeIntervalSince(date) * 1000).rounded()) }
}

extension HKWorkoutSessionState {
    var portable: WorkoutSessionState {
        switch self {
        case .notStarted: .notStarted
        case .prepared: .prepared
        case .running: .running
        case .paused: .paused
        case .stopped: .stopped
        case .ended: .ended
        @unknown default: .notStarted
        }
    }
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
