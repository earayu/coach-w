import CoachKit
import SwiftUI

/// Pre-workout Pulse W lobby: activity selection, watch launch CTA, voice coach card, and recent summary.
struct LobbyView: View {
    @Binding var selectedActivity: WorkoutActivity
    let voice: VoiceVisualState
    let isConfigured: Bool
    let lastRecord: WorkoutRecord?
    let lastError: String?
    var isStartingWatch = false
    let onStartWatch: () -> Void
    let onConnectVoice: () -> Void
    let onToggleMute: () -> Void
    let onStopVoice: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                brandHeader
                activitySelector
                primaryActionSection
                voiceCoachCard

                if let record = lastRecord {
                    recentWorkoutSection(record)
                }

                if let error = lastError {
                    errorBanner(error)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var brandHeader: some View {
        VStack(spacing: 10) {
            PulseWMark(size: 74, showRings: true, breathing: true)
            VStack(spacing: 4) {
                Text("COACH W")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(PulseTheme.textPrimary)
                Text("实时语音运动教练")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PulseTheme.textSecondary)
            }
            CoachStatusPill(voice: voice, isConfigured: isConfigured)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var activitySelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择运动")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PulseTheme.textSecondary)
                Spacer()
                Text(selectedActivity.subtitle)
                    .font(.caption)
                    .foregroundStyle(PulseTheme.mint)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(WorkoutActivity.allCases) { activity in
                        ActivityCard(
                            activity: activity,
                            isSelected: activity == selectedActivity
                        ) {
                            withAnimation(.spring(duration: 0.25)) {
                                selectedActivity = activity
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var primaryActionSection: some View {
        VStack(spacing: 10) {
            Button {
                diag("phone-ui", "start on watch tapped: \(selectedActivity.wireName)")
                onStartWatch()
            } label: {
                HStack(spacing: 10) {
                    if isStartingWatch {
                        ProgressView().tint(PulseTheme.obsidianMid)
                        Text("正在启动手表 · \(selectedActivity.title)")
                    } else {
                        Image(systemName: "applewatch.radiowaves.left.and.right")
                            .font(.title3.weight(.bold))
                        Text("在手表上开始 · \(selectedActivity.title)")
                    }
                }
            }
            .buttonStyle(PulsePrimaryButtonStyle())
            .disabled(isStartingWatch)

            Text("Apple Watch 采集与保存运动，iPhone 实时显示并驱动语音教练")
                .font(.caption)
                .foregroundStyle(PulseTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var voiceCoachCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(voice.accentColor.opacity(0.14))
                        .frame(width: 48, height: 48)
                    VoiceWaveView(state: voice, barCount: 5, maxHeight: 22)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("实时语音教练")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(PulseTheme.textPrimary)
                        if voice.isConnected {
                            Text("LIVE")
                                .font(.caption2.weight(.black))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(PulseTheme.mint.opacity(0.22), in: Capsule())
                                .foregroundStyle(PulseTheme.mint)
                        }
                    }
                    Text(isConfigured || voice.isActive ? voice.detailLabel : "先填写服务器地址与邀请码，即可开启实时双工语音陪练")
                        .font(.caption)
                        .foregroundStyle(PulseTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if voice.framesSent > 0 || voice.cuesReceived > 0 || voice.reconnects > 0 {
                HStack(spacing: 10) {
                    voiceStatChip(title: "同步帧", value: "\(voice.framesSent)")
                    voiceStatChip(title: "手表提醒", value: "\(voice.cuesReceived)")
                    if voice.reconnects > 0 {
                        voiceStatChip(title: "自动重连", value: "\(voice.reconnects)")
                    }
                }
            }

            if voice.needsLocalFallback {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PulseTheme.amber)
                    Text("教练暂时离线：超心率、整公里与结束提醒将由手机本地播报，手表照常震动。")
                        .font(.caption)
                        .foregroundStyle(PulseTheme.amber.opacity(0.95))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PulseTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 10) {
                if voice.isActive {
                    Button(action: onToggleMute) {
                        Label(
                            voice.isMuted ? "取消静音" : "静音",
                            systemImage: voice.isMuted ? "mic.slash.fill" : "mic.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(
                        PulseGlassButtonStyle(
                            tint: voice.isMuted ? PulseTheme.sky : PulseTheme.textPrimary,
                            fill: voice.isMuted ? PulseTheme.sky.opacity(0.16) : PulseTheme.surfaceElevated
                        )
                    )
                    .disabled(!voice.isConnected)
                    .opacity(voice.isConnected ? 1 : 0.45)

                    Button(action: onStopVoice) {
                        Label("结束语音", systemImage: "phone.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(
                        PulseGlassButtonStyle(
                            tint: PulseTheme.coral,
                            fill: PulseTheme.coral.opacity(0.15)
                        )
                    )
                } else if isConfigured {
                    Button(action: onConnectVoice) {
                        Label("连接语音教练", systemImage: "waveform")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(
                        PulseGlassButtonStyle(
                            tint: PulseTheme.volt,
                            fill: PulseTheme.volt.opacity(0.14)
                        )
                    )
                } else {
                    Button(action: onOpenSettings) {
                        Label("前往设置填写邀请码与服务器", systemImage: "gearshape.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(
                        PulseGlassButtonStyle(
                            tint: PulseTheme.amber,
                            fill: PulseTheme.amber.opacity(0.14)
                        )
                    )
                }
            }
        }
        .padding(16)
        .pulseCard(highlighted: voice.isConnected, cornerRadius: 22)
    }

    private func voiceStatChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(PulseTheme.textTertiary)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(PulseTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(PulseTheme.obsidianMid.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func recentWorkoutSection(_ record: WorkoutRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("刚刚完成")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PulseTheme.textSecondary)
                Spacer()
                Text("查看跑后总结")
                    .font(.caption)
                    .foregroundStyle(PulseTheme.mint)
            }

            NavigationLink {
                RecordDetailView(record: record)
            } label: {
                RecordSummaryCard(record: record, highlighted: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PulseTheme.coral)
            Text(error)
                .font(.footnote)
                .foregroundStyle(PulseTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(PulseTheme.coral.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PulseTheme.coral.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct ActivityCard: View {
    let activity: WorkoutActivity
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                isSelected
                                    ? AnyShapeStyle(PulseTheme.pulseGradient)
                                    : AnyShapeStyle(PulseTheme.surfaceElevated)
                            )
                            .frame(width: 40, height: 40)
                        Image(systemName: activity.symbol)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(isSelected ? PulseTheme.obsidianMid : PulseTheme.mint)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(PulseTheme.volt)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(PulseTheme.textPrimary)
                    Text(activity.watchSubtitle)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? PulseTheme.mint : PulseTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(width: 132, alignment: .leading)
            .pulseCard(highlighted: isSelected, cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }
}
