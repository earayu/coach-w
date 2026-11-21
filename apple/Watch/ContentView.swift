import CoachKit
import SwiftUI

struct ContentView: View {
    let workout: WorkoutController

    var body: some View {
        NavigationStack {
            Group {
                if workout.state.isActive {
                    ActiveWorkoutView(workout: workout)
                } else {
                    StartView(workout: workout)
                }
            }
        }
        .task { await workout.requestAuthorization() }
    }
}

private struct StartView: View {
    let workout: WorkoutController

    var body: some View {
        List {
            ForEach(WorkoutActivity.allCases) { activity in
                Button {
                    Task { await workout.start(activity) }
                } label: {
                    Label(activity.title, systemImage: activity.symbol)
                }
            }
            if let error = workout.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle("coach-w")
    }
}

private struct ActiveWorkoutView: View {
    let workout: WorkoutController

    var body: some View {
        let frame = workout.latest
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(Format.duration(frame?.elapsedS))
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .foregroundStyle(.yellow)
                Text(Format.value(frame?.hrBpm, unit: "bpm"))
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                Text(Format.distance(frame?.distanceM))
                Text(Format.pace(frame?.speedMps))
                Text("#\(frame?.seq ?? 0)").font(.footnote).foregroundStyle(.secondary)

                HStack {
                    if workout.state == .running {
                        Button("暂停", systemImage: "pause.fill") { workout.pause() }
                    } else {
                        Button("继续", systemImage: "play.fill") { workout.resume() }
                    }
                    Button("结束", systemImage: "xmark", role: .destructive) { workout.end() }
                }
                .labelStyle(.iconOnly)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(workout.activity?.title ?? "")
        .overlay(alignment: .top) {
            if let cue = workout.cue {
                CueBanner(cue: cue)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: workout.cue?.id)
    }
}

/// Short coach cue shown over the workout for a few seconds.
private struct CueBanner: View {
    let cue: CoachCue

    var body: some View {
        Label(cue.text ?? "教练提醒", systemImage: symbol)
            .font(.headline)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.black)
    }

    private var symbol: String {
        switch cue.priority {
        case .emergency: "exclamationmark.triangle.fill"
        case .correction: "arrow.up.arrow.down"
        case .milestone: "flag.fill"
        case .companion: "bubble.left.fill"
        }
    }

    private var color: Color {
        switch cue.priority {
        case .emergency: .red
        case .correction: .orange
        case .milestone: .green
        case .companion: .gray
        }
    }
}
