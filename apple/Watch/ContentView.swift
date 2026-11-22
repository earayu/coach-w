import CoachKit
import SwiftUI

struct ContentView: View {
    let workout: WorkoutController

    #if DEBUG
    private var uiPreview: WatchPreviewScene? {
        ProcessInfo.processInfo.environment["COACHW_UI_PREVIEW"].flatMap(WatchPreviewScene.init(rawValue:))
    }
    #endif

    var body: some View {
        NavigationStack {
            Group {
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
        }
        .tint(Theme.accent)
        .task {
            #if DEBUG
            if uiPreview != nil { return }
            #endif
            await workout.requestAuthorization()
        }
    }

    @ViewBuilder
    private var liveBody: some View {
        if workout.state.isActive {
            ActiveWorkoutView(
                activity: workout.activity ?? .other,
                frame: workout.latest,
                isRunning: workout.isRunning,
                isFinishing: workout.isFinishing,
                lastError: workout.lastError,
                cue: workout.cue,
                onPause: { workout.pause() },
                onResume: { workout.resume() },
                onEnd: { workout.end() }
            )
        } else {
            StartView(
                lastError: workout.lastError,
                onStart: { activity in
                    diag("watch-ui", "start button tapped: \(activity.wireName)")
                    Task { await workout.start(activity) }
                }
            )
        }
    }

    #if DEBUG
    @ViewBuilder
    private func previewBody(_ scene: WatchPreviewScene) -> some View {
        switch scene {
        case .start:
            StartView(lastError: nil, onStart: { _ in })
        case .active:
            ActiveWorkoutView(
                activity: .running,
                frame: WatchPreviewFixtures.sampleFrame,
                isRunning: true,
                isFinishing: false,
                lastError: nil,
                cue: nil,
                onPause: {},
                onResume: {},
                onEnd: {}
            )
        case .activeCue:
            ActiveWorkoutView(
                activity: .running,
                frame: WatchPreviewFixtures.sampleFrame,
                isRunning: true,
                isFinishing: false,
                lastError: nil,
                cue: WatchPreviewFixtures.sampleCue,
                onPause: {},
                onResume: {},
                onEnd: {}
            )
        }
    }
    #endif
}

/// The Workout app's start screen: one tile per workout, tap to start.
private struct StartView: View {
    let lastError: String?
    let onStart: (WorkoutActivity) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(WorkoutActivity.allCases) { activity in
                    Button {
                        onStart(activity)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: activity.symbol)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 40, height: 40)
                                .background(Theme.accent.opacity(0.18), in: Circle())
                            Text(activity.title)
                                .font(.system(.headline, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if let error = lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.red)
                        .padding(.top, 4)
                }
            }
        }
        .navigationTitle("Coach W")
    }
}

/// During a workout, as on the Workout app: swipe right for the controls, metrics in the middle.
private struct ActiveWorkoutView: View {
    let activity: WorkoutActivity
    let frame: MetricsFrame?
    let isRunning: Bool
    let isFinishing: Bool
    let lastError: String?
    let cue: CoachCue?
    let onPause: () -> Void
    let onResume: () -> Void
    let onEnd: () -> Void

    private enum Page { case controls, metrics }
    @State private var page: Page = .metrics

    var body: some View {
        TabView(selection: $page) {
            controls.tag(Page.controls)
            metrics.tag(Page.metrics)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Theme.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            if let cue {
                CueBanner(cue: cue)
                    .padding(.horizontal, 6)
                    .padding(.top, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25), value: cue?.id)
    }

    private var paused: Bool { !isRunning || frame?.state == .paused }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Kept on the leading half so the watchOS clock stays clear on the top right
            HStack(spacing: 4) {
                Image(systemName: activity.symbol)
                    .foregroundStyle(Theme.accent)
                Text(isFinishing ? "正在保存" : paused ? "已暂停" : activity.title)
                    .foregroundStyle(paused ? Theme.yellow : Theme.secondaryText)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))

            Text(Format.duration(frame?.elapsedS))
                .font(Theme.numeral(38))
                .foregroundStyle(Theme.time)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                MetricLine(value: Format.number(frame?.hrBpm), unit: "BPM", unitColor: Theme.heart, size: 30, hasValue: frame?.hrBpm != nil)
                Image(systemName: "heart.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(HeartRateZone.zone(for: frame?.hrBpm)?.color ?? Theme.heart)
            }
            MetricLine(
                value: Format.primarySpeedNumber(frame?.speedMps, readsAsPace: activity.readsSpeedAsPace),
                unit: activity.speedUnit,
                unitColor: Theme.pace,
                size: 30,
                hasValue: frame?.speedMps != nil
            )
            MetricLine(
                value: Format.distanceNumber(frame?.distanceM),
                unit: "KM",
                unitColor: Theme.accent,
                size: 30,
                hasValue: frame?.distanceM != nil
            )

            if let lastError {
                Text(lastError)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.orange)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            control(symbol: "xmark", title: "结束", color: Theme.red) {
                diag("watch-ui", "end button tapped")
                onEnd()
            }
            control(
                symbol: isRunning ? "pause.fill" : "arrow.clockwise",
                title: isFinishing ? "正在保存" : isRunning ? "暂停" : "继续",
                color: isRunning ? Theme.yellow : Theme.accent
            ) {
                diag("watch-ui", "\(isRunning ? "pause" : "resume") button tapped")
                (isRunning ? onPause : onResume)()
                page = .metrics
            }
            .disabled(isFinishing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func control(symbol: String, title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 62, height: 62)
                    .background(color.opacity(0.22), in: Circle())
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A coach cue shown over the metrics until it expires.
private struct CueBanner: View {
    let cue: CoachCue

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: cue.priority.symbol)
                .font(.subheadline.weight(.bold))
            Text(cue.text ?? "教练提醒")
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(cue.priority == .emergency ? .white : .black)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(cue.priority.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#if DEBUG
private enum WatchPreviewScene: String {
    case start
    case active
    case activeCue = "active_cue"
}

private enum WatchPreviewFixtures {
    static let sampleFrame = MetricsFrame(
        seq: 1718,
        ts: 1_760_000_000_000,
        activity: "running",
        state: .running,
        elapsedS: 1718,
        hrBpm: 158,
        distanceM: 5240,
        speedMps: 3.185,
        cadenceSpm: 176,
        powerW: 268,
        lat: 31.2304,
        lon: 121.4737,
        altM: 42
    )

    static let sampleCue = CoachCue(
        id: "preview-cue-1",
        ts: 1_760_000_000_000,
        expiresAt: 1_999_999_999_000,
        priority: .milestone,
        kind: "km_split",
        haptic: .success,
        text: "第 5 公里 5'14\" · 节奏稳住"
    )
}
#endif
