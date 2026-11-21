import CoachKit
import SwiftUI

struct ContentView: View {
    let mirror: MirrorReceiver
    @State private var activity: WorkoutActivity = .running

    var body: some View {
        NavigationStack {
            List {
                if mirror.isActive {
                    LiveSection(mirror: mirror)
                    StreamSection(stats: mirror.stats)
                } else {
                    startSection
                }
                if let error = mirror.lastError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(mirror.activity?.title ?? "coach-w")
        }
        .task { await mirror.requestAuthorization() }
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

private struct LiveSection: View {
    let mirror: MirrorReceiver

    var body: some View {
        let frame = mirror.latest
        Section {
            Row("时长", Format.duration(frame?.elapsedS))
            Row("心率", Format.value(frame?.hrBpm, unit: "bpm"))
            Row("距离", Format.distance(frame?.distanceM))
            Row("配速", Format.pace(frame?.speedMps))
            Row("步频", Format.value(frame?.cadenceSpm, unit: "spm"))
            Row("功率", Format.value(frame?.powerW, unit: "W"))
            Row("步幅", Format.value(frame?.strideM, unit: "m", digits: 2))
            Row("触地时间", Format.value(frame?.gctMs, unit: "ms"))
            Row("垂直振幅", Format.value(frame?.voCm, unit: "cm", digits: 1))
            Row("能量", Format.value(frame?.energyKcal, unit: "kcal"))
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
