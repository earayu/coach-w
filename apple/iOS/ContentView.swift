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

    #if DEBUG
    private var uiPreview: UIPreviewScene? {
        ProcessInfo.processInfo.environment["COACHW_UI_PREVIEW"].flatMap(UIPreviewScene.init(rawValue:))
    }
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                PulseBackground(auraOpacity: isWorkoutActive ? 0.12 : 0.18)

                #if DEBUG
                if let preview = uiPreview {
                    previewBody(preview)
                } else {
                    liveBody
                }
                #else
                liveBody
                #endif
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if showRootToolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            RecordsView(store: store)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                                    .font(.subheadline.weight(.semibold))
                                Text("记录")
                                    .font(.subheadline.weight(.semibold))
                                if !store.records.isEmpty {
                                    Text("\(store.records.count)")
                                        .font(.caption2.weight(.bold).monospacedDigit())
                                        .foregroundStyle(PulseTheme.obsidianMid)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(PulseTheme.volt, in: Capsule())
                                }
                            }
                            .foregroundStyle(PulseTheme.textPrimary)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "gearshape.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(PulseTheme.textPrimary)
                                if showConfigDot {
                                    Circle()
                                        .fill(PulseTheme.amber)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 3, y: -2)
                                }
                            }
                        }
                        .accessibilityLabel("设置")
                    }
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { settings.normalize() }) {
                SettingsView(settings: settings)
            }
        }
        .tint(PulseTheme.volt)
        .preferredColorScheme(.dark)
        .task {
            #if DEBUG
            if let preview = uiPreview {
                if preview == .settings { showSettings = true }
                return
            }
            #endif
            if settings.autoConnect, settings.isConfigured { await voice.start(settings: settings) }
            await mirror.requestAuthorization()
        }
    }

    private var isWorkoutActive: Bool {
        #if DEBUG
        if uiPreview == .active { return true }
        #endif
        return mirror.isActive
    }

    private var showRootToolbar: Bool {
        #if DEBUG
        if uiPreview == .records || uiPreview == .recordDetail { return false }
        #endif
        return true
    }

    private var showConfigDot: Bool {
        #if DEBUG
        if uiPreview != nil { return false }
        #endif
        return !settings.isConfigured
    }

    @ViewBuilder
    private var liveBody: some View {
        if mirror.isActive {
            WorkoutDashboardView(
                activity: mirror.activity ?? .other,
                frame: mirror.latest,
                stats: mirror.stats,
                isRunning: mirror.isRunning,
                isFinishing: mirror.state == .stopped,
                voice: VoiceVisualState(voice: voice),
                isConfigured: settings.isConfigured,
                lastError: mirror.lastError,
                onPause: { mirror.pause() },
                onResume: { mirror.resume() },
                onEnd: { mirror.end() },
                onConnectVoice: { Task { await voice.start(settings: settings) } },
                onToggleMute: { Task { await voice.toggleMute() } },
                onStopVoice: { Task { await voice.stop() } },
                onOpenSettings: { showSettings = true }
            )
        } else {
            LobbyView(
                selectedActivity: $activity,
                voice: VoiceVisualState(voice: voice),
                isConfigured: settings.isConfigured,
                lastRecord: recorder.lastRecord,
                lastError: mirror.lastError,
                isStartingWatch: mirror.isStartingWatch,
                onStartWatch: { Task { await mirror.startOnWatch(activity) } },
                onConnectVoice: { Task { await voice.start(settings: settings) } },
                onToggleMute: { Task { await voice.toggleMute() } },
                onStopVoice: { Task { await voice.stop() } },
                onOpenSettings: { showSettings = true }
            )
        }
    }

    #if DEBUG
    @ViewBuilder
    private func previewBody(_ scene: UIPreviewScene) -> some View {
        switch scene {
        case .lobby, .settings:
            LobbyView(
                selectedActivity: $activity,
                voice: VoiceVisualState(
                    mode: .listening,
                    isActive: true,
                    isConnected: true,
                    isMuted: false,
                    needsLocalFallback: false,
                    framesSent: 0,
                    cuesReceived: 0,
                    reconnects: 0
                ),
                isConfigured: true,
                lastRecord: UIPreviewFixtures.sampleRecords.first,
                lastError: nil,
                onStartWatch: {},
                onConnectVoice: {},
                onToggleMute: {},
                onStopVoice: {},
                onOpenSettings: { showSettings = true }
            )
        case .active:
            WorkoutDashboardView(
                activity: .running,
                frame: UIPreviewFixtures.sampleFrame,
                stats: UIPreviewFixtures.sampleStats,
                isRunning: true,
                voice: VoiceVisualState(
                    mode: .speaking,
                    isActive: true,
                    isConnected: true,
                    isMuted: false,
                    needsLocalFallback: false,
                    framesSent: 1718,
                    cuesReceived: 5,
                    reconnects: 0
                ),
                isConfigured: true,
                lastError: nil,
                onPause: {},
                onResume: {},
                onEnd: {},
                onConnectVoice: {},
                onToggleMute: {},
                onStopVoice: {},
                onOpenSettings: { showSettings = true }
            )
        case .records:
            RecordsView(records: UIPreviewFixtures.sampleRecords)
        case .recordDetail:
            RecordDetailView(record: UIPreviewFixtures.sampleRecords[0])
        }
    }
    #endif
}

#if DEBUG
private enum UIPreviewScene: String {
    case lobby
    case active
    case records
    case recordDetail = "record_detail"
    case settings
}

/// Synthetic fixtures used solely when launching Simulator with `COACHW_UI_PREVIEW` in DEBUG builds.
private enum UIPreviewFixtures {
    static let sampleFrame = MetricsFrame(
        seq: 1718,
        ts: 1_760_000_000_000,
        activity: "running",
        state: .running,
        elapsedS: 1718,
        phoneTs: 1_760_000_000_068,
        hrBpm: 158,
        distanceM: 5240,
        speedMps: 3.185,
        cadenceSpm: 176,
        powerW: 268,
        strideM: 1.09,
        gctMs: 228,
        voCm: 8.4,
        energyKcal: 362,
        lat: 31.2304,
        lon: 121.4737,
        altM: 42
    )

    static var sampleStats: FrameStats {
        var stats = FrameStats()
        for i in 1...12 {
            let ts: Int64 = 1_760_000_000_000 + Int64(i) * 1000
            stats.record(
                MetricsFrame(
                    seq: i,
                    ts: ts,
                    activity: "running",
                    state: .running,
                    elapsedS: Double(i),
                    phoneTs: ts + 68
                )
            )
        }
        return stats
    }

    static let sampleRecords: [WorkoutRecord] = [
        WorkoutRecord(
            activity: "running",
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: Date().addingTimeInterval(-1882),
            durationS: 1718,
            distanceM: 5240,
            energyKcal: 362,
            avgHrBpm: 154,
            maxHrBpm: 169,
            avgSpeedMps: 3.05,
            avgCadenceSpm: 176,
            avgPowerW: 264,
            kmSplitsS: [338, 326, 321, 314, 319],
            lines: [
                CoachLine(at: Date().addingTimeInterval(-3540), text: "出发啦！前五分钟先轻松热身，把步频慢慢带起来。", source: .coach),
                CoachLine(at: Date().addingTimeInterval(-2600), text: "第 3 公里用时 5 分 21 秒，心率稳在有氧区，节奏非常顺。", source: .coach),
                CoachLine(at: Date().addingTimeInterval(-2280), text: "第 4 公里 5 分 14 秒，是今天最快的一公里，注意保持放松摆臂。", source: .coach),
                CoachLine(at: Date().addingTimeInterval(-1880), text: "辛苦了！今天共跑 5.24 公里，用时 28 分 38 秒，平均心率 154，第 4 公里最快。", source: .coach),
            ]
        ),
        WorkoutRecord(
            activity: "cycling",
            startedAt: Date().addingTimeInterval(-90_000),
            endedAt: Date().addingTimeInterval(-86_400),
            durationS: 3600,
            distanceM: 24_800,
            energyKcal: 610,
            avgHrBpm: 141,
            maxHrBpm: 162,
            avgSpeedMps: 6.89,
            avgCadenceSpm: 84,
            avgPowerW: 185,
            kmSplitsS: [],
            lines: [
                CoachLine(at: Date().addingTimeInterval(-88_200), text: "已骑行 15 公里，当前均速每小时 24.8 公里，前方路口注意控速。", source: .coach),
            ]
        ),
        WorkoutRecord(
            activity: "walking",
            startedAt: Date().addingTimeInterval(-176_000),
            endedAt: Date().addingTimeInterval(-173_900),
            durationS: 2100,
            distanceM: 3120,
            energyKcal: 168,
            avgHrBpm: 108,
            maxHrBpm: 119,
            avgSpeedMps: 1.49,
            kmSplitsS: [680, 672, 665],
            lines: [
                CoachLine(at: Date().addingTimeInterval(-174_500), text: "已经走了 2 公里，顺口提醒一下记得补充几口水。", source: .local),
            ]
        ),
    ]
}
#endif
