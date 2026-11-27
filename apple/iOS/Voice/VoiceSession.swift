import AVFoundation
import CoachKit
import Foundation
import LiveKit
import Network
import Observation
import os

private let log = Logger(subsystem: "com.earayu.coachw", category: "voice")

/// The voice link to the coach (spec 7.1). The token API hands back the same room for every
/// reconnect until LiveKit closes it, so a rejoin finds the same coach (spec 7.4).
///
/// The only file that imports LiveKit. All lifecycle transitions live in `CoachKit`'s pure
/// `VoiceStateMachine`; this class is the thin MainActor I/O shell that executes its effects.
@MainActor
@Observable
final class VoiceSession: NSObject {
    static let shared = VoiceSession()

    /// Agent transcripts (livekit-agents publishes them as text streams on this topic).
    static let transcriptionTopic = "lk.transcription"

    enum Status: Equatable {
        case idle
        case requestingToken
        case connecting
        case connected
        case reconnecting
        /// The link is down; the next attempt is scheduled.
        case offline
        case failed(String)

        var title: String {
            switch self {
            case .idle: "未连接"
            case .requestingToken: "获取通行证…"
            case .connecting: "连接中…"
            case .connected: "已连接教练"
            case .reconnecting: "重新连接中…"
            case .offline: "网络断开，本机播报中，正在重连…"
            case .failed(let message): "连接失败：\(message)"
            }
        }
    }

    private var machine = VoiceStateMachine()
    private(set) var framesSent = 0
    private(set) var cuesReceived = 0

    var status: Status {
        switch machine.phase {
        case .idle: .idle
        case .requestingToken(let attempt, _): attempt > 0 ? .reconnecting : .requestingToken
        case .connectingRoom(let attempt, _): attempt > 0 ? .reconnecting : .connecting
        case .connected(let c): c.liveKitReconnecting ? .reconnecting : .connected
        case .waitingToRetry: .offline
        case .failed(.sessionEndedByServer): .failed("教练会话已结束")
        case .failed(.error(let message)): .failed(message)
        }
    }

    var isMuted: Bool { machine.isMuted }
    var isCoachSpeaking: Bool { machine.isCoachSpeaking }
    /// LiveKit hears the user's microphone right now: shows the user the coach can hear them.
    var isUserSpeaking: Bool { machine.isUserSpeaking }
    var reconnects: Int { machine.reconnects }
    var isActive: Bool { machine.isActive }
    /// The server ended the session on purpose (length cap, removed), as opposed to the user.
    var endedByServer: Bool { machine.phase == .failed(.sessionEndedByServer) }
    /// What the watch shows of the coach (spec 7.6).
    var coachState: CoachStatus.State {
        switch status {
        case .connected: .online
        case .requestingToken, .connecting, .reconnecting: .connecting
        case .offline: .offline
        case .idle, .failed: .off
        }
    }
    /// The user wants the coach but cannot hear it right now: the phone speaks key cues itself.
    var needsLocalFallback: Bool { machine.needsLocalFallback }

    /// Called with each coach cue from the agent that has not expired, e.g. to forward it to the watch.
    @ObservationIgnored var onCue: (@MainActor (CoachCue) -> Void)?
    /// Called with each finished line the coach said (agent transcript).
    @ObservationIgnored var onCoachLine: (@MainActor (String) -> Void)?
    /// Called with each final transcript of what the user said, so feedback given by voice is kept.
    @ObservationIgnored var onUserLine: (@MainActor (String) -> Void)?
    /// Called once each time an established link drops and offline fallback takes over.
    @ObservationIgnored var onLinkLost: (@MainActor () -> Void)?
    /// Called each time a session is connected and its microphone is live.
    @ObservationIgnored var onConnected: (@MainActor () -> Void)?
    /// Called whenever `status` changes.
    @ObservationIgnored var onStatusChanged: (@MainActor () -> Void)?
    /// Called when the voice session ends for good: the user stopped it or the server said no.
    @ObservationIgnored var onStopped: (@MainActor () -> Void)?
    /// The workout so far, for a session that joins mid-workout; nil when there is none.
    @ObservationIgnored var resumeProvider: (@MainActor () -> CoachResume?)?
    /// Answers the coach's `look_around` tool: query in, JSON out (spec 7.5).
    @ObservationIgnored var placesProvider: (@MainActor (String) async -> String)?

    /// Answers the coach's `start_workout` tool: activity wire name in, JSON out (spec 7.6).
    @ObservationIgnored var startProvider: (@MainActor (String) -> String)?
    /// Answers the coach's pause / resume / end tools: action in, JSON out (spec 7.6).
    @ObservationIgnored var controlProvider: (@MainActor (String) -> String)?
    /// Answers the coach's `get_history` tool: activity filter & limit in, compact JSON out (spec 11).
    @ObservationIgnored var historyProvider: (@MainActor (_ activity: String, _ limit: Int) -> String)?
    /// Called right before the coach's microphone is switched on, to release it elsewhere.
    @ObservationIgnored var onWillEnableMicrophone: (@MainActor () -> Void)?

    /// RPC the coach calls to look around the athlete (`server/src/coachw/session.py`).
    static let placesMethod = "coach.places"
    /// RPC the coach calls to start a workout on the watch (`server/src/coachw/session.py`).
    static let startMethod = "coach.start"
    /// RPC the coach calls to pause, resume or end the workout (`server/src/coachw/session.py`).
    static let controlMethod = "coach.control"
    /// RPC the coach calls to read recent workout summaries (`server/src/coachw/session.py`).
    static let historyMethod = "coach.history"
    /// A microphone that would not start is tried again this often while the room stays up.
    static let microphoneRetry: Duration = .seconds(5)
    /// Text the agent takes as the user's words (livekit-agents' chat input).
    static let chatTopic = "lk.chat"

    /// The coach answers this RPC (`server/src/coachw/session.py`). On mobile data the link died
    /// without LiveKit noticing for 30-90 s, and nobody heard the athlete meanwhile (COCH-15):
    /// unanswered pings end the link after ~15-20 s and the phone rejoins its room.
    static let heartbeatMethod = "coach.ping"
    static let heartbeatInterval: Duration = .seconds(5)
    static let heartbeatTimeout: TimeInterval = 5
    static let heartbeatMisses = 3

    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var roomGeneration: Int?
    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private var pendingGrant: (generation: Int, grant: SessionGrant)?
    /// Frames are published one after another, in the order they arrived (M3 trend windows).
    @ObservationIgnored private var sendTail: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var disconnectTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private let micMeter = MicMeter()
    @ObservationIgnored private var offlineAudioTap: OfflineAudioTap?

    func start(settings: AppSettings) async {
        guard !isActive else {
            diag("voice", "start ignored: already \(String(describing: status))")
            return
        }
        AudioManager.shared.remove(localAudioRenderer: micMeter)
        AudioManager.shared.add(localAudioRenderer: micMeter)
        await enableAudioPreparation()
        MicMeter.logAudioState("before connect")
        self.settings = settings
        framesSent = 0
        cuesReceived = 0
        dispatch(.start)
    }

    func stop() async {
        diag("voice", "stop requested")
        stopOfflineAudioCapture(releaseEngine: false)
        let roomToClose = self.room
        dispatch(.stop)
        await disconnectTask?.value
        await roomToClose?.disconnect()
        await releaseAudioPreparation()
    }

    /// Keeps LiveKit's audio engine initialized in muted `.playAndRecord` mode across room swaps
    /// so iOS does not tear down background audio and reject microphone restart in a pocket (COCH-22).
    func enableAudioPreparation() async {
        guard !AudioManager.shared.isRecordingAlwaysPreparedMode else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        do {
            try await AudioManager.shared.setRecordingAlwaysPreparedMode(true)
            diag("voice", "audio always-prepared mode enabled")
        } catch {
            diag("voice", "audio always-prepared mode failed: \(error.localizedDescription)")
        }
    }

    /// Releases background audio preparation once the voice session is truly done (not rejoining).
    func releaseAudioPreparation() async {
        guard AudioManager.shared.isRecordingAlwaysPreparedMode else { return }
        do {
            try await AudioManager.shared.setRecordingAlwaysPreparedMode(false)
            diag("voice", "audio always-prepared mode disabled")
        } catch {
            log.error("disabling always-prepared mode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Taps local microphone PCM buffers through LiveKit's shared audio engine while offline.
    func startOfflineAudioCapture(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async -> Bool {
        await disconnectTask?.value
        guard status == .offline || status == .reconnecting else { return false }
        stopOfflineAudioCapture(releaseEngine: false)
        let tap = OfflineAudioTap(sink: sink)
        AudioManager.shared.add(localAudioRenderer: tap)
        do {
            try AudioManager.shared.startLocalRecording()
            offlineAudioTap = tap
            return true
        } catch {
            AudioManager.shared.remove(localAudioRenderer: tap)
            diag("offline-voice", "LiveKit local recording failed: \(error.localizedDescription)")
            return false
        }
    }

    func stopOfflineAudioCapture(releaseEngine: Bool) {
        guard let tap = offlineAudioTap else { return }
        offlineAudioTap = nil
        AudioManager.shared.remove(localAudioRenderer: tap)
        if releaseEngine {
            try? AudioManager.shared.stopLocalRecording()
        }
    }

    func toggleMute() async {
        guard status == .connected, let room, let gen = roomGeneration else { return }
        let targetMuted = !isMuted
        do {
            try await room.localParticipant.setMicrophone(enabled: !targetMuted)
            dispatch(.muteChanged(generation: gen, isMuted: targetMuted))
        } catch {
            log.error("mute toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forwards metrics frames to the coach agent on the `coach.metrics` topic (spec 6.4), in order.
    func send(_ frames: [MetricsFrame]) {
        guard status == .connected, let room else { return }
        let payloads = frames.compactMap { frame in (try? frame.encoded()).map { (frame.seq, $0) } }
        guard !payloads.isEmpty else { return }
        let previous = sendTail
        sendTail = Task { [weak self] in
            await previous?.value
            let options = DataPublishOptions(topic: MetricsFrame.topic, reliable: true)
            for (seq, data) in payloads {
                guard !Task.isCancelled else { return }
                do {
                    try await room.localParticipant.publish(data: data, options: options)
                    self?.framesSent += 1
                } catch {
                    log.error("publish frame \(seq) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Tells the coach what the athlete said while it could not hear them (spec 7.4).
    func sendOfflineSpeech(_ text: String) async {
        guard status == .connected, let room else { return }
        do {
            _ = try await room.localParticipant.sendText("（刚才断网的时候我说了：\(text)）", for: Self.chatTopic)
            diag("voice", "sent \(text.count) characters said offline to the coach")
        } catch {
            log.error("sending offline speech failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - State Machine Effect Runner

    private func dispatch(_ event: VoiceStateMachine.Event) {
        let before = String(describing: status)
        let effects = machine.handle(event)
        let after = String(describing: status)
        if before != after { diag("voice", "\(before) -> \(after)") }
        for effect in effects { execute(effect) }
        if before != after { onStatusChanged?() }
    }

    private func execute(_ effect: VoiceStateMachine.Effect) {
        switch effect {
        case .startPathMonitor:
            startPathMonitor()
        case .stopPathMonitor:
            stopPathMonitor()
        case .requestToken(let gen):
            requestToken(generation: gen)
        case .connectRoom(let gen, let micEnabled):
            connectRoom(generation: gen, micEnabled: micEnabled)
        case .disconnectRoom:
            disconnectCurrentRoom()
        case .startHeartbeat(let gen):
            if let room, roomGeneration == gen { startHeartbeat(in: room, generation: gen) }
        case .stopHeartbeat:
            stopHeartbeat()
        case .cancelSendTail:
            sendTail?.cancel()
            sendTail = nil
        case .scheduleRetry(let gen, let delay):
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.dispatch(.retryTimerFired(generation: gen))
            }
        case .cancelRetry:
            retryTask?.cancel()
            retryTask = nil
        case .notifyConnected:
            onConnected?()
        case .notifyLinkLost:
            onLinkLost?()
        case .notifyStopped:
            if case .failed(.error) = machine.phase {
                Task { await self.releaseAudioPreparation() }
            }
            onStopped?()
        }
    }

    // MARK: - Connecting

    private func requestToken(generation gen: Int) {
        guard let settings else { return }
        let baseURL = settings.apiBaseURL
        let inviteCode = settings.trimmedInviteCode
        let athleteID = settings.athleteID
        let cueWriter = settings.cueWriter
        let voiceProvider = settings.voiceProvider
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            do {
                let grant = try await TokenClient.requestSession(
                    baseURL: baseURL,
                    inviteCode: inviteCode,
                    athleteID: athleteID,
                    cueWriter: cueWriter,
                    voiceProvider: voiceProvider
                )
                guard let self, !Task.isCancelled else { return }
                if self.machine.generation == gen {
                    self.pendingGrant = (gen, grant)
                    self.dispatch(.tokenSucceeded(generation: gen))
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                log.error("voice token request failed: \(error.localizedDescription, privacy: .public)")
                self.dispatch(.tokenFailed(
                    generation: gen, drop: Self.drop(for: error), message: error.localizedDescription
                ))
            }
        }
    }

    private func connectRoom(generation gen: Int, micEnabled: Bool) {
        guard let pending = pendingGrant, pending.generation == gen else { return }
        pendingGrant = nil
        let grant = pending.grant
        let room = Room(delegate: self)
        self.room = room
        self.roomGeneration = gen
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            do {
                await self?.disconnectTask?.value
                guard let self, self.machine.generation == gen else { return }
                try await room.connect(url: grant.serverUrl, token: grant.token)
                guard self.machine.generation == gen else {
                    await room.disconnect()
                    return
                }
                await self.listenForTranscripts(in: room)
                await self.answerPlaces(in: room)
                await self.answerStart(in: room)
                await self.answerControl(in: room)
                await self.answerHistory(in: room)
                if micEnabled { self.onWillEnableMicrophone?() }
                do {
                    try await room.localParticipant.setMicrophone(enabled: micEnabled)
                    if micEnabled { await self.enableAudioPreparation() }
                } catch {
                    // Leaving here dropped every reconnect within seconds, for 37 minutes, while
                    // the phone was in a pocket (COCH-22). Stay: the coach still talks, cues
                    // still reach the watch, and the microphone is tried again.
                    diag("voice", "microphone did not start: \(error.localizedDescription); listening only, retrying")
                    self.retryMicrophone(in: room, generation: gen)
                }
                guard self.machine.generation == gen else {
                    await room.disconnect()
                    return
                }
                self.dispatch(.roomReady(generation: gen))
                log.info("joined room \(grant.room, privacy: .public)")
                MicMeter.logAudioState("after connect")
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    MicMeter.logAudioState("4s after connect")
                }
                // an agent that is already here gets the workout now; one that joins later on arrival
                if room.remoteParticipants.values.contains(where: { $0.kind == .agent }) {
                    await self.sendResume()
                }
            } catch {
                guard let self else {
                    await room.disconnect()
                    return
                }
                log.error("voice connect failed: \(error.localizedDescription, privacy: .public)")
                diag("voice", "connect failed: \(error.localizedDescription)")
                if self.room === room {
                    self.room = nil
                    self.roomGeneration = nil
                }
                await room.disconnect()
                self.dispatch(.roomConnectFailed(
                    generation: gen, drop: Self.drop(for: error), message: error.localizedDescription
                ))
            }
        }
    }

    private func disconnectCurrentRoom() {
        connectTask?.cancel()
        connectTask = nil
        pendingGrant = nil
        let old = self.room
        self.room = nil
        self.roomGeneration = nil
        if let old {
            let previous = disconnectTask
            disconnectTask = Task {
                await previous?.value
                await old.disconnect()
            }
        }
    }

    /// Pings the coach while this room is current. A coach that never answers means the link is
    /// dead even if LiveKit still says connected or reconnecting: drop it and rejoin.
    private func startHeartbeat(in room: Room, generation gen: Int) {
        stopHeartbeat()
        let id = ObjectIdentifier(room)
        heartbeat = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled, let self, self.isCurrent(id) else { return }
                // no coach in the room yet (or it left, which is handled on its own)
                guard let coach = room.remoteParticipants.values.first(where: { $0.kind == .agent }),
                      let identity = coach.identity
                else { continue }
                do {
                    _ = try await room.localParticipant.performRpc(
                        destinationIdentity: identity, method: Self.heartbeatMethod, payload: "",
                        responseTimeout: Self.heartbeatTimeout, maxRoundTripLatency: Self.heartbeatTimeout
                    )
                    misses = 0
                } catch let error as RpcError {
                    switch HeartbeatErrorAction.forRpcCode(error.code) {
                    case .disable:
                        diag("voice", "coach does not answer heartbeats (rpc \(error.code)); heartbeat off")
                        return
                    case .ignore:
                        diag("voice", "heartbeat rpc \(error.code) (\(error.message)); link alive, ignoring")
                    case .countMiss:
                        misses += 1
                        diag("voice", "heartbeat missed (\(misses)/\(Self.heartbeatMisses)): rpc \(error.code) \(error.message)")
                        guard misses >= Self.heartbeatMisses, self.isCurrent(id) else { continue }
                        diag("voice", "coach unreachable for \(misses) heartbeats; rejoining")
                        self.dispatch(.heartbeatFailed(generation: gen))
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    misses += 1
                    diag("voice", "heartbeat missed (\(misses)/\(Self.heartbeatMisses)): \(String(describing: error))")
                    guard misses >= Self.heartbeatMisses, self.isCurrent(id) else { continue }
                    diag("voice", "coach unreachable for \(misses) heartbeats; rejoining")
                    self.dispatch(.heartbeatFailed(generation: gen))
                    return
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    private static func drop(for error: Error) -> ReconnectPolicy.Drop {
        switch error {
        case TokenError.invalidBaseURL, TokenError.unknownInvite, TokenError.quotaExhausted,
             TokenError.providerUnavailable: .final
        case TokenError.server(let code): ReconnectPolicy.drop(forHTTPStatus: code)
        default: .network
        }
    }

    /// Retry at once when the network comes back instead of waiting out the backoff.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self else { return }
                if case .waitingToRetry = self.machine.phase {
                    log.info("network is back, reconnecting now")
                    self.dispatch(.networkSatisfied)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.earayu.coachw.path"))
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Session content

    /// Sends the workout so far so the agent continues it (spec 7.4). Safe to repeat: the agent
    /// applies the first one.
    private func sendResume() async {
        guard status == .connected, let room, let resume = resumeProvider?(), let data = try? resume.encoded() else {
            return
        }
        do {
            try await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: CoachResume.topic, reliable: true))
            log.info("sent coach.resume")
        } catch {
            log.error("publish coach.resume failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func answerPlaces(in room: Room) async {
        do {
            try await room.registerRpcMethod(Self.placesMethod) { [weak self] data in
                let query = (try? JSONSerialization.jsonObject(with: Data(data.payload.utf8)) as? [String: Any])?["query"] as? String
                guard let self else { return #"{"available":false,"reason":"app closing"}"# }
                return await self.lookAround(query ?? "")
            }
        } catch {
            log.error("places RPC unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func answerStart(in room: Room) async {
        do {
            try await room.registerRpcMethod(Self.startMethod) { [weak self] data in
                let activity = (try? JSONSerialization.jsonObject(with: Data(data.payload.utf8)) as? [String: Any])?["activity"] as? String
                return await MainActor.run {
                    guard let start = self?.startProvider else { return #"{"ok":false,"reason":"not supported"}"# }
                    return start(activity ?? "")
                }
            }
        } catch {
            log.error("start RPC unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func answerControl(in room: Room) async {
        do {
            try await room.registerRpcMethod(Self.controlMethod) { [weak self] data in
                let action = (try? JSONSerialization.jsonObject(with: Data(data.payload.utf8)) as? [String: Any])?["action"] as? String
                return await MainActor.run {
                    guard let control = self?.controlProvider else { return #"{"ok":false,"reason":"not supported"}"# }
                    return control(action ?? "")
                }
            }
        } catch {
            log.error("control RPC unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func answerHistory(in room: Room) async {
        do {
            try await room.registerRpcMethod(Self.historyMethod) { [weak self] data in
                let obj = (try? JSONSerialization.jsonObject(with: Data(data.payload.utf8)) as? [String: Any]) ?? [:]
                let activity = obj["activity"] as? String ?? ""
                let limit = obj["limit"] as? Int ?? 5
                return await MainActor.run {
                    guard let history = self?.historyProvider else {
                        return #"{"available":false,"reason":"not supported"}"#
                    }
                    return history(activity, limit)
                }
            }
        } catch {
            log.error("history RPC unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func retryMicrophone(in room: Room, generation gen: Int) {
        let id = ObjectIdentifier(room)
        Task { [weak self] in
            for attempt in 1... {
                try? await Task.sleep(for: Self.microphoneRetry)
                guard let self, self.isCurrent(id), self.machine.generation == gen else { return }
                guard !self.isMuted else { continue }
                do {
                    self.onWillEnableMicrophone?()
                    try await room.localParticipant.setMicrophone(enabled: true)
                    await self.enableAudioPreparation()
                    diag("voice", "microphone started on retry \(attempt)")
                    return
                } catch {
                    if attempt % 6 == 1 { diag("voice", "microphone retry \(attempt) failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    private func lookAround(_ query: String) async -> String {
        guard let placesProvider else { return #"{"available":false,"reason":"not supported"}"# }
        return await placesProvider(query)
    }

    private func listenForTranscripts(in room: Room) async {
        let me = room.localParticipant.identity
        let id = ObjectIdentifier(room)
        do {
            try await room.registerTextStreamHandler(for: Self.transcriptionTopic) { [weak self] reader, sender in
                // the agent also publishes the user's own words, under the user's identity: interim
                // guesses first, then one final segment
                let isUser = sender == me
                if isUser, reader.info.attributes["lk.transcription_final"] != "true" { return }
                let text = try await reader.readAll()
                await MainActor.run {
                    guard let self, self.isCurrent(id) else { return }
                    if isUser { self.onUserLine?(text) } else { self.onCoachLine?(text) }
                }
            }
        } catch {
            log.error("transcript stream unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func receive(_ cue: CoachCue) {
        guard !cue.isExpired(at: .now) else {
            log.info("dropping expired cue \(cue.id, privacy: .public)")
            return
        }
        cuesReceived += 1
        onCue?(cue)
    }

    /// Delegate callbacks may come from a room this session already let go of.
    private func isCurrent(_ id: ObjectIdentifier) -> Bool {
        room.map(ObjectIdentifier.init) == id
    }

    private nonisolated static func isFatalDisconnect(_ error: LiveKitError?) -> Bool {
        guard let type = error?.type else { return false }
        return [.roomDeleted, .participantRemoved, .duplicateIdentity].contains(type)
    }
}

/// Forwards local mic PCM buffers from LiveKit's audio engine into `OfflineVoiceRecorder`.
private final class OfflineAudioTap: NSObject, AudioRenderer, @unchecked Sendable {
    private let sink: @Sendable (AVAudioPCMBuffer) -> Void

    init(sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.sink = sink
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        sink(pcmBuffer)
    }
}

/// Logs the microphone level LiveKit actually captures, every few seconds, plus the audio session
/// it runs in. On device the coach heard pure digital silence from the phone (COCH-12); this tells
/// a silent capture apart from a network or server problem. Levels only, never audio.
final class MicMeter: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var frames = 0
    private var since = Date()

    func render(pcmBuffer: AVAudioPCMBuffer) {
        var bufferPeak: Float = 0
        if let channel = pcmBuffer.floatChannelData?[0] {
            for i in 0..<Int(pcmBuffer.frameLength) { bufferPeak = max(bufferPeak, abs(channel[i])) }
        } else if let channel = pcmBuffer.int16ChannelData?[0] {
            for i in 0..<Int(pcmBuffer.frameLength) { bufferPeak = max(bufferPeak, Float(abs(Int(channel[i]))) / 32768) }
        }
        lock.lock()
        peak = max(peak, bufferPeak)
        frames += Int(pcmBuffer.frameLength)
        let due = Date().timeIntervalSince(since) >= 3
        let report = due ? (peak, frames) : nil
        if due { peak = 0; frames = 0; since = Date() }
        lock.unlock()
        if let (p, n) = report {
            log.info("mic peak \(String(format: "%.4f", p), privacy: .public) over \(n, privacy: .public) frames")
        }
    }

    static func logAudioState(_ context: String) {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        log.info(
            "audio \(context, privacy: .public): category \(session.category.rawValue, privacy: .public) mode \(session.mode.rawValue, privacy: .public) in [\(inputs, privacy: .public)] out [\(outputs, privacy: .public)] inputAvailable \(session.isInputAvailable, privacy: .public) permission \(AVAudioApplication.shared.recordPermission.rawValue, privacy: .public) engineRunning \(AudioManager.shared.isEngineRunning, privacy: .public) micMuted \(AudioManager.shared.isMicrophoneMuted, privacy: .public)"
        )
    }
}

extension VoiceSession: RoomDelegate {
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        let id = ObjectIdentifier(room)
        Task { @MainActor in
            guard self.isCurrent(id), let gen = self.roomGeneration else { return }
            switch connectionState {
            case .connected:
                self.dispatch(.liveKitConnectionChanged(generation: gen, reconnecting: false))
            case .reconnecting:
                self.dispatch(.liveKitConnectionChanged(generation: gen, reconnecting: true))
            default:
                break
            }
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        let id = ObjectIdentifier(room)
        let fatal = Self.isFatalDisconnect(error)
        let desc = error.map { String(describing: $0.type) } ?? "no error"
        Task { @MainActor in
            guard self.isCurrent(id), let gen = self.roomGeneration else { return }
            log.info("voice link lost: \(desc, privacy: .public)")
            self.dispatch(.roomDisconnected(generation: gen, isFatal: fatal))
        }
    }

    /// The coach left while the phone stayed in the room (its job ended, or the agent server
    /// restarted): nobody would ever answer again, so start a fresh session as after a drop.
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard participant.kind == .agent else { return }
        let id = ObjectIdentifier(room)
        Task { @MainActor in
            guard self.isCurrent(id), let gen = self.roomGeneration else { return }
            log.info("coach left the room; starting a new session")
            self.dispatch(.agentLeft(generation: gen))
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        guard participant.kind == .agent else { return }
        let id = ObjectIdentifier(room)
        Task { @MainActor in
            guard self.isCurrent(id) else { return }
            await self.sendResume()
        }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        let id = ObjectIdentifier(room)
        let speaking = participants.contains { $0.kind == .agent }
        let userSpeaking = participants.contains { $0 is LocalParticipant }
        Task { @MainActor in
            guard self.isCurrent(id), let gen = self.roomGeneration else { return }
            self.dispatch(.speakingChanged(generation: gen, coach: speaking, user: userSpeaking))
        }
    }

    nonisolated func room(
        _ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String,
        encryptionType: EncryptionType
    ) {
        guard topic == CoachCue.topic, participant != nil else { return }
        let id = ObjectIdentifier(room)
        guard let cue = try? CoachCue.decode(data) else {
            log.error("dropping undecodable cue (\(data.count) bytes)")
            return
        }
        Task { @MainActor in
            guard self.isCurrent(id) else { return }
            self.receive(cue)
        }
    }
}
