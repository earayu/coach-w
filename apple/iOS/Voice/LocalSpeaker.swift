import AVFoundation
import os

private let log = Logger(subsystem: "com.earayu.coachw", category: "speaker")

/// Speaks the phone's own announcements with the system voice while the voice coach is offline
/// (docs/spec.md 7.4). Never logs what it says: the lines contain heart rate.
@MainActor
final class LocalSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = LocalSpeaker()

    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "zh-CN")
    /// Whether this speaker activated the audio session and should hand it back when done.
    private var ownsSession = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Emergencies cut in; everything else waits its turn.
    func speak(_ text: String, urgent: Bool = false) {
        if urgent, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        activateSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
    }

    /// The voice coach is back and LiveKit owns the audio session now: stop talking over it, and
    /// never deactivate the session it is using when this speech would have finished.
    func yieldToVoiceCoach() {
        ownsSession = false
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        // While LiveKit still holds a voice session (e.g. reconnecting) its category stays: speak
        // through it rather than tear it down.
        guard session.category != .playAndRecord else { return }
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try session.setActive(true)
            ownsSession = true
        } catch {
            log.error("audio session for local speech failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.releaseSessionIfIdle() }
    }

    private func releaseSessionIfIdle() {
        guard ownsSession, !synthesizer.isSpeaking else { return }
        ownsSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
