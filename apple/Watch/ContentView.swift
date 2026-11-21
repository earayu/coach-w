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
    }
}
