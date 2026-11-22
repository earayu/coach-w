import HealthKit
import SwiftUI
import WatchKit

final class AppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        diag("watch", "app launched, build \(build)")
    }

    /// Called when the iPhone starts a workout with `startWatchApp(toHandle:)`.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        diag("watch", "iPhone asked to start a workout (activity type \(workoutConfiguration.activityType.rawValue))")
        Task { await WorkoutController.shared.start(workoutConfiguration) }
    }

    /// Called when watchOS relaunches the app while one of its workouts is still running.
    func handleActiveWorkoutRecovery() {
        diag("watch", "relaunched to recover an active workout")
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
