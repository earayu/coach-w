import AVFoundation
import Foundation
import Speech
import os

private let log = Logger(subsystem: "com.earayu.coachw", category: "offline-voice")

/// Keeps what the athlete says while the coach is unreachable (spec 7.4, COCH-15).
///
/// Records the microphone to a local file while the voice link is down; once it is back, the
/// file is transcribed on the phone and the text goes to the conversation log and to the coach.
/// The audio stays in Application Support/offline-voice and is deleted once transcribed; a file
/// that could not be transcribed is kept. Nothing is logged but sizes and outcomes.
@MainActor
final class OfflineVoiceRecorder: NSObject {
    static let shared = OfflineVoiceRecorder()

    private enum State {
        case idle
        case recording(recorder: AVAudioRecorder, startedAt: Date)
    }

    private var state: State = .idle
    private let directory = URL.applicationSupportDirectory.appending(path: "offline-voice", directoryHint: .isDirectory)

    /// Shorter recordings hold nothing worth transcribing.
    static let minDuration: TimeInterval = 1.5

    var isRecording: Bool {
        if case .recording(let recorder, _) = state { return recorder.isRecording }
        return false
    }

    /// Starts keeping the microphone; the audio session is the one LiveKit set up (play and record).
    func start() {
        guard case .idle = state else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Self.fileStamp.string(from: .now)
            let suffix = String(UUID().uuidString.prefix(8))
            let url = directory.appending(path: "\(stamp)-\(suffix).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .mixWithOthers])
            }
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else {
                diag("offline-voice", "recorder did not start")
                return
            }
            state = .recording(recorder: recorder, startedAt: .now)
            diag("offline-voice", "recording while the coach is unreachable")
        } catch {
            diag("offline-voice", "could not start recording: \(error.localizedDescription)")
        }
    }

    /// Stops and transcribes. Returns the text said offline, or nil when there was nothing.
    func stopAndTranscribe() async -> String? {
        guard case .recording(let recorder, let began) = state else { return nil }
        state = .idle
        let url = recorder.url
        let duration = recorder.currentTime
        recorder.stop()
        guard duration >= Self.minDuration else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        diag("offline-voice", "stopped after \(Int(duration))s; transcribing on the phone")
        guard let text = await Self.transcribe(url), !text.isEmpty else {
            diag("offline-voice", "nothing transcribed; audio kept")
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        diag("offline-voice", "transcribed \(text.count) characters said since \(Self.clock.string(from: began))")
        return text
    }

    private static func transcribe(_ url: URL) async -> String? {
        guard await authorize(), let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable
        else { return nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // keep the athlete's words on the phone when the device can
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.resume(result.bestTranscription.formattedString)
                } else if let error {
                    log.info("transcription failed: \(error.localizedDescription, privacy: .public)")
                    once.resume(nil)
                }
            }
        }
    }

    private static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Resumes a continuation once: the recognizer may call back after its final result.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
