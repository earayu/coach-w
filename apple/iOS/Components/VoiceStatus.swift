import SwiftUI

/// Visual presentation state of the voice coach, decoupled from transport details.
struct VoiceVisualState: Equatable {
    enum Mode: Equatable {
        case idle
        case connecting
        case listening
        case speaking
        case muted
        case reconnecting
        case offline
        case failed(String)
    }

    let mode: Mode
    let isActive: Bool
    let isConnected: Bool
    let isMuted: Bool
    let needsLocalFallback: Bool
    /// The microphone is picking the user up: proof the coach can hear them.
    let isUserSpeaking: Bool

    @MainActor
    init(voice: VoiceSession) {
        self.isUserSpeaking = voice.status == .connected && !voice.isMuted && voice.isUserSpeaking
        self.isActive = voice.isActive
        self.isConnected = voice.status == .connected
        self.isMuted = voice.isMuted
        self.needsLocalFallback = voice.needsLocalFallback

        switch voice.status {
        case .idle:
            self.mode = .idle
        case .requestingToken, .connecting:
            self.mode = .connecting
        case .connected:
            if voice.isMuted {
                self.mode = .muted
            } else if voice.isCoachSpeaking {
                self.mode = .speaking
            } else {
                self.mode = .listening
            }
        case .reconnecting:
            self.mode = .reconnecting
        case .offline:
            self.mode = .offline
        case .failed(let message):
            self.mode = .failed(message)
        }
    }

    init(
        mode: Mode,
        isActive: Bool,
        isConnected: Bool,
        isMuted: Bool,
        needsLocalFallback: Bool,
        isUserSpeaking: Bool = false
    ) {
        self.isUserSpeaking = isUserSpeaking
        self.mode = mode
        self.isActive = isActive
        self.isConnected = isConnected
        self.isMuted = isMuted
        self.needsLocalFallback = needsLocalFallback
    }

    var label: String {
        switch mode {
        case .idle: "教练未连接"
        case .connecting: "正在连接教练"
        case .listening: isUserSpeaking ? "正在听你说" : "教练在线"
        case .speaking: "教练在说话"
        case .muted: "已静音"
        case .reconnecting: "正在重连"
        case .offline: "离线 · 本机播报"
        case .failed: "连接失败"
        }
    }

    /// One line of explanation, only when the state needs one.
    var detail: String? {
        switch mode {
        case .muted: "教练听不到你，但仍会主动提醒"
        case .offline: "网络断开时，关键提醒由手机播报，手表照常震动"
        case .failed(let message): message
        default: nil
        }
    }

    var color: Color {
        switch mode {
        case .speaking, .listening: Theme.accent
        case .connecting, .reconnecting, .offline: Theme.orange
        case .muted: Theme.teal
        case .idle: Theme.tertiaryText
        case .failed: Theme.red
        }
    }
}

/// A small coloured dot and label: the whole voice status at a glance.
struct VoiceStatusLabel: View {
    let voice: VoiceVisualState
    var isConfigured = true

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConfigured || voice.isActive ? voice.color : Theme.orange)
                .frame(width: 8, height: 8)
            Text(isConfigured || voice.isActive ? voice.label : "尚未配置语音服务")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .animation(.easeOut(duration: 0.2), value: voice.mode)
    }
}
