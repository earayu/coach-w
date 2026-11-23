import CoachKit
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The coach follows the workout (docs/spec.md 7.6): it comes when one starts and leaves
    /// after the chat that follows, so nobody has to connect or hang up by hand.
    private var presence = CoachPresence()
    private var presenceCheck: Task<Void, Never>?
    static let presenceInterval: Duration = .seconds(15)
    /// Between the server ending a capped session and asking for the next one.
    static let rejoinDelay: Duration = .seconds(3)

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        diag("phone", "app launched, build \(build)")
        let mirror = MirrorReceiver.shared, voice = VoiceSession.shared, recorder = WorkoutRecorder.shared
        let settings = AppSettings.shared
        mirror.install()
        // the coach dot on the watch (spec 7.6): on every change, at each workout start, and on
        // each presence check so it never goes stale on the wrist
        let showCoachOnWatch: @MainActor () -> Void = {
            guard mirror.isActive else { return }
            mirror.sendToWatch(CoachStatus(voice.coachState, at: .now))
        }
        voice.onStatusChanged = showCoachOnWatch
        mirror.onSessionStarted = { [weak self] activity in
            recorder.begin(activity)
            self?.presence.workoutStarted()
            showCoachOnWatch()
            // also when the workout was started on the watch, with the phone in a pocket
            guard settings.wantsCoachForWorkout, !voice.isActive else { return }
            diag("voice", "workout started: connecting the coach")
            Task { await voice.start(settings: settings) }
        }
        mirror.onSessionEnded = { [weak self] in
            recorder.finish()
            self?.presence.workoutEnded(at: .now)
        }
        mirror.onFrames = { frames in
            recorder.ingest(frames)
            voice.send(frames)
        }
        voice.onCue = { mirror.sendToWatch($0) }
        let conversation = ConversationLog.shared
        voice.onCoachLine = { [weak self] in
            conversation.append($0, source: .coach)
            recorder.addLine($0, source: .coach)
            self?.presence.talked(at: .now)
        }
        voice.onUserLine = { [weak self] in
            conversation.append($0, source: .athlete)
            recorder.addLine($0, source: .athlete)
            self?.presence.talked(at: .now)
        }
        voice.resumeProvider = { recorder.resume() }
        // the coach's `start_workout` tool (spec 7.6): kick the start off and answer right away,
        // the watch can take a while to wake up (COCH-17)
        voice.startProvider = { wire in
            guard let activity = WorkoutActivity(rawValue: wire) else { return #"{"ok":false,"reason":"unknown activity"}"# }
            if mirror.isActive { return #"{"ok":false,"reason":"a workout is already running"}"# }
            if mirror.isStartingWatch { return #"{"ok":true,"status":"already waking the watch"}"# }
            diag("phone", "coach asked to start \(wire) on the watch")
            Task { await mirror.startOnWatch(activity) }
            return #"{"ok":true,"status":"waking the watch"}"#
        }
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
        voice.onConnected = { [weak self] in
            LocalSpeaker.shared.yieldToVoiceCoach()
            keepOfflineSpeech(true)
            self?.presence.coachConnected(at: .now)
        }
        voice.onStopped = { [weak self] in
            keepOfflineSpeech(false)
            guard let self else { return }
            // the session length cap ends a long run's coach: bring a new one, which carries on
            // from `coach.resume` and the conversation so far (spec 7.4)
            let rejoin = voice.endedByServer && presence.shouldRejoin(at: .now)
            presence.coachStopped()
            guard rejoin else { return }
            diag("voice", "server ended the session mid-workout: rejoining")
            Task {
                try? await Task.sleep(for: Self.rejoinDelay)
                guard mirror.isActive, !voice.isActive else { return }
                await voice.start(settings: settings)
            }
        }
        presenceCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.presenceInterval)
                showCoachOnWatch()
                guard let self, voice.isActive, presence.shouldHangUp(at: .now) else { continue }
                diag("voice", "hanging up, nobody spoke for a while: \(presence.stage)")
                await voice.stop()
                LocalSpeaker.shared.speak(
                    settings.wantsCoachForWorkout ? "教练先下线了，下次开始运动会自动接通。" : "教练先下线了。"
                )
            }
        }
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
