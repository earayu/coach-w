import CoachKit
import SwiftUI

/// Past workouts kept on this phone (docs/spec.md 2 step 6).
struct RecordsView: View {
    let store: WorkoutStore

    var body: some View {
        List {
            if store.records.isEmpty {
                ContentUnavailableView(
                    "还没有运动记录", systemImage: "figure.run",
                    description: Text("在手表上完成一次运动后，这里会留下指标摘要和教练说过的话。")
                )
            }
            ForEach(store.records) { record in
                NavigationLink {
                    RecordDetailView(record: record)
                } label: {
                    RecordRow(record: record)
                }
            }
            .onDelete { offsets in
                offsets.map { store.records[$0] }.forEach(store.delete)
            }
        }
        .navigationTitle("运动记录")
    }
}

struct RecordRow: View {
    let record: WorkoutRecord

    var body: some View {
        let activity = WorkoutActivity(wireName: record.activity)
        HStack(spacing: 12) {
            Image(systemName: activity.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).font(.headline)
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let meters = record.distanceM {
                    Text(Format.distance(meters)).font(.headline.monospacedDigit())
                }
                Text(Format.duration(record.durationS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct RecordDetailView: View {
    let record: WorkoutRecord

    var body: some View {
        let activity = WorkoutActivity(wireName: record.activity)
        List {
            Section {
                MetricGrid(items: metrics(for: activity))
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } header: {
                Text(record.startedAt.formatted(date: .complete, time: .shortened))
            }
            if !record.kmSplitsS.isEmpty {
                Section("每公里") {
                    ForEach(Array(record.kmSplitsS.enumerated()), id: \.offset) { index, seconds in
                        LabeledContent {
                            Text(Format.duration(seconds)).monospacedDigit()
                        } label: {
                            Label("第 \(index + 1) 公里", systemImage: index + 1 == record.fastestKm ? "bolt.fill" : "flag")
                        }
                    }
                }
            }
            Section("教练说过的话") {
                if record.lines.isEmpty {
                    Text("这次没有语音教练的记录").foregroundStyle(.secondary)
                }
                ForEach(record.lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.text)
                        HStack(spacing: 4) {
                            Image(systemName: line.source == .coach ? "waveform" : "iphone")
                            Text(line.source == .coach ? "教练" : "本机播报")
                            Text(line.at.formatted(date: .omitted, time: .shortened))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(activity.title)
    }

    private func metrics(for activity: WorkoutActivity) -> [MetricGrid.Item] {
        var items: [MetricGrid.Item] = [.init(title: "时长", value: Format.duration(record.durationS))]
        if let meters = record.distanceM { items.append(.init(title: "距离", value: Format.distance(meters))) }
        if let speed = record.avgSpeedMps {
            items.append(
                activity.readsSpeedAsPace
                    ? .init(title: "平均配速", value: Format.pace(speed))
                    : .init(title: "平均速度", value: Format.speed(speed))
            )
        }
        if let hr = record.avgHrBpm { items.append(.init(title: "平均心率", value: Format.value(hr, unit: "bpm"))) }
        if let hr = record.maxHrBpm { items.append(.init(title: "最高心率", value: Format.value(hr, unit: "bpm"))) }
        if let kcal = record.energyKcal { items.append(.init(title: "能量", value: Format.value(kcal, unit: "kcal"))) }
        if let cadence = record.avgCadenceSpm {
            let title = activity.readsSpeedAsPace ? "平均步频" : "平均踏频"
            items.append(.init(title: title, value: Format.value(cadence, unit: activity.cadenceUnit)))
        }
        if let power = record.avgPowerW { items.append(.init(title: "平均功率", value: Format.value(power, unit: "W"))) }
        return items
    }
}

/// Two columns of big numbers.
struct MetricGrid: View {
    struct Item: Hashable {
        let title: String
        let value: String
    }

    let items: [Item]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 14) {
            ForEach(items, id: \.self) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.caption).foregroundStyle(.secondary)
                    Text(item.value).font(.title3.weight(.semibold).monospacedDigit())
                }
            }
        }
    }
}
