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
        .tint(PulseTheme.volt)
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

/// Full-width Apple Watch Fitness-style activity picker with Pulse W obsidian cards.
private struct StartView: View {
    let lastError: String?
    let onStart: (WorkoutActivity) -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PulseTheme.obsidianTop, PulseTheme.watchCanvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        PulseWMark(size: 24, showRings: false, breathing: false)
                        Text("COACH W")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(PulseTheme.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)

                    ForEach(WorkoutActivity.allCases) { activity in
                        Button {
                            onStart(activity)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(PulseTheme.volt.opacity(0.16))
                                        .frame(width: 38, height: 38)
                                    Image(systemName: activity.symbol)
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(PulseTheme.volt)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(activity.title)
                                        .font(.system(.headline, design: .rounded).weight(.bold))
                                        .foregroundStyle(PulseTheme.textPrimary)
                                    Text(activity.watchSubtitle)
                                        .font(.caption2)
                                        .foregroundStyle(PulseTheme.textSecondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 4)

                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(PulseTheme.mint.opacity(0.8))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            .background {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(PulseTheme.cardGradient)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(PulseTheme.surfaceStroke, lineWidth: 1)
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if let error = lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(PulseTheme.coral)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// High-contrast OLED workout dial tuned for outdoor sunlight legibility.
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

    var body: some View {
        let paused = !isRunning || frame?.state == .paused
        let hrZone = HeartRateZone.zone(for: frame?.hrBpm)

        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 4) {
                // Status header kept on the leading half so the watchOS clock stays clear on top-right
                HStack(spacing: 5) {
                    Image(systemName: activity.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PulseTheme.mint)
                    Text(isFinishing ? "正在保存…" : paused ? "已暂停" : activity.title)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(paused ? PulseTheme.amber : PulseTheme.textSecondary)
                    if frame?.lat != nil {
                        Image(systemName: "location.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(PulseTheme.mint)
                    }
                    Circle()
                        .fill(paused ? PulseTheme.amber : PulseTheme.mint)
                        .frame(width: 6, height: 6)
                    Spacer()
                }

                // Giant high-contrast Volt timer
                Text(Format.duration(frame?.elapsedS))
                    .font(.system(size: 36, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(paused ? PulseTheme.amber : PulseTheme.volt)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                // Heart rate + zone badge
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "heart.fill")
                        .font(.body)
                        .foregroundStyle(hrZone?.color ?? PulseTheme.coral)
                    Text(Format.number(frame?.hrBpm))
                        .font(.system(size: 27, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(frame?.hrBpm != nil ? PulseTheme.textPrimary : PulseTheme.textTertiary)
                    Text("bpm")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PulseTheme.textSecondary)
                    Spacer(minLength: 2)
                    if let hrZone {
                        Text(hrZone.code)
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(PulseTheme.obsidianMid)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(hrZone.color, in: Capsule())
                    }
                }

                // Distance + primary speed/pace row
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Format.distanceNumber(frame?.distanceM))
                            .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(frame?.distanceM != nil ? PulseTheme.textPrimary : PulseTheme.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text("km")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PulseTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1, height: 24)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(Format.primarySpeedNumber(frame?.speedMps, readsAsPace: activity.readsSpeedAsPace))
                            .font(.system(size: 19, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(frame?.speedMps != nil ? PulseTheme.mint : PulseTheme.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(activity.speedUnit)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PulseTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)

                if let lastError {
                    Text(lastError)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PulseTheme.coral)
                        .lineLimit(2)
                }

                Spacer(minLength: 2)

                // High-contrast dual circular controls
                HStack(spacing: 14) {
                    watchCircleControl(
                        symbol: isRunning ? "pause.fill" : "play.fill",
                        label: isRunning ? "暂停" : "继续",
                        foreground: isRunning ? PulseTheme.amber : PulseTheme.obsidianMid,
                        background: isRunning ? PulseTheme.amber.opacity(0.24) : PulseTheme.volt,
                        border: isRunning ? PulseTheme.amber.opacity(0.75) : PulseTheme.volt,
                        action: {
                            diag("watch-ui", "\(isRunning ? "pause" : "resume") button tapped")
                            (isRunning ? onPause : onResume)()
                        }
                    )

                    watchCircleControl(
                        symbol: "xmark",
                        label: "结束",
                        foreground: PulseTheme.coral,
                        background: PulseTheme.coral.opacity(0.24),
                        border: PulseTheme.coral.opacity(0.75),
                        action: {
                            diag("watch-ui", "end button tapped")
                            onEnd()
                        }
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 4)
        }
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

    private func watchCircleControl(
        symbol: String,
        label: String,
        foreground: Color,
        background: Color,
        border: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(foreground)
                    .frame(width: 46, height: 46)
                    .background(background, in: Circle())
                    .overlay(Circle().strokeBorder(border, lineWidth: 1.5))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PulseTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

/// High-contrast floating coach cue banner shown over the watch dial until expiry.
private struct CueBanner: View {
    let cue: CoachCue

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: cue.priority.symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(iconColor)
            Text(cue.text ?? "教练提醒")
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .foregroundStyle(textColor)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cue.priority.accentColor)
                .shadow(color: cue.priority.accentColor.opacity(0.45), radius: 10, y: 3)
        )
    }

    private var textColor: Color {
        cue.priority == .emergency ? .white : PulseTheme.obsidianMid
    }

    private var iconColor: Color {
        cue.priority == .emergency ? .white : PulseTheme.obsidianMid
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
