import HealthKit
import SwiftUI
import WatchKit

final class AppDelegate: NSObject, WKApplicationDelegate {
    /// Called when the iPhone starts a workout with `startWatchApp(toHandle:)`.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { await WorkoutController.shared.start(workoutConfiguration) }
    }

    /// Called when watchOS relaunches the app while one of its workouts is still running.
    func handleActiveWorkoutRecovery() {
        Task { await WorkoutController.shared.recover() }
    }
}

@main
struct CoachWWatchApp: App {
    @WKApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(workout: .shared)
        }
    }
}
