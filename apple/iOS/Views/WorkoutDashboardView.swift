import CoachKit
import SwiftUI

/// During a workout, laid out like the Workout app: time, heart rate, pace and distance stacked
/// in big numerals; the other metrics small underneath; end and pause as two round buttons.
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

    @State private var confirmEnd = false

    private var paused: Bool { !isRunning || frame?.state == .paused }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                staleStreamNotice
                primaryMetrics
                secondaryMetrics
                footnote
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { controls }
        .confirmationDialog("结束本次\(activity.title)？", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("结束并保存", role: .destructive) {
                diag("phone-ui", "end confirmed")
                onEnd()
            }
            Button("继续运动", role: .cancel) { diag("phone-ui", "end cancelled") }
        } message: {
            Text("手表会把这次运动保存到「健康」。")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: activity.symbol)
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                Text(isFinishing ? "正在保存" : paused ? "已暂停" : activity.title)
                    .font(.headline)
                    .foregroundStyle(paused ? Theme.yellow : .white)
                Spacer()
                voiceControls
            }
            if let detail = voice.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var voiceControls: some View {
        if voice.isActive {
            VoiceStatusLabel(voice: voice)
            Menu {
                Button(voice.isMuted ? "取消静音" : "静音", systemImage: voice.isMuted ? "mic.fill" : "mic.slash.fill", action: onToggleMute)
                    .disabled(!voice.isConnected)
                Button("断开语音教练", systemImage: "phone.down.fill", role: .destructive, action: onStopVoice)
            } label: {
                Image(systemName: voice.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(voice.isMuted ? Theme.teal : .white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.14), in: Circle())
            } primaryAction: {
                onToggleMute()
            }
            .accessibilityLabel(voice.isMuted ? "取消静音" : "静音")
        } else if isConfigured {
            Button("连接教练", action: onConnectVoice)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
        } else {
            Button("设置教练", action: onOpenSettings)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.orange)
        }
    }

    /// Shown when the workout runs but the watch has stopped sending frames: the numbers on screen
    /// are old, and the coach does not get new ones either.
    private var staleStreamNotice: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if isRunning, let frame, frame.isStale(at: context.date) {
                Label(
                    "手表数据已中断 \(Int(frame.silence(at: context.date) ?? 0)) 秒，抬腕打开手表上的 coach-w 可恢复",
                    systemImage: "applewatch.slash"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.orange)
            }
        }
    }

    // MARK: - Metrics

    private var primaryMetrics: some View {
        let bpm = frame?.hrBpm
        let zone = HeartRateZone.zone(for: bpm)
        return VStack(alignment: .leading, spacing: 2) {
            // ticks on the phone between frames, so the clock never freezes on a stalled stream
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Format.duration(isRunning ? frame?.elapsed(at: context.date) : frame?.elapsedS))
                    .font(Theme.numeral(76))
                    .foregroundStyle(Theme.time)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MetricLine(value: Format.number(bpm), unit: "BPM", unitColor: Theme.heart, size: 52, hasValue: bpm != nil)
                Image(systemName: "heart.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.heart)
                if let zone {
                    Text(zone.badge)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(zone.color)
                }
            }

            MetricLine(
                value: Format.primarySpeedNumber(frame?.speedMps, readsAsPace: activity.readsSpeedAsPace),
                unit: activity.speedUnit,
                unitColor: Theme.pace,
                size: 52,
                hasValue: frame?.speedMps != nil
            )

            MetricLine(
                value: Format.distanceNumber(frame?.distanceM),
                unit: "KM",
                unitColor: Theme.accent,
                size: 52,
                hasValue: frame?.distanceM != nil
            )
        }
    }

    /// Only the metrics this workout actually reports; nothing is shown as an empty tile.
    @ViewBuilder
    private var secondaryMetrics: some View {
        let items = secondaryItems
        if !items.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 14) {
                ForEach(items, id: \.title) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                        MetricLine(value: item.value, unit: item.unit, unitColor: Theme.secondaryText, size: 24)
                    }
                }
            }
            .padding(.top, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5)
            }
        }
    }

    private var secondaryItems: [(title: String, value: String, unit: String)] {
        guard let frame else { return [] }
        let all: [(String, Double?, String, Int)] = [
            (activity.cadenceTitle, frame.cadenceSpm, activity.cadenceUnit, 0),
            ("功率", frame.powerW, "W", 0),
            ("活动能量", frame.energyKcal, "kcal", 0),
            ("步幅", frame.strideM, "m", 2),
            ("触地时间", frame.gctMs, "ms", 0),
            ("垂直振幅", frame.voCm, "cm", 1),
        ]
        return all.compactMap { title, value, unit, digits in
            value.map { (title, Format.number($0, digits: digits), unit) }
        }
    }

    /// The watch stream in one quiet line, for when the numbers look wrong (docs/spec.md 6.2).
    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(Theme.orange)
            }
            if stats.received > 0 {
                Text(streamSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    private var streamSummary: String {
        var parts = ["手表数据 \(stats.received) 帧"]
        if let interval = stats.meanInterval { parts.append(String(format: "间隔 %.2fs", interval)) }
        if let delay = stats.lastDelayMs { parts.append("延迟 \(delay) ms") }
        if stats.missing > 0 { parts.append("丢 \(stats.missing)") }
        if stats.outOfOrder > 0 { parts.append("乱序 \(stats.outOfOrder)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 56) {
            RoundControl(symbol: "xmark", title: "结束", color: Theme.red) {
                diag("phone-ui", "end tapped")
                confirmEnd = true
            }
            RoundControl(
                symbol: isFinishing ? "hourglass" : isRunning ? "pause.fill" : "arrow.clockwise",
                title: isFinishing ? "正在保存" : isRunning ? "暂停" : "继续",
                color: isRunning || isFinishing ? Theme.yellow : Theme.accent
            ) {
                diag("phone-ui", "\(isRunning ? "pause" : "resume") tapped")
                (isRunning ? onPause : onResume)()
            }
            .disabled(isFinishing)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.canvas)
    }
}

/// The Workout app's control: a tinted circle with a symbol, and a caption under it.
private struct RoundControl: View {
    let symbol: String
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 72, height: 72)
                    .background(color.opacity(0.22), in: Circle())
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}
