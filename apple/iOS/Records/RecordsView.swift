import CoachKit
import SwiftUI

/// Past workouts kept on this phone (docs/spec.md 2 step 6).
struct RecordsView: View {
    let records: [WorkoutRecord]
    let onDelete: (WorkoutRecord) -> Void

    @MainActor
    init(store: WorkoutStore) {
        self.records = store.records
        self.onDelete = { store.delete($0) }
    }

    init(records: [WorkoutRecord], onDelete: @escaping (WorkoutRecord) -> Void = { _ in }) {
        self.records = records
        self.onDelete = onDelete
    }

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "还没有运动记录",
                    systemImage: "figure.run",
                    description: Text("用 Apple Watch 完成一次运动后，数据和教练对话会保存在这里。")
                )
            } else {
                List {
                    ForEach(records) { record in
                        NavigationLink {
                            RecordDetailView(record: record)
                        } label: {
                            RecordRow(record: record)
                        }
                        .swipeActions {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                onDelete(record)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.canvas)
        .navigationTitle("运动记录")
        .navigationBarTitleDisplayMode(.large)
    }
}

/// One workout in a list, as in the Fitness app: icon, name, the headline number, and the date.
struct RecordRow: View {
    let record: WorkoutRecord

    var body: some View {
        let activity = WorkoutActivity(wireName: record.activity)
        HStack(spacing: 14) {
            Image(systemName: activity.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Text(record.distanceM.map(Format.distance) ?? Format.duration(record.durationS))
                    .font(Theme.numeral(24))
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            Text(record.startedAt.formatted(.relative(presentation: .named)))
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, 2)
    }
}

/// After a workout: the summary grid, km splits, and what the coach and you said.
struct RecordDetailView: View {
    let record: WorkoutRecord

    var body: some View {
        let activity = WorkoutActivity(wireName: record.activity)
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: activity.symbol)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 56, height: 56)
                        .background(Theme.accent.opacity(0.16), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.title)
                            .font(.title3.weight(.semibold))
                        Text(timeRange)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("运动详情") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    ForEach(Array(stride(from: 0, to: metrics.count, by: 2)), id: \.self) { index in
                        GridRow {
                            metricCell(metrics[index])
                            if index + 1 < metrics.count {
                                metricCell(metrics[index + 1])
                            }
                        }
                        if index + 2 < metrics.count {
                            Divider().gridCellColumns(2)
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            if !record.kmSplitsS.isEmpty {
                Section("分段") {
                    ForEach(Array(record.kmSplitsS.enumerated()), id: \.offset) { index, seconds in
                        let isFastest = index + 1 == record.fastestKm
                        HStack {
                            Text("第 \(index + 1) 公里")
                                .foregroundStyle(Theme.secondaryText)
                            if isFastest {
                                Text("最快")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                            Spacer()
                            Text(Format.paceNumber(1000 / max(seconds, 1)))
                                .font(Theme.numeral(17))
                                .foregroundStyle(isFastest ? Theme.accent : Theme.pace)
                        }
                    }
                }
            }

            Section("教练对话") {
                if record.lines.isEmpty {
                    Text("这次运动没有记录到对话。")
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    ForEach(record.lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(line.source.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(line.source.accent)
                                Text(line.at.formatted(date: .omitted, time: .shortened))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            Text(line.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .navigationTitle(record.startedAt.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var timeRange: String {
        let start = record.startedAt.formatted(date: .omitted, time: .shortened)
        let end = record.endedAt.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private struct Metric {
        let title: String
        let value: String
        let unit: String
        let color: Color
    }

    private var metrics: [Metric] {
        let activity = WorkoutActivity(wireName: record.activity)
        var items = [Metric(title: "运动时间", value: Format.duration(record.durationS), unit: "", color: Theme.time)]
        if let meters = record.distanceM {
            items.append(Metric(title: "距离", value: Format.distanceNumber(meters), unit: "KM", color: Theme.accent))
        }
        if let speed = record.avgSpeedMps {
            items.append(Metric(
                title: activity.averageSpeedTitle,
                value: Format.primarySpeedNumber(speed, readsAsPace: activity.readsSpeedAsPace),
                unit: activity.speedUnit,
                color: Theme.pace
            ))
        }
        if let hr = record.avgHrBpm {
            items.append(Metric(title: "平均心率", value: Format.number(hr), unit: "BPM", color: Theme.heart))
        }
        if let hr = record.maxHrBpm {
            items.append(Metric(title: "最高心率", value: Format.number(hr), unit: "BPM", color: Theme.heart))
        }
        if let kcal = record.energyKcal {
            items.append(Metric(title: "活动能量", value: Format.number(kcal), unit: "KCAL", color: Theme.energy))
        }
        if let cadence = record.avgCadenceSpm {
            items.append(Metric(title: "平均\(activity.cadenceTitle)", value: Format.number(cadence), unit: activity.cadenceUnit, color: Theme.teal))
        }
        if let power = record.avgPowerW {
            items.append(Metric(title: "平均功率", value: Format.number(power), unit: "W", color: Theme.green))
        }
        return items
    }

    private func metricCell(_ metric: Metric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.title)
                .font(.subheadline)
                .foregroundStyle(.white)
            MetricLine(value: metric.value, unit: metric.unit, color: metric.color, size: 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension CoachLine.Source {
    var title: String {
        switch self {
        case .coach: "教练"
        case .local: "本机播报"
        case .athlete: "我"
        }
    }

    var accent: Color {
        switch self {
        case .coach: Theme.accent
        case .local: Theme.orange
        case .athlete: Theme.teal
        }
    }
}
