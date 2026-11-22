import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The voice coach hangs up this long after a workout ends, unless another one starts: time
    /// for the summary and a word or two, without a session left open for the rest of the day.
    static let voiceAfterWorkout: Duration = .seconds(5 * 60)
    private var voiceHangUp: Task<Void, Never>?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        diag("phone", "app launched, build \(build)")
        let mirror = MirrorReceiver.shared, voice = VoiceSession.shared, recorder = WorkoutRecorder.shared
        mirror.install()
        mirror.onSessionStarted = { [weak self] activity in
            self?.voiceHangUp?.cancel()
            recorder.begin(activity)
        }
        mirror.onSessionEnded = { [weak self] in
            recorder.finish()
            self?.voiceHangUp?.cancel()
            self?.voiceHangUp = Task {
                try? await Task.sleep(for: Self.voiceAfterWorkout)
                guard !Task.isCancelled, !mirror.isActive, voice.isActive else { return }
                diag("voice", "hanging up \(Self.voiceAfterWorkout) after the workout ended")
                await voice.stop()
            }
        }
        mirror.onFrames = { frames in
            recorder.ingest(frames)
            voice.send(frames)
        }
        voice.onCue = { mirror.sendToWatch($0) }
        let conversation = ConversationLog.shared
        voice.onCoachLine = {
            conversation.append($0, source: .coach)
            recorder.addLine($0, source: .coach)
        }
        voice.onUserLine = {
            conversation.append($0, source: .athlete)
            recorder.addLine($0, source: .athlete)
        }
        voice.resumeProvider = { recorder.resume() }
        let places = PlaceFinder.shared
        places.watchFix = { mirror.latest?.location }
        voice.placesProvider = { await places.lookAround(query: $0) }
        // What the athlete says while the coach cannot hear it is kept and passed on (spec 7.4).
        let offline = OfflineVoiceRecorder.shared
        let keepOfflineSpeech: @MainActor (Bool) -> Void = { tellCoach in
            Task {
                guard let text = await offline.stopAndTranscribe() else { return }
                conversation.append(text, source: .athlete)
                recorder.addLine(text, source: .athlete)
                if tellCoach { await voice.sendOfflineSpeech(text) }
            }
        }
        voice.onLinkLost = {
            if !voice.isMuted { offline.start() }
            guard recorder.isRecording else { return }
            LocalSpeaker.shared.speak("教练暂时离线，正在重连。你说的话我先记在手机上，运动记录不受影响。")
        }
        voice.onConnected = {
            LocalSpeaker.shared.yieldToVoiceCoach()
            keepOfflineSpeech(true)
        }
        voice.onStopped = { keepOfflineSpeech(false) }
        // Offline fallback (docs/spec.md 7.4): the phone speaks what the coach cannot, and the watch
        // still buzzes. While the coach is connected it handles both itself.
        recorder.onLocalCue = { local in
            guard voice.needsLocalFallback, !local.cue.isExpired(at: .now) else { return }
            LocalSpeaker.shared.speak(local.speech, urgent: local.cue.priority == .emergency)
            mirror.sendToWatch(local.cue)
            conversation.append(local.speech, source: .local)
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
