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
    let framesSent: Int
    let cuesReceived: Int
    let reconnects: Int
    /// The microphone is picking the user up: proof the coach can hear them.
    let isUserSpeaking: Bool

    @MainActor
    init(voice: VoiceSession) {
        self.isUserSpeaking = voice.status == .connected && !voice.isMuted && voice.isUserSpeaking
        self.isActive = voice.isActive
        self.isConnected = voice.status == .connected
        self.isMuted = voice.isMuted
        self.needsLocalFallback = voice.needsLocalFallback
        self.framesSent = voice.framesSent
        self.cuesReceived = voice.cuesReceived
        self.reconnects = voice.reconnects

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
        framesSent: Int,
        cuesReceived: Int,
        reconnects: Int,
        isUserSpeaking: Bool = false
    ) {
        self.isUserSpeaking = isUserSpeaking
        self.mode = mode
        self.isActive = isActive
        self.isConnected = isConnected
        self.isMuted = isMuted
        self.needsLocalFallback = needsLocalFallback
        self.framesSent = framesSent
        self.cuesReceived = cuesReceived
        self.reconnects = reconnects
    }

    var shortLabel: String {
        switch mode {
        case .idle: "教练未连接"
        case .connecting: "正在连接教练…"
        case .listening: "教练在线 · 聆听中"
        case .speaking: "教练说话中"
        case .muted: "教练在线 · 已静音"
        case .reconnecting: "语音重连中…"
        case .offline: "离线 · 本机播报中"
        case .failed: "语音连接失败"
        }
    }

    var detailLabel: String {
        switch mode {
        case .idle: "戴上耳机一键连线，运动时随时开口对话"
        case .connecting: "正在向服务器申请实时语音通道…"
        case .listening: "实时双工通道已就绪，随时开口即可对话"
        case .speaking: "正在播报运动建议，开口即可随时打断"
        case .muted: "麦克风已静音，教练仍会按指标主动提醒"
        case .reconnecting: "网络波动，正在自动恢复实时语音通道"
        case .offline: "网络暂时断开，关键提醒由本机播报，手表照常震动"
        case .failed(let message): message
        }
    }

    var accentColor: Color {
        switch mode {
        case .speaking: PulseTheme.volt
        case .listening: PulseTheme.mint
        case .connecting, .reconnecting, .offline: PulseTheme.amber
        case .muted: PulseTheme.sky
        case .idle: PulseTheme.textSecondary
        case .failed: PulseTheme.coral
        }
    }

    var isAnimated: Bool {
        switch mode {
        case .speaking, .listening, .connecting, .reconnecting, .offline: true
        case .idle, .muted, .failed: false
        }
    }
}

/// Animated acoustic waveform reacting to voice session state.
struct VoiceWaveView: View {
    let state: VoiceVisualState
    var barCount: Int = 5
    var maxHeight: CGFloat = 24

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !state.isAnimated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(barFill)
                        .frame(width: 3.5, height: barHeight(index: index, time: t))
                }
            }
            .frame(height: maxHeight)
        }
    }

    private var barFill: AnyShapeStyle {
        switch state.mode {
        case .speaking, .listening:
            AnyShapeStyle(PulseTheme.pulseGradient)
        case .connecting, .reconnecting, .offline:
            AnyShapeStyle(PulseTheme.amber)
        case .muted:
            AnyShapeStyle(PulseTheme.sky.opacity(0.6))
        case .failed:
            AnyShapeStyle(PulseTheme.coral.opacity(0.75))
        case .idle:
            AnyShapeStyle(PulseTheme.textTertiary.opacity(0.65))
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let center = Double(barCount - 1) / 2.0
        let envelope = 1.0 - abs(Double(index) - center) / max(center + 0.6, 1.0) * 0.45

        let fraction: Double
        switch state.mode {
        case .speaking:
            let wave = 0.5 + 0.5 * sin(time * 7.5 + Double(index) * 1.15)
            fraction = (0.30 + 0.70 * wave) * envelope
        case .listening:
            let wave = 0.5 + 0.5 * sin(time * 2.8 + Double(index) * 0.85)
            fraction = (0.24 + 0.44 * wave) * envelope
        case .connecting, .reconnecting:
            let wave = 0.5 + 0.5 * sin(time * 4.2 - Double(index) * 0.9)
            fraction = 0.22 + 0.52 * wave
        case .offline:
            let wave = 0.5 + 0.5 * sin(time * 2.0 + Double(index) * 0.5)
            fraction = 0.20 + 0.30 * wave
        case .muted:
            fraction = 0.18
        case .failed:
            fraction = 0.22
        case .idle:
            fraction = 0.20 + 0.24 * envelope
        }
        return max(4, maxHeight * fraction)
    }
}

/// Status pill displayed under the Pulse W brand mark in the lobby.
struct CoachStatusPill: View {
    let voice: VoiceVisualState
    let isConfigured: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .shadow(color: dotColor.opacity(0.65), radius: 5)
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PulseTheme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background {
            Capsule()
                .fill(PulseTheme.surfaceElevated.opacity(0.9))
                .overlay(Capsule().strokeBorder(dotColor.opacity(0.32), lineWidth: 1))
        }
    }

    private var dotColor: Color {
        if !isConfigured && !voice.isActive { return PulseTheme.amber }
        return voice.accentColor
    }

    private var label: String {
        if !isConfigured && !voice.isActive { return "尚未配置语音服务" }
        return voice.shortLabel
    }
}

/// Five-segment heart rate zone bar with a glowing current-bpm marker.
struct HeartRateZoneBar: View {
    let bpm: Double?
    let activeZone: HeartRateZone?

    var body: some View {
        GeometryReader { geo in
            let progress = HeartRateZone.progress(for: bpm)
            ZStack(alignment: .leading) {
                HStack(spacing: 4) {
                    ForEach(HeartRateZone.allCases, id: \.self) { zone in
                        let isCurrent = zone == activeZone
                        Capsule()
                            .fill(zone.color.opacity(isCurrent ? 1.0 : 0.24))
                            .frame(height: isCurrent ? 8 : 6)
                            .shadow(color: isCurrent ? zone.color.opacity(0.55) : .clear, radius: 6)
                    }
                }

                if bpm != nil {
                    Circle()
                        .fill(PulseTheme.textPrimary)
                        .frame(width: 13, height: 13)
                        .overlay(
                            Circle()
                                .strokeBorder(activeZone?.color ?? PulseTheme.mint, lineWidth: 2.5)
                        )
                        .shadow(color: (activeZone?.color ?? PulseTheme.mint).opacity(0.75), radius: 6)
                        .offset(x: max(0, min(geo.size.width - 13, geo.size.width * progress - 6.5)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 16)
    }
}

/// Subtle breathing status dot for live workout indicators.
struct LivePulseDot: View {
    let color: Color
    var animated: Bool = true
    @State private var expanded = false

    var body: some View {
        ZStack {
            if animated {
                Circle()
                    .fill(color.opacity(expanded ? 0 : 0.42))
                    .frame(width: 14, height: 14)
                    .scaleEffect(expanded ? 1.4 : 0.7)
            }
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                expanded = true
            }
        }
    }
}

/// Signature full-width Volt-to-Mint primary CTA button.
struct PulsePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .foregroundStyle(PulseTheme.obsidianMid)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(PulseTheme.pulseHorizontal)
                    .shadow(color: PulseTheme.volt.opacity(configuration.isPressed ? 0.14 : 0.30), radius: 16, y: 6)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Tactile dark glass pill button for secondary and control actions.
struct PulseGlassButtonStyle: ButtonStyle {
    var tint: Color = PulseTheme.textPrimary
    var fill: Color = PulseTheme.surfaceElevated

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background {
                Capsule()
                    .fill(fill.opacity(configuration.isPressed ? 0.75 : 1.0))
                    .overlay(Capsule().strokeBorder(tint.opacity(0.24), lineWidth: 1))
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
