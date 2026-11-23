import CoachKit
import HealthKit
import Observation
import os

private let log = Logger(subsystem: "com.earayu.coachw", category: "mirror")

/// Receives the workout session mirrored from the watch and the metrics frames it sends.
///
/// All lifecycle transitions, launch/reattach/end timeouts, and stale-callback guards live in
/// `CoachKit`'s pure `MirrorStateMachine`; this class is the thin MainActor HealthKit shell.
@MainActor
@Observable
final class MirrorReceiver: NSObject {
    static let shared = MirrorReceiver()

    let healthStore = HKHealthStore()

    private var machine = MirrorStateMachine()
    private(set) var latest: MetricsFrame?
    private(set) var stats = FrameStats()
    private var authError: String?

    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var sessionGeneration: Int?
    @ObservationIgnored private var timers: [MirrorStateMachine.TimerID: Task<Void, Never>] = [:]
    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// Called with every batch of received frames, e.g. to forward them to the coach.
    @ObservationIgnored var onFrames: (@MainActor ([MetricsFrame]) -> Void)?
    /// Called when a workout session from the watch attaches, and when it ends.
    @ObservationIgnored var onSessionStarted: (@MainActor (WorkoutActivity) -> Void)?
    @ObservationIgnored var onSessionEnded: (@MainActor () -> Void)?

    var state: HKWorkoutSessionState {
        switch machine.phase {
        case .idle, .launchingWatch, .awaitingMirror: .notStarted
        case .active(let w), .disconnected(let w):
            switch w.runState {
            case .prepared: .prepared
            case .running: .running
            case .paused: .paused
            case .stopping: .stopped
            }
        }
    }

    var activity: WorkoutActivity? { machine.activeActivity.map(WorkoutActivity.init(wireName:)) }
    var startingActivity: WorkoutActivity? { machine.startingActivity.map(WorkoutActivity.init(wireName:)) }
    var awaitingActivity: WorkoutActivity? { machine.awaitingActivity.map(WorkoutActivity.init(wireName:)) }
    var isActive: Bool { machine.isActive }
    var isRunning: Bool { machine.isRunning }
    var isPaused: Bool { machine.isPaused }
    var isStartingWatch: Bool { machine.isStartingWatch }
    var isWatchSlowToStart: Bool { machine.isWatchSlowToStart }

    var lastError: String? {
        if let notice = machine.notice { return Self.message(for: notice) }
        return authError
    }

    /// When the phone starts telling the athlete to wake the watch or start on it instead.
    static let slowStartAfter: Duration = .seconds(4)
    /// How long the phone waits for the watch's session after asking it to start.
    static let attachTimeout: Duration = .seconds(120)
    /// How long the watch gets to confirm an end before the phone closes the workout on its own.
    static let endTimeout: Duration = .seconds(5)
    /// How long a disconnected workout waits for the watch to mirror again before the phone closes
    /// it. HealthKit re-mirrors in about 15 s; a link that stays down past this means the workout
    /// ended on the watch without the phone hearing of it (COCH-15).
    static let reattachTimeout: Duration = .seconds(120)

    static func ms(since date: Date) -> Int { Int((Date().timeIntervalSince(date) * 1000).rounded()) }

    /// Must run at launch: HealthKit may launch the app in the background to hand over a session.
    func install() {
        healthStore.workoutSessionMirroringStartHandler = { [weak self] mirrored in
            Task { @MainActor in self?.attach(mirrored) }
        }
    }

    func requestAuthorization() async {
        do {
            try await healthStore.requestAuthorization(toShare: HealthTypes.share, read: HealthTypes.read)
            authError = nil
        } catch {
            authError = "健康权限请求失败：\(error.localizedDescription)"
        }
    }

    /// Launches the watch app and asks it to start the workout; the session then mirrors back here.
    func startOnWatch(_ activity: WorkoutActivity) async {
        diag("phone", "start on watch requested: \(activity.wireName), state \(state.label), session \(session != nil)")
        if isStartingWatch {
            diag("phone", "ignoring start: already waiting for the watch")
            return
        }
        authError = nil
        dispatch(.startOnWatch(activity: activity.wireName))
    }

    /// Stops waiting for a start the watch has not taken yet. The request may still reach the
    /// watch later; a workout it starts then still mirrors here and shows up.
    func cancelStart() {
        if case .launchingWatch = machine.phase {
            diag("phone", "start on watch cancelled while waiting for the watch")
        }
        dispatch(.cancelStart)
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

    /// Tells the watch whether the voice coach is with the athlete (spec 7.6).
    func sendToWatch(_ status: CoachStatus) {
        guard let session, let data = try? status.encoded() else { return }
        Task {
            do {
                try await session.sendToRemoteWorkoutSession(data: data)
            } catch {
                log.error("sending coach status to watch failed: \(error.localizedDescription)")
            }
        }
    }

    func pause() {
        diag("phone", "pause requested, state \(state.label), session \(session != nil)")
        dispatch(.pauseRequested)
    }

    func resume() {
        diag("phone", "resume requested, state \(state.label), session \(session != nil)")
        dispatch(.resumeRequested)
    }

    /// Asks the watch to end the workout. A watch that has gone away never answers, which left the
    /// phone stuck on the dashboard (COCH-12): then the phone closes the workout itself. The watch
    /// still owns and saves the HealthKit workout.
    func end() {
        diag("phone", "end requested, state \(state.label), session \(session.map { $0.state.label } ?? "none")")
        dispatch(.endRequested)
    }

    // MARK: - State Machine Effect Runner

    private func dispatch(_ event: MirrorStateMachine.Event, incoming: HKWorkoutSession? = nil) {
        let effects = machine.handle(event)
        for effect in effects { execute(effect, incoming: incoming) }
    }

    private func execute(_ effect: MirrorStateMachine.Effect, incoming: HKWorkoutSession?) {
        switch effect {
        case .callStartWatchApp(let wireName, let gen):
            let activity = WorkoutActivity(wireName: wireName)
            let began = Date()
            startTask?.cancel()
            startTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.healthStore.startWatchApp(toHandle: activity.configuration())
                    diag("phone", "startWatchApp returned after \(Self.ms(since: began)) ms; waiting for the watch to mirror")
                    self.dispatch(.watchAppStarted(generation: gen))
                } catch {
                    diag("phone", "startWatchApp failed after \(Self.ms(since: began)) ms: \(Self.describe(error))")
                    log.error("startWatchApp failed: \(error.localizedDescription)")
                    self.dispatch(.watchAppStartFailed(generation: gen, message: error.localizedDescription))
                }
            }

        case .scheduleTimer(let id, let gen):
            scheduleTimer(id, generation: gen)

        case .cancelTimer(let id):
            timers[id]?.cancel()
            timers[id] = nil

        case .sendPause:
            session?.pause()

        case .sendResume:
            session?.resume()

        case .sendStop:
            session?.stopActivity(with: .now)

        case .detachSession:
            session?.delegate = nil
            session = nil
            sessionGeneration = nil

        case .attachIncomingSession(let gen):
            guard let incoming else { return }
            session = incoming
            sessionGeneration = gen
            incoming.delegate = self

        case .resetMetrics:
            latest = nil
            stats = FrameStats()

        case .notifySessionStarted(let wireName):
            onSessionStarted?(WorkoutActivity(wireName: wireName))

        case .notifySessionEnded:
            diag("phone", "workout closed on the phone")
            onSessionEnded?()
        }
    }

    private func scheduleTimer(_ id: MirrorStateMachine.TimerID, generation gen: Int) {
        timers[id]?.cancel()
        let duration: Duration = switch id {
        case .slowStart: Self.slowStartAfter
        case .attachTimeout: Self.attachTimeout
        case .endTimeout: Self.endTimeout
        case .reattachTimeout: Self.reattachTimeout
        }
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.timers[id] = nil
            switch id {
            case .slowStart:
                diag("phone", "watch has not taken the start \(Self.slowStartAfter) after the tap")
                self.dispatch(.slowStartTimerFired(generation: gen))
            case .attachTimeout:
                diag("phone", "no mirrored session \(Self.attachTimeout) after the tap")
                self.dispatch(.attachTimerFired(generation: gen))
            case .endTimeout:
                diag("phone", "watch did not confirm the end within \(Self.endTimeout) (state \(self.state.label)); closing on the phone")
                self.dispatch(.endTimerFired(generation: gen))
            case .reattachTimeout:
                diag("phone", "watch did not mirror again within \(Self.reattachTimeout); closing on the phone")
                self.dispatch(.reattachTimerFired(generation: gen))
            }
        }
    }

    private func attach(_ mirrored: HKWorkoutSession) {
        let activity = WorkoutActivity(healthKitType: mirrored.workoutConfiguration.activityType)
        diag("phone", "mirrored session attached, state \(mirrored.state.label)")
        dispatch(
            .sessionAttached(
                activity: activity.wireName,
                startedAt: mirrored.startDate,
                state: mirrored.state.portable
            ),
            incoming: mirrored
        )
    }

    private func receive(_ frames: [MetricsFrame], generation gen: Int) {
        if let latest, latest.isStale(at: .now), let silence = latest.silence(at: .now) {
            diag("phone", "frames resumed after \(Int(silence))s of silence")
        }
        if latest == nil { diag("phone", "first frame received") }
        for frame in frames {
            stats.record(frame)
            if frame.isNewer(than: latest) { latest = frame }
        }
        onFrames?(frames)
        if let latest {
            if latest.state == .ended { diag("phone", "watch reports the workout ended") }
            dispatch(.framesReceived(generation: gen, latestState: latest.state))
        }
    }

    private static func message(for notice: MirrorStateMachine.Notice) -> String {
        switch notice {
        case .watchLaunchFailed(let message):
            "无法从手机启动手表：\(message)\n请抬腕解锁手表，或直接在手表上打开 coach-w 开始，手机会自动接上。"
        case .watchAttachTimedOut:
            "手表没有开始运动。请抬腕看看手表上的 coach-w：如果还停在上一场运动，先在手表上结束它；也可以直接在手表上开始。"
        case .sessionFailed(let message):
            message
        case .disconnected(let message):
            "与手表断开：\(message)"
        case .controlsUnavailableWhileDisconnected:
            "手表已断开，暂停和继续请在手表上操作；点「结束」可在手机上结束本次记录。"
        case .endedWhileAwaitingMirror:
            "手机不再等手表的数据。手表上已经开始的运动请在手表上结束。"
        case .endedWhileDisconnected:
            "手表已断开，已在手机上结束本次记录。手表上的运动请在手表上结束。"
        case .watchDidNotConfirmEnd:
            "手表没有响应，已在手机上结束。手表上的运动请在手表上结束。"
        case .reattachTimedOut:
            "与手表断开太久，已在手机上保存本次记录。手表上的运动请在手表上确认已结束。"
        }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
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
        let portable = toState.portable
        Task { @MainActor in
            guard self.session === workoutSession, let gen = self.sessionGeneration else { return }
            self.dispatch(.sessionStateChanged(generation: gen, state: portable))
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        diag("phone", "mirrored session failed: \(Self.describe(error))")
        Task { @MainActor in
            guard self.session === workoutSession, let gen = self.sessionGeneration else { return }
            self.dispatch(.sessionFailed(generation: gen, message: message))
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        diag("phone", "mirrored session disconnected: \(error.map(Self.describe) ?? "no error")")
        let message = error?.localizedDescription ?? "unknown"
        Task { @MainActor in
            guard self.session === workoutSession, let gen = self.sessionGeneration else { return }
            self.dispatch(.sessionDisconnected(generation: gen, message: message))
        }
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
        Task { @MainActor in
            guard self.session === workoutSession, let gen = self.sessionGeneration else { return }
            self.receive(frames, generation: gen)
        }
    }
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
