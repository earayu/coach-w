import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let mirror = MirrorReceiver.shared, voice = VoiceSession.shared, recorder = WorkoutRecorder.shared
        mirror.install()
        mirror.onSessionStarted = { recorder.begin($0) }
        mirror.onSessionEnded = { recorder.finish() }
        mirror.onFrames = { frames in
            recorder.ingest(frames)
            voice.send(frames)
        }
        voice.onCue = { mirror.sendToWatch($0) }
        voice.onCoachLine = { recorder.addLine($0, source: .coach) }
        voice.resumeProvider = { recorder.resume() }
        voice.onLinkLost = {
            guard recorder.isRecording else { return }
            LocalSpeaker.shared.speak("网络断了，教练暂时离线。我先播报重要提醒，运动记录不受影响。")
        }
        // Offline fallback (docs/spec.md 7.4): the phone speaks what the coach cannot, and the watch
        // still buzzes. While the coach is connected it handles both itself.
        recorder.onLocalCue = { local in
            guard voice.needsLocalFallback, !local.cue.isExpired(at: .now) else { return }
            LocalSpeaker.shared.speak(local.speech, urgent: local.cue.priority == .emergency)
            mirror.sendToWatch(local.cue)
            recorder.addLine(local.speech, source: .local)
        }
        return true
    }
}

@main
struct CoachWApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(mirror: .shared, voice: .shared, recorder: .shared, store: .shared, settings: .shared)
        }
    }
}
