import CoachKit
import Foundation
import LiveKit
import Observation
import os

private let log = Logger(subsystem: "com.earayu.coachw", category: "voice")

/// The voice link to the coach: one LiveKit room per session (spec 7.1).
///
/// The only file that imports LiveKit. LiveKit's automatic audio session setup
/// uses `.playAndRecord` with Bluetooth HFP/A2DP, which is what the headphones need.
@MainActor
@Observable
final class VoiceSession: NSObject {
    static let shared = VoiceSession()

    enum Status: Equatable {
        case idle
        case requestingToken
        case connecting
        case connected
        case reconnecting
        case failed(String)

        var title: String {
            switch self {
            case .idle: "未连接"
            case .requestingToken: "获取通行证…"
            case .connecting: "连接中…"
            case .connected: "已连接教练"
            case .reconnecting: "重新连接中…"
            case .failed(let message): "连接失败：\(message)"
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var isMuted = false
    private(set) var framesSent = 0
    private(set) var cuesReceived = 0

    /// Called with each coach cue from the agent that has not expired, e.g. to forward it to the watch.
    @ObservationIgnored var onCue: (@MainActor (CoachCue) -> Void)?

    @ObservationIgnored private var room: Room?
    /// Bumped by every start and stop: a start that resumes after a newer stop/start gives up.
    @ObservationIgnored private var generation = 0
    /// Frames are published one after another, in the order they arrived (M3 trend windows).
    @ObservationIgnored private var sendTail: Task<Void, Never>?

    var isActive: Bool {
        switch status {
        case .requestingToken, .connecting, .connected, .reconnecting: true
        case .idle, .failed: false
        }
    }

    func start(settings: AppSettings) async {
        guard !isActive else { return }
        generation += 1
        let attempt = generation
        framesSent = 0
        cuesReceived = 0
        isMuted = false
        status = .requestingToken
        do {
            let grant = try await TokenClient.requestSession(
                baseURL: settings.apiBaseURL, inviteCode: settings.trimmedInviteCode, athleteID: settings.athleteID
            )
            guard attempt == generation else { return }
            status = .connecting
            let room = Room(delegate: self)
            self.room = room
            try await room.connect(url: grant.serverUrl, token: grant.token)
            // stopped while connecting: stop() already let go of this room, make sure it is closed
            guard attempt == generation else {
                await room.disconnect()
                return
            }
            try await room.localParticipant.setMicrophone(enabled: true)
            guard attempt == generation else {
                await room.disconnect()
                return
            }
            status = .connected
            log.info("joined room \(grant.room, privacy: .public)")
        } catch {
            guard attempt == generation else { return }
            log.error("voice start failed: \(error.localizedDescription, privacy: .public)")
            await room?.disconnect()
            room = nil
            status = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        generation += 1
        let room = self.room
        self.room = nil
        sendTail?.cancel()
        sendTail = nil
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

    private func update(_ state: ConnectionState) {
        switch state {
        case .connected: status = .connected
        case .reconnecting: status = .reconnecting
        case .disconnected where isActive:
            room = nil
            status = .failed("连接已断开")
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

extension VoiceSession: RoomDelegate {
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        let id = ObjectIdentifier(room)
        Task { @MainActor in
            guard self.isCurrent(id) else { return }
            self.update(connectionState)
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
