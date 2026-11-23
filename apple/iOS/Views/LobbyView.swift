import CoachKit
import SwiftUI

/// Before a workout: the coach's status, the workouts to start on the watch, and the last result.
struct LobbyView: View {
    @Binding var selectedActivity: WorkoutActivity
    let voice: VoiceVisualState
    let isConfigured: Bool
    let lastRecord: WorkoutRecord?
    let lastError: String?
    var isStartingWatch = false
    var isWatchSlowToStart = false
    /// Starting a workout also connects the coach (spec 7.6).
    var coachJoinsWorkouts = true
    let onStartWatch: (WorkoutActivity) -> Void
    var onCancelStart: () -> Void = {}
    let onConnectVoice: () -> Void
    let onToggleMute: () -> Void
    let onStopVoice: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        List {
            Section {
                coachRow
            } footer: {
                if let detail = voice.detail {
                    Text(detail)
                }
            }

            Section {
                ForEach(WorkoutActivity.allCases) { activity in
                    activityRow(activity)
                }
                if isStartingWatch {
                    Button("取消", role: .cancel, action: onCancelStart)
                        .foregroundStyle(Theme.secondaryText)
                }
            } header: {
                Text("开始")
            } footer: {
                if isStartingWatch {
                    Text(isWatchSlowToStart
                        ? "手表还没响应。请抬腕点亮手表；仍没反应就直接在手表上打开 coach-w 点「开始」，手机会自动接上。"
                        : "正在唤起手表上的 coach-w…")
                        .foregroundStyle(isWatchSlowToStart ? Theme.orange : Theme.secondaryText)
                } else if let lastError {
                    Text(lastError).foregroundStyle(Theme.red)
                } else {
                    Text(coachJoinsWorkouts
                        ? "运动由 Apple Watch 记录，教练随运动自动接通。也可以直接在手表上开始。"
                        : "运动由 Apple Watch 记录。也可以直接在手表上开始。")
                }
            }

            if let record = lastRecord {
                Section("上次运动") {
                    NavigationLink {
                        RecordDetailView(record: record)
                    } label: {
                        RecordRow(record: record)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Coach W")
        .navigationBarTitleDisplayMode(.large)
    }

    private var coachRow: some View {
        HStack(spacing: 12) {
            VoiceStatusLabel(voice: voice, isConfigured: isConfigured)
            Spacer()
            if voice.isActive {
                Button(action: onToggleMute) {
                    Image(systemName: voice.isMuted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(voice.isMuted ? Theme.teal : .white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .disabled(!voice.isConnected)
                .accessibilityLabel(voice.isMuted ? "取消静音" : "静音")
                Button("断开", role: .destructive, action: onStopVoice)
                    .foregroundStyle(Theme.red)
            } else if isConfigured {
                Button("和教练聊聊", action: onConnectVoice)
                    .fontWeight(.semibold)
            } else {
                Button("去设置", action: onOpenSettings)
                    .fontWeight(.semibold)
            }
        }
        .buttonStyle(.borderless)
    }

    private func activityRow(_ activity: WorkoutActivity) -> some View {
        let starting = isStartingWatch && activity == selectedActivity
        return Button {
            diag("phone-ui", "start on watch tapped: \(activity.wireName)")
            selectedActivity = activity
            onStartWatch(activity)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: activity.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30)
                Text(activity.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                if starting {
                    ProgressView()
                } else {
                    Image(systemName: "applewatch")
                        .font(.subheadline)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.vertical, 4)
        }
        .disabled(isStartingWatch)
    }
}
