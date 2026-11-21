import CoachKit
import SwiftUI

struct ContentView: View {
    let mirror: MirrorReceiver
    let voice: VoiceSession
    let recorder: WorkoutRecorder
    let store: WorkoutStore
    @Bindable var settings: AppSettings
    @State private var activity: WorkoutActivity = .running
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                VoiceSection(voice: voice, settings: settings, showSettings: $showSettings)
                if mirror.isActive {
                    LiveSection(mirror: mirror)
                    StreamSection(stats: mirror.stats)
                } else {
                    if let record = recorder.lastRecord {
                        Section("刚刚完成") {
                            NavigationLink { RecordDetailView(record: record) } label: { RecordRow(record: record) }
                        }
                    }
                    startSection
                }
                if let error = mirror.lastError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(mirror.activity?.title ?? "coach-w")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { RecordsView(store: store) } label: { Label("运动记录", systemImage: "list.bullet.rectangle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { settings.normalize() }) { SettingsView(settings: settings) }
        }
        .task {
            if settings.autoConnect, settings.isConfigured { await voice.start(settings: settings) }
            await mirror.requestAuthorization()
        }
    }

    private var startSection: some View {
        Section {
            Picker("运动", selection: $activity) {
                ForEach(WorkoutActivity.allCases) { activity in
                    Label(activity.title, systemImage: activity.symbol).tag(activity)
                }
            }
            Button {
                Task { await mirror.startOnWatch(activity) }
            } label: {
                Label("在手表上开始", systemImage: "applewatch")
            }
        } footer: {
            Text("手表负责采集和保存运动，这里实时显示手表发来的指标。")
        }
    }
}

private struct VoiceSection: View {
    let voice: VoiceSession
    let settings: AppSettings
    @Binding var showSettings: Bool

    var body: some View {
        Section {
            LabeledContent("教练", value: voice.status.title)
            if voice.status == .connected {
                Row("已发送指标", "\(voice.framesSent) 帧")
                Row("手表提醒", "\(voice.cuesReceived) 条")
            }
            if voice.reconnects > 0 {
                Row("自动重连", "\(voice.reconnects) 次")
            }
            HStack {
                if voice.isActive {
                    Button(voice.isMuted ? "取消静音" : "静音",
                           systemImage: voice.isMuted ? "mic.slash.fill" : "mic.fill") {
                        Task { await voice.toggleMute() }
                    }
                    .disabled(voice.status != .connected)
                    Spacer()
                    Button("结束语音", systemImage: "phone.down.fill", role: .destructive) {
                        Task { await voice.stop() }
                    }
                } else if settings.isConfigured {
                    Button("连接教练", systemImage: "waveform") {
                        Task { await voice.start(settings: settings) }
                    }
                } else {
                    Button("先填写邀请码和服务器", systemImage: "gearshape") { showSettings = true }
                }
            }
            .buttonStyle(.bordered)
        } header: {
            Text("语音教练")
        } footer: {
            if voice.needsLocalFallback {
                Text("教练暂时不在线：心率过高、整公里和结束由手机直接播报，手表照常震动。")
            }
        }
    }
}

private struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("邀请码", text: $settings.inviteCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("邀请码保存在钥匙串里。")
                }
                Section {
                    TextField("http://192.168.1.10:8000", text: $settings.apiBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("服务器地址")
                } footer: {
                    Text("开发时填 Mac 的局域网地址，正式服务器填 https 域名。")
                }
                Section("运动者 ID") {
                    Text(settings.athleteID).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("设置")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

private struct LiveSection: View {
    let mirror: MirrorReceiver

    var body: some View {
        let frame = mirror.latest
        let activity = mirror.activity ?? .other
        Section {
            Row("时长", Format.duration(frame?.elapsedS))
            Row("心率", Format.value(frame?.hrBpm, unit: "bpm"))
            Row("距离", Format.distance(frame?.distanceM))
            if activity.readsSpeedAsPace {
                Row("配速", Format.pace(frame?.speedMps))
            } else {
                Row("速度", Format.speed(frame?.speedMps))
            }
            Row(activity.readsSpeedAsPace ? "步频" : "踏频", Format.value(frame?.cadenceSpm, unit: activity.cadenceUnit))
            Row("功率", Format.value(frame?.powerW, unit: "W"))
            Row("步幅", Format.value(frame?.strideM, unit: "m", digits: 2))
            Row("触地时间", Format.value(frame?.gctMs, unit: "ms"))
            Row("垂直振幅", Format.value(frame?.voCm, unit: "cm", digits: 1))
            Row("能量", Format.value(frame?.energyKcal, unit: "kcal"))
            Row("海拔", Format.value(frame?.altM, unit: "m"))
            Row("GPS", frame?.lat == nil ? "未定位" : "已定位")
        } header: {
            Text(frame?.state == .paused ? "已暂停" : "进行中")
        } footer: {
            HStack {
                if mirror.state == .running {
                    Button("暂停", systemImage: "pause.fill") { mirror.pause() }
                } else {
                    Button("继续", systemImage: "play.fill") { mirror.resume() }
                }
                Spacer()
                Button("结束", systemImage: "stop.fill", role: .destructive) { mirror.end() }
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
    }
}

private struct StreamSection: View {
    let stats: FrameStats

    var body: some View {
        Section("数据流") {
            Row("已收到", "\(stats.received) 帧")
            Row("丢失", "\(stats.missing) 帧")
            Row("乱序", "\(stats.outOfOrder) 帧")
            Row("平均间隔", stats.meanInterval.map { String(format: "%.2f s", $0) } ?? Format.dash)
            Row("最近延迟", stats.lastDelayMs.map { "\($0) ms" } ?? Format.dash)
        }
    }
}

private struct Row: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title) {
            Text(value).monospacedDigit()
        }
    }
}
