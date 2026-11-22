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
/// The only file that imports LiveKit. LiveKit's automatic audio session setup
/// uses `.playAndRecord` with Bluetooth HFP/A2DP, which is what the headphones need.
///
/// When the link drops, or the coach stops answering heartbeats, it keeps trying with a fresh token
/// (spec 7.4) until the user ends the voice
/// session or the server says no; meanwhile `needsLocalFallback` tells the app to announce key
/// cues itself. Each new session gets the workout so far as `coach.resume`.
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

    private(set) var status: Status = .idle {
        didSet {
            let new = String(describing: status), old = String(describing: oldValue)
            if new != old { diag("voice", "\(old) -> \(new)") }
        }
    }
    private(set) var isMuted = false
    private(set) var isCoachSpeaking = false
    /// LiveKit hears the user's microphone right now: shows the user the coach can hear them.
    private(set) var isUserSpeaking = false
    private(set) var framesSent = 0
    private(set) var cuesReceived = 0
    private(set) var reconnects = 0

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
    /// The workout so far, for a session that joins mid-workout; nil when there is none.
    @ObservationIgnored var resumeProvider: (@MainActor () -> CoachResume?)?

    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var settings: AppSettings?
    /// Bumped by every start, stop and retry: a start that resumes after a newer one gives up.
    @ObservationIgnored private var generation = 0
    /// Frames are published one after another, in the order they arrived (M3 trend windows).
    @ObservationIgnored private var sendTail: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private let policy = ReconnectPolicy()
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?

    /// The coach answers this RPC (`server/src/coachw/session.py`). On mobile data the link died
    /// without LiveKit noticing for 30-90 s, and nobody heard the athlete meanwhile (COCH-15):
    /// unanswered pings end the link after about 10 s and the phone rejoins its room.
    static let heartbeatMethod = "coach.ping"
    static let heartbeatInterval: Duration = .seconds(5)
    static let heartbeatTimeout: TimeInterval = 4
    static let heartbeatMisses = 2

    var isActive: Bool {
        switch status {
        case .requestingToken, .connecting, .connected, .reconnecting, .offline: true
        case .idle, .failed: false
        }
    }

    /// The user wants the coach but cannot hear it right now: the phone speaks key cues itself.
    var needsLocalFallback: Bool { isActive && status != .connected }

    @ObservationIgnored private let micMeter = MicMeter()

    func start(settings: AppSettings) async {
        guard !isActive else {
            diag("voice", "start ignored: already \(String(describing: status))")
            return
        }
        AudioManager.shared.remove(localAudioRenderer: micMeter)
        AudioManager.shared.add(localAudioRenderer: micMeter)
        MicMeter.logAudioState("before connect")
        self.settings = settings
        framesSent = 0
        cuesReceived = 0
        reconnects = 0
        retryAttempt = 0
        isMuted = false
        isCoachSpeaking = false
        isUserSpeaking = false
        startPathMonitor()
        await connect()
    }

    func stop() async {
        diag("voice", "stop requested")
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        stopHeartbeat()
        stopPathMonitor()
        let room = self.room
        self.room = nil
        sendTail?.cancel()
        sendTail = nil
        isCoachSpeaking = false
        isUserSpeaking = false
        status = .idle
        await room?.disconnect()
    }

    func toggleMute() async {
        guard status == .connected, let room else { return }
        do {
            try await room.localParticipant.setMicrophone(enabled: isMuted)
            isMuted.toggle()
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

    // MARK: - Connecting

    private func connect() async {
        guard let settings else { return }
        generation += 1
        let attempt = generation
        retryTask?.cancel()
        retryTask = nil
        status = retryAttempt > 0 ? .reconnecting : .requestingToken
        do {
            let grant = try await TokenClient.requestSession(
                baseURL: settings.apiBaseURL, inviteCode: settings.trimmedInviteCode, athleteID: settings.athleteID
            )
            guard attempt == generation else { return }
            if retryAttempt == 0 { status = .connecting }
            let room = Room(delegate: self)
            self.room = room
            try await room.connect(url: grant.serverUrl, token: grant.token)
            // stopped while connecting: stop() already let go of this room, make sure it is closed
            guard attempt == generation else {
                await room.disconnect()
                return
            }
            await listenForTranscripts(in: room)
            try await room.localParticipant.setMicrophone(enabled: !isMuted)
            guard attempt == generation else {
                await room.disconnect()
                return
            }
            if retryAttempt > 0 { reconnects += 1 }
            retryAttempt = 0
            status = .connected
            onConnected?()
            log.info("joined room \(grant.room, privacy: .public)")
            MicMeter.logAudioState("after connect")
            Task {
                try? await Task.sleep(for: .seconds(4))
                MicMeter.logAudioState("4s after connect")
            }
            startHeartbeat(in: room)
            // an agent that is already here gets the workout now; one that joins later on arrival
            if room.remoteParticipants.values.contains(where: { $0.kind == .agent }) { await sendResume() }
        } catch {
            guard attempt == generation else { return }
            log.error("voice start failed: \(error.localizedDescription, privacy: .public)")
            await room?.disconnect()
            room = nil
            if policy.shouldRetry(Self.drop(for: error)) {
                scheduleRetry()
            } else {
                giveUp(error.localizedDescription)
            }
        }
    }

    private func scheduleRetry() {
        let delay = policy.delay(forAttempt: retryAttempt)
        retryAttempt += 1
        status = .offline
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func giveUp(_ message: String) {
        retryTask?.cancel()
        retryTask = nil
        stopHeartbeat()
        stopPathMonitor()
        isCoachSpeaking = false
        isUserSpeaking = false
        status = .failed(message)
    }

    /// The link of a connected session went away.
    private func linkDropped(_ error: LiveKitError?) {
        room = nil
        stopHeartbeat()
        sendTail?.cancel()
        sendTail = nil
        isCoachSpeaking = false
        isUserSpeaking = false
        // the server closed the session on purpose (time cap, removed): do not start a new one
        if let type = error?.type, [.roomDeleted, .participantRemoved, .duplicateIdentity].contains(type) {
            giveUp("教练会话已结束")
            return
        }
        log.info("voice link lost: \(error.map { String(describing: $0.type) } ?? "no error", privacy: .public)")
        onLinkLost?()
        scheduleRetry()
    }

    /// Pings the coach while this room is current. A coach that never answers means the link is
    /// dead even if LiveKit still says connected or reconnecting: drop it and rejoin.
    private func startHeartbeat(in room: Room) {
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
                } catch let error as RpcError where error.code == RpcError.BuiltInError.unsupportedMethod.code {
                    diag("voice", "coach does not answer heartbeats; heartbeat off")
                    return
                } catch is CancellationError {
                    return
                } catch {
                    misses += 1
                    diag("voice", "heartbeat missed (\(misses)): \(error.localizedDescription)")
                    guard misses >= Self.heartbeatMisses, self.isCurrent(id), self.isActive else { continue }
                    diag("voice", "coach unreachable for \(misses) heartbeats; rejoining")
                    self.linkDropped(nil)
                    await room.disconnect()
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
        case TokenError.invalidBaseURL, TokenError.unknownInvite, TokenError.quotaExhausted: .final
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
                guard let self, self.status == .offline else { return }
                log.info("network is back, reconnecting now")
                await self.connect()
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

    private func update(_ state: ConnectionState) {
        switch state {
        case .connected where status == .reconnecting: status = .connected
        case .reconnecting where status == .connected: status = .reconnecting
        default: break
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
            guard self.isCurrent(id) else { return }
            self.update(connectionState)
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        let id = ObjectIdentifier(room)
        Task { @MainActor in
            guard self.isCurrent(id), self.isActive else { return }
            self.linkDropped(error)
        }
    }

    /// The coach left while the phone stayed in the room (its job ended, or the agent server
    /// restarted): nobody would ever answer again, so start a fresh session as after a drop.
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard participant.kind == .agent else { return }
        let id = ObjectIdentifier(room)
        Task { @MainActor in
            guard self.isCurrent(id), self.status == .connected else { return }
            log.info("coach left the room; starting a new session")
            self.linkDropped(nil)
            await room.disconnect()
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
            guard self.isCurrent(id) else { return }
            self.isCoachSpeaking = speaking
            self.isUserSpeaking = userSpeaking
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
