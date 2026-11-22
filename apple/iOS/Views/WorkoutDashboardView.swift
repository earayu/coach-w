import CoachKit
import SwiftUI

/// Active workout dashboard: live voice bar, peripheral-vision hero metrics, HR zone card,
/// adaptive 2-column telemetry grid, collapsible stream diagnostics, and protected controls.
struct WorkoutDashboardView: View {
    let activity: WorkoutActivity
    let frame: MetricsFrame?
    let stats: FrameStats
    let isRunning: Bool
    /// The watch stopped the workout and is saving it: pause / resume no longer apply.
    var isFinishing = false
    let voice: VoiceVisualState
    let isConfigured: Bool
    let lastError: String?
    let onPause: () -> Void
    let onResume: () -> Void
    let onEnd: () -> Void
    let onConnectVoice: () -> Void
    let onToggleMute: () -> Void
    let onStopVoice: () -> Void
    let onOpenSettings: () -> Void

    @State private var showStreamDiagnostics = false
    @State private var confirmEnd = false
    @State private var heartbeatPulse = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                voiceStatusBar
                staleStreamBanner
                heroCard
                heartRateCard
                secondaryMetricsGrid
                streamHealthDrawer

                if let error = lastError {
                    errorCard(error)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 108)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            controlDock
        }
        .confirmationDialog("结束本次\(activity.title)？", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("结束并保存记录", role: .destructive) {
                diag("phone-ui", "end confirmed")
                onEnd()
            }
            Button("继续运动", role: .cancel) { diag("phone-ui", "end cancelled") }
        } message: {
            Text("手表将保存本次运动到 Apple 健康，本机同步生成跑后总结。")
        }
    }

    // MARK: - Top Voice Coach Status Bar

    private var voiceStatusBar: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(voice.accentColor.opacity(0.16))
                    .frame(width: 40, height: 40)
                VoiceWaveView(state: voice, barCount: 5, maxHeight: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.shortLabel)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(PulseTheme.textPrimary)
                    .lineLimit(1)
                Text(voiceSubline)
                    .font(.caption2)
                    .foregroundStyle(voice.needsLocalFallback ? PulseTheme.amber : PulseTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if voice.isActive {
                HStack(spacing: 8) {
                    Button(action: onToggleMute) {
                        Image(systemName: voice.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(voice.isMuted ? PulseTheme.sky : PulseTheme.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(
                                (voice.isMuted ? PulseTheme.sky.opacity(0.20) : PulseTheme.surfaceElevated),
                                in: Circle()
                            )
                    }
                    .disabled(!voice.isConnected)
                    .opacity(voice.isConnected ? 1 : 0.4)
                    .accessibilityLabel(voice.isMuted ? "取消静音" : "静音")

                    Button(action: onStopVoice) {
                        Image(systemName: "phone.down.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(PulseTheme.coral)
                            .frame(width: 36, height: 36)
                            .background(PulseTheme.coral.opacity(0.18), in: Circle())
                    }
                    .accessibilityLabel("结束语音")
                }
            } else if isConfigured {
                Button("连接", action: onConnectVoice)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PulseTheme.obsidianMid)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(PulseTheme.pulseHorizontal, in: Capsule())
            } else {
                Button("去设置", action: onOpenSettings)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PulseTheme.amber)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(PulseTheme.amber.opacity(0.16), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .pulseCard(highlighted: voice.mode == .speaking, cornerRadius: 18)
    }

    private var voiceSubline: String {
        if voice.needsLocalFallback {
            return "本机自动播报关键节点 · 手表照常震动"
        }
        if voice.isUserSpeaking {
            return "听到你在说话…"
        }
        if voice.isConnected {
            return "已发送 \(voice.framesSent) 帧 · 手表提醒 \(voice.cuesReceived) 条"
        }
        return isConfigured ? "随时可连线实时语音教练" : "未配置服务器与邀请码"
    }

    // MARK: - Stalled Watch Stream

    /// Shown when the workout runs but the watch has stopped sending frames: the numbers on screen
    /// are old, and the coach does not get new ones either.
    private var staleStreamBanner: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if isRunning, let frame, frame.isStale(at: context.date) {
                HStack(spacing: 10) {
                    Image(systemName: "applewatch.slash")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(PulseTheme.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("手表数据已中断 \(Int(frame.silence(at: context.date) ?? 0)) 秒")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(PulseTheme.textPrimary)
                        Text("心率、距离停在最后一次收到的值。抬腕打开手表上的 coach-w 可恢复。")
                            .font(.caption2)
                            .foregroundStyle(PulseTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(PulseTheme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: - Core Hero Card

    private var heroCard: some View {
        let paused = !isRunning || frame?.state == .paused
        return VStack(spacing: 18) {
            HStack {
                HStack(spacing: 6) {
                    LivePulseDot(color: paused ? PulseTheme.amber : PulseTheme.mint, animated: !paused)
                    Image(systemName: activity.symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PulseTheme.volt)
                    Text(paused ? "\(activity.title) · 已暂停" : "\(activity.title) · 进行中")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(paused ? PulseTheme.amber : PulseTheme.textPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(PulseTheme.obsidianMid.opacity(0.65), in: Capsule())

                Spacer()

                gpsBadge
            }

            VStack(spacing: 4) {
                Text(activity.speedTitle)
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(PulseTheme.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.primarySpeedNumber(frame?.speedMps, readsAsPace: activity.readsSpeedAsPace))
                        .font(.system(size: 62, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(
                            frame?.speedMps != nil
                                ? AnyShapeStyle(PulseTheme.pulseGradient)
                                : AnyShapeStyle(PulseTheme.textTertiary)
                        )
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)

                    Text(activity.speedUnit)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(PulseTheme.textSecondary)
                }
            }
            .padding(.vertical, 4)

            HStack(spacing: 0) {
                // ticks on the phone between frames, so the clock never freezes on a stalled stream
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    heroSubMetric(
                        title: "时长",
                        value: Format.duration(isRunning ? frame?.elapsed(at: context.date) : frame?.elapsedS),
                        unit: nil,
                        hasValue: frame != nil
                    )
                }
                Rectangle()
                    .fill(PulseTheme.surfaceStroke)
                    .frame(width: 1, height: 38)
                heroSubMetric(
                    title: "距离",
                    value: Format.distanceNumber(frame?.distanceM),
                    unit: "km",
                    hasValue: frame?.distanceM != nil
                )
            }
            .padding(.vertical, 12)
            .background(PulseTheme.obsidianMid.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(18)
        .pulseCard(highlighted: !paused, cornerRadius: 24)
    }

    private var gpsBadge: some View {
        let locked = frame?.lat != nil
        return HStack(spacing: 5) {
            Image(systemName: locked ? "location.fill" : "location.slash")
                .font(.caption2.weight(.bold))
            if let alt = frame?.altM {
                Text(locked ? "GPS · \(Format.number(alt)) m" : "\(Format.number(alt)) m")
            } else {
                Text(locked ? "GPS 已定位" : "GPS 等待")
            }
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(locked ? PulseTheme.mint : PulseTheme.textTertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            (locked ? PulseTheme.mint.opacity(0.14) : PulseTheme.obsidianMid.opacity(0.55)),
            in: Capsule()
        )
    }

    private func heroSubMetric(title: String, value: String, unit: String?, hasValue: Bool) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(PulseTheme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(hasValue ? PulseTheme.textPrimary : PulseTheme.textTertiary)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PulseTheme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Heart Rate Zone Card

    private var heartRateCard: some View {
        let bpm = frame?.hrBpm
        let zone = HeartRateZone.zone(for: bpm)
        let accent = zone?.color ?? PulseTheme.coral

        return VStack(spacing: 14) {
            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "heart.fill")
                        .font(.title2)
                        .foregroundStyle(bpm != nil ? accent : PulseTheme.textTertiary)
                        .scaleEffect(bpm != nil && heartbeatPulse ? 1.15 : 0.94)
                        .shadow(color: bpm != nil ? accent.opacity(0.45) : .clear, radius: 6)

                    Text(Format.number(bpm))
                        .font(.system(size: 46, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(bpm != nil ? PulseTheme.textPrimary : PulseTheme.textTertiary)

                    Text("bpm")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PulseTheme.textSecondary)
                }

                Spacer()

                if let zone {
                    Text(zone.badge)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PulseTheme.obsidianMid)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(zone.color, in: Capsule())
                        .shadow(color: zone.color.opacity(0.35), radius: 8)
                } else {
                    Text("等待心率")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PulseTheme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(PulseTheme.obsidianMid.opacity(0.6), in: Capsule())
                }
            }

            HeartRateZoneBar(bpm: bpm, activeZone: zone)

            HStack {
                ForEach(HeartRateZone.allCases, id: \.self) { band in
                    Text("\(band.code) \(band.title)")
                        .font(.system(size: 10, weight: band == zone ? .bold : .medium))
                        .foregroundStyle(band == zone ? band.color : PulseTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .pulseCard(cornerRadius: 22)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                heartbeatPulse = true
            }
        }
    }

    // MARK: - Secondary Metrics Grid (2 Columns)

    private var secondaryMetricsGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            SecondaryMetricTile(
                title: activity.cadenceTitle,
                symbol: "metronome.fill",
                value: Format.number(frame?.cadenceSpm),
                unit: activity.cadenceUnit,
                hasValue: frame?.cadenceSpm != nil
            )
            SecondaryMetricTile(
                title: "功率",
                symbol: "bolt.fill",
                value: Format.number(frame?.powerW),
                unit: "W",
                hasValue: frame?.powerW != nil
            )
            SecondaryMetricTile(
                title: "步幅",
                symbol: "ruler.fill",
                value: Format.number(frame?.strideM, digits: 2),
                unit: "m",
                hasValue: frame?.strideM != nil
            )
            SecondaryMetricTile(
                title: "触地时间",
                symbol: "shoeprints.fill",
                value: Format.number(frame?.gctMs),
                unit: "ms",
                hasValue: frame?.gctMs != nil
            )
            SecondaryMetricTile(
                title: "垂直振幅",
                symbol: "arrow.up.and.down",
                value: Format.number(frame?.voCm, digits: 1),
                unit: "cm",
                hasValue: frame?.voCm != nil
            )
            SecondaryMetricTile(
                title: "活动能量",
                symbol: "flame.fill",
                value: Format.number(frame?.energyKcal),
                unit: "kcal",
                hasValue: frame?.energyKcal != nil
            )
        }
    }

    // MARK: - Collapsible Stream Health Drawer

    private var streamHealthDrawer: some View {
        let healthy = stats.received > 0 && stats.missing == 0 && stats.outOfOrder == 0
        let dotColor: Color = stats.received == 0 ? PulseTheme.textTertiary : (healthy ? PulseTheme.mint : PulseTheme.amber)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.28)) {
                    showStreamDiagnostics.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: dotColor.opacity(0.6), radius: 4)
                    Text(stats.received == 0 ? "等待手表数据流" : (healthy ? "手表数据流健康" : "手表数据流有波动"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PulseTheme.textPrimary)
                    Spacer()
                    if let delay = stats.lastDelayMs {
                        Text("\(delay) ms")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(dotColor)
                    }
                    Text("· \(stats.received) 帧")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PulseTheme.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PulseTheme.textTertiary)
                        .rotationEffect(.degrees(showStreamDiagnostics ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if showStreamDiagnostics {
                Divider().overlay(PulseTheme.surfaceStroke)
                HStack(spacing: 8) {
                    diagnosticPill("收帧", "\(stats.received)")
                    diagnosticPill("丢帧", "\(stats.missing)", warn: stats.missing > 0)
                    diagnosticPill("乱序", "\(stats.outOfOrder)", warn: stats.outOfOrder > 0)
                    diagnosticPill("间隔", stats.meanInterval.map { String(format: "%.2fs", $0) } ?? Format.dash)
                }
                .padding(12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .pulseCard(muted: true, cornerRadius: 16)
    }

    private func diagnosticPill(_ title: String, _ value: String, warn: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(PulseTheme.textTertiary)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(warn ? PulseTheme.amber : PulseTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(PulseTheme.obsidianMid.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func errorCard(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PulseTheme.coral)
            Text(error)
                .font(.caption)
                .foregroundStyle(PulseTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(PulseTheme.coral.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Bottom Control Dock

    private var controlDock: some View {
        HStack(spacing: 12) {
            Button {
                diag("phone-ui", "\(isRunning ? "pause" : "resume") tapped")
                (isRunning ? onPause : onResume)()
            } label: {
                Label(
                    isFinishing ? "正在保存…" : isRunning ? "暂停运动" : "继续运动",
                    systemImage: isFinishing ? "hourglass" : isRunning ? "pause.fill" : "play.fill"
                )
                .font(.headline.weight(.bold))
                .foregroundStyle(isRunning ? PulseTheme.amber : PulseTheme.obsidianMid)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background {
                    if isRunning {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(PulseTheme.obsidianTop)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(PulseTheme.amber.opacity(0.18))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(PulseTheme.amber.opacity(0.50), lineWidth: 1.2)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(PulseTheme.pulseHorizontal)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isFinishing)

            Button {
                diag("phone-ui", "end tapped")
                confirmEnd = true
            } label: {
                Label("结束", systemImage: "stop.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(PulseTheme.coral)
                    .frame(width: 112)
                    .padding(.vertical, 15)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(PulseTheme.obsidianTop)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(PulseTheme.coral.opacity(0.18))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(PulseTheme.coral.opacity(0.50), lineWidth: 1.2)
                            )
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background {
            Rectangle()
                .fill(PulseTheme.obsidianBottom)
                .overlay(alignment: .top) {
                    Rectangle().fill(PulseTheme.surfaceStroke).frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

private struct SecondaryMetricTile: View {
    let title: String
    let symbol: String
    let value: String
    let unit: String
    let hasValue: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(hasValue ? PulseTheme.mint : PulseTheme.textTertiary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(hasValue ? PulseTheme.textSecondary : PulseTheme.textTertiary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(hasValue ? PulseTheme.textPrimary : PulseTheme.textTertiary)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Text(unit)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PulseTheme.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pulseCard(muted: !hasValue, cornerRadius: 18)
        .opacity(hasValue ? 1.0 : 0.72)
    }
}
