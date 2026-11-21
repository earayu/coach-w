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
        ZStack {
            PulseBackground(auraOpacity: 0.12)

            if records.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(records) { record in
                            NavigationLink {
                                RecordDetailView(record: record)
                            } label: {
                                RecordSummaryCard(record: record)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删除这条记录", systemImage: "trash", role: .destructive) {
                                    onDelete(record)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle("运动记录")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(PulseTheme.volt.opacity(0.12))
                    .frame(width: 82, height: 82)
                Image(systemName: "figure.run.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(PulseTheme.pulseGradient)
            }
            VStack(spacing: 6) {
                Text("还没有运动记录")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(PulseTheme.textPrimary)
                Text("戴上 Apple Watch 完成一次运动后，指标摘要、每公里分段和教练对话精彩回顾都会保存在这里。")
                    .font(.subheadline)
                    .foregroundStyle(PulseTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .pulseCard(cornerRadius: 24)
        .padding(.horizontal, 20)
    }
}

/// Compact summary card reused in both the Lobby ("刚刚完成") and Records list.
struct RecordSummaryCard: View {
    let record: WorkoutRecord
    var highlighted: Bool = false

    var body: some View {
        let activity = WorkoutActivity(wireName: record.activity)
        let hrZone = HeartRateZone.zone(for: record.avgHrBpm)

        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(PulseTheme.pulseGradient.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: activity.symbol)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(PulseTheme.volt)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(PulseTheme.textPrimary)
                    Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(PulseTheme.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if let meters = record.distanceM {
                        Text(Format.distance(meters))
                            .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                            .foregroundStyle(PulseTheme.volt)
                    }
                    Text(Format.duration(record.durationS))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(PulseTheme.textSecondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PulseTheme.textTertiary)
            }

            HStack(spacing: 8) {
                if let speed = record.avgSpeedMps {
                    miniBadge(
                        icon: "speedometer",
                        text: Format.primarySpeed(speed, readsAsPace: activity.readsSpeedAsPace),
                        tint: PulseTheme.textSecondary
                    )
                }
                if let hr = record.avgHrBpm {
                    miniBadge(
                        icon: "heart.fill",
                        text: Format.value(hr, unit: "bpm"),
                        tint: hrZone?.color ?? PulseTheme.coral
                    )
                }
                if !record.lines.isEmpty {
                    miniBadge(
                        icon: "waveform",
                        text: "\(record.lines.count) 条教练对话",
                        tint: PulseTheme.mint
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .pulseCard(highlighted: highlighted, cornerRadius: 20)
    }

    private func miniBadge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.caption2.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(PulseTheme.obsidianMid.opacity(0.65), in: Capsule())
    }
}

/// Post-workout summary detail screen: hero card, metrics summary, km split bars, and coach timeline.
struct RecordDetailView: View {
    let record: WorkoutRecord

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        let activity = WorkoutActivity(wireName: record.activity)

        ZStack {
            PulseBackground(auraOpacity: 0.14)

            ScrollView {
                VStack(spacing: 16) {
                    heroSummaryCard(activity: activity)
                    secondarySummaryGrid(activity: activity)

                    if !record.kmSplitsS.isEmpty {
                        splitsCard
                    }

                    coachTimelineCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("\(activity.title)总结")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func heroSummaryCard(activity: WorkoutActivity) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: activity.symbol)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(PulseTheme.obsidianMid)
                        .frame(width: 28, height: 28)
                        .background(PulseTheme.pulseGradient, in: Circle())
                    Text(activity.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(PulseTheme.textPrimary)
                }
                Spacer()
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(PulseTheme.textSecondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let meters = record.distanceM {
                    Text(Format.distanceNumber(meters))
                        .font(.system(size: 52, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(PulseTheme.pulseGradient)
                    Text("km")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(PulseTheme.textSecondary)
                } else {
                    Text(Format.duration(record.durationS))
                        .font(.system(size: 48, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(PulseTheme.pulseGradient)
                }
            }

            HStack(spacing: 0) {
                summaryStat(title: "总时长", value: Format.duration(record.durationS))
                if let speed = record.avgSpeedMps {
                    Rectangle().fill(PulseTheme.surfaceStroke).frame(width: 1, height: 32)
                    summaryStat(
                        title: activity.averageSpeedTitle,
                        value: Format.primarySpeed(speed, readsAsPace: activity.readsSpeedAsPace)
                    )
                }
                if let hr = record.avgHrBpm {
                    Rectangle().fill(PulseTheme.surfaceStroke).frame(width: 1, height: 32)
                    summaryStat(title: "平均心率", value: Format.value(hr, unit: "bpm"))
                }
            }
            .padding(.vertical, 10)
            .background(PulseTheme.obsidianMid.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(18)
        .pulseCard(highlighted: true, cornerRadius: 24)
    }

    private func summaryStat(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(PulseTheme.textTertiary)
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(PulseTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func secondarySummaryGrid(activity: WorkoutActivity) -> some View {
        let items = detailMetrics(for: activity)
        if !items.isEmpty {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: item.symbol)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(item.accent)
                            Text(item.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(PulseTheme.textSecondary)
                        }
                        Text(item.value)
                            .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(PulseTheme.textPrimary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pulseCard(cornerRadius: 16)
                }
            }
        }
    }

    private var splitsCard: some View {
        let slowest = record.kmSplitsS.max() ?? 1
        let fastest = record.kmSplitsS.min() ?? 1
        let span = max(slowest - fastest, 1)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("每公里分段", systemImage: "flag.checkered")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(PulseTheme.textPrimary)
                Spacer()
                if let fastestKm = record.fastestKm {
                    Label("最快第 \(fastestKm) 公里", systemImage: "bolt.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PulseTheme.obsidianMid)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(PulseTheme.volt, in: Capsule())
                }
            }

            VStack(spacing: 10) {
                ForEach(Array(record.kmSplitsS.enumerated()), id: \.offset) { index, seconds in
                    let isFastest = index + 1 == record.fastestKm
                    // Faster split gets a fuller visual bar (0.45...1.0)
                    let ratio = record.kmSplitsS.count == 1
                        ? 0.85
                        : 0.45 + 0.55 * (1.0 - (seconds - fastest) / span)

                    HStack(spacing: 10) {
                        Text("\(index + 1)K")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(isFastest ? PulseTheme.volt : PulseTheme.textSecondary)
                            .frame(width: 28, alignment: .leading)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(PulseTheme.obsidianMid.opacity(0.7))
                                Capsule()
                                    .fill(
                                        isFastest
                                            ? AnyShapeStyle(PulseTheme.pulseHorizontal)
                                            : AnyShapeStyle(PulseTheme.mint.opacity(0.55))
                                    )
                                    .frame(width: max(20, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 10)

                        Text(Format.duration(seconds))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(isFastest ? PulseTheme.volt : PulseTheme.textPrimary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .pulseCard(cornerRadius: 20)
    }

    private var coachTimelineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("教练对话回顾", systemImage: "waveform")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(PulseTheme.textPrimary)
                Spacer()
                Text("\(record.lines.count) 条")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(PulseTheme.textSecondary)
            }

            if record.lines.isEmpty {
                Text("这次运动没有记录到语音教练对话。")
                    .font(.subheadline)
                    .foregroundStyle(PulseTheme.textTertiary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(record.lines.enumerated()), id: \.element.id) { index, line in
                        let isCoach = line.source == .coach
                        let accent = isCoach ? PulseTheme.mint : PulseTheme.amber
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(accent)
                                    .frame(width: 9, height: 9)
                                    .padding(.top, 5)
                                if index < record.lines.count - 1 {
                                    Rectangle()
                                        .fill(PulseTheme.surfaceStroke)
                                        .frame(width: 1.5)
                                        .frame(maxHeight: .infinity)
                                        .padding(.top, 4)
                                }
                            }
                            .frame(width: 12)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Label(
                                        isCoach ? "语音教练" : "本机播报",
                                        systemImage: isCoach ? "waveform" : "iphone"
                                    )
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(accent)

                                    Text(line.at.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(PulseTheme.textTertiary)
                                }

                                Text(line.text)
                                    .font(.subheadline)
                                    .foregroundStyle(PulseTheme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        PulseTheme.obsidianMid.opacity(0.68),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    )
                            }
                            .padding(.bottom, index < record.lines.count - 1 ? 14 : 0)
                        }
                    }
                }
            }
        }
        .padding(16)
        .pulseCard(cornerRadius: 20)
    }

    private struct DetailMetric: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let value: String
        let accent: Color
    }

    private func detailMetrics(for activity: WorkoutActivity) -> [DetailMetric] {
        var items: [DetailMetric] = []
        if let hr = record.maxHrBpm {
            let zoneColor = HeartRateZone.zone(for: hr)?.color ?? PulseTheme.coral
            items.append(.init(id: "maxHr", title: "最高心率", symbol: "heart.fill", value: Format.value(hr, unit: "bpm"), accent: zoneColor))
        }
        if let kcal = record.energyKcal {
            items.append(.init(id: "kcal", title: "活动能量", symbol: "flame.fill", value: Format.value(kcal, unit: "kcal"), accent: PulseTheme.orange))
        }
        if let cadence = record.avgCadenceSpm {
            items.append(.init(
                id: "cadence",
                title: "平均\(activity.cadenceTitle)",
                symbol: "metronome.fill",
                value: Format.value(cadence, unit: activity.cadenceUnit),
                accent: PulseTheme.mint
            ))
        }
        if let power = record.avgPowerW {
            items.append(.init(id: "power", title: "平均功率", symbol: "bolt.fill", value: Format.value(power, unit: "W"), accent: PulseTheme.volt))
        }
        return items
    }
}
