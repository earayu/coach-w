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

    @ObservationIgnored private var room: Room?

    var isActive: Bool {
        switch status {
        case .requestingToken, .connecting, .connected, .reconnecting: true
        case .idle, .failed: false
        }
    }

    func start(settings: AppSettings) async {
        guard !isActive else { return }
        framesSent = 0
        isMuted = false
        status = .requestingToken
        do {
            let grant = try await TokenClient.requestSession(
                baseURL: settings.apiBaseURL, inviteCode: settings.inviteCode, athleteID: settings.athleteID
            )
            status = .connecting
            let room = Room(delegate: self)
            self.room = room
            try await room.connect(url: grant.serverUrl, token: grant.token)
            try await room.localParticipant.setMicrophone(enabled: true)
            status = .connected
            log.info("joined room \(grant.room, privacy: .public)")
        } catch {
            log.error("voice start failed: \(error.localizedDescription, privacy: .public)")
            await room?.disconnect()
            room = nil
            status = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        let room = self.room
        self.room = nil
        status = .idle
        await room?.disconnect()
    }

    func toggleMute() async {
        guard let room else { return }
        do {
            try await room.localParticipant.setMicrophone(enabled: isMuted)
            isMuted.toggle()
        } catch {
            log.error("mute toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forwards metrics frames to the coach agent on the `coach.metrics` topic (spec 6.4).
    func send(_ frames: [MetricsFrame]) {
        guard status == .connected, let room else { return }
        let options = DataPublishOptions(topic: "coach.metrics", reliable: true)
        for frame in frames {
            guard let data = try? frame.encoded() else { continue }
            Task {
                do {
                    try await room.localParticipant.publish(data: data, options: options)
                    self.framesSent += 1
                } catch {
                    log.error("publish frame \(frame.seq) failed: \(error.localizedDescription, privacy: .public)")
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
}

extension VoiceSession: RoomDelegate {
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor in self.update(connectionState) }
    }
}
