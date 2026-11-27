import AVFoundation
import Foundation
import Speech
import os

private let log = Logger(subsystem: "com.earayu.coachw", category: "offline-voice")

/// Keeps what the athlete says while the coach is unreachable (spec 7.4, COCH-15).
///
/// Captures PCM buffers from LiveKit's already-running audio engine (which stays alive in the
/// background via always-prepared recording mode) instead of starting a competing `AVAudioRecorder`
/// that iOS rejects while the phone is in a pocket (COCH-22). Once the link is back, the file is
/// transcribed on the phone and the text goes to the conversation log and to the coach.
/// The audio stays in Application Support/offline-voice and is deleted once transcribed; a file
/// that could not be transcribed is kept. Nothing is logged but sizes and outcomes.
@MainActor
final class OfflineVoiceRecorder: NSObject {
    static let shared = OfflineVoiceRecorder()

    private enum State {
        case idle
        case starting(writer: PCMWriter, startedAt: Date)
        case recording(writer: PCMWriter, startedAt: Date)
    }

    /// Hooks into `VoiceSession`'s LiveKit `AudioManager` so only `VoiceSession` imports LiveKit.
    var startCapture: (@MainActor (@escaping @Sendable (AVAudioPCMBuffer) -> Void) async -> Bool)?
    var stopCapture: (@MainActor (_ releaseEngine: Bool) -> Void)?

    private var state: State = .idle
    /// A recording stopped (to hand the microphone to the coach) but not transcribed yet.
    private var pending: (url: URL, duration: TimeInterval, began: Date)?
    private let directory = URL.applicationSupportDirectory.appending(path: "offline-voice", directoryHint: .isDirectory)

    /// Shorter recordings hold nothing worth transcribing.
    static let minDuration: TimeInterval = 1.5

    var isRecording: Bool {
        switch state {
        case .starting, .recording: true
        case .idle: false
        }
    }

    /// Starts keeping the microphone through LiveKit's shared audio engine.
    func start() {
        guard case .idle = state else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Self.fileStamp.string(from: .now)
            let suffix = String(UUID().uuidString.prefix(8))
            let url = directory.appending(path: "\(stamp)-\(suffix).m4a")
            let writer = try PCMWriter(url: url)
            let began = Date.now
            state = .starting(writer: writer, startedAt: began)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let started = await self.startCapture?({ buffer in writer.append(buffer) }) ?? false
                guard case .starting(let active, _) = self.state, active === writer else {
                    // Stopped while waiting for the old room to finish disconnecting.
                    if started { self.stopCapture?(false) }
                    _ = writer.finish()
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                guard started else {
                    self.state = .idle
                    _ = writer.finish()
                    try? FileManager.default.removeItem(at: url)
                    diag("offline-voice", "recorder did not start: audio engine unavailable")
                    return
                }
                self.state = .recording(writer: writer, startedAt: began)
                diag("offline-voice", "recording while the coach is unreachable")
            }
        } catch {
            diag("offline-voice", "could not start recording: \(error.localizedDescription)")
        }
    }

    /// Stops tapping the microphone and keeps the recording for `stopAndTranscribe`.
    /// Pass `releaseEngine: false` when handing straight back to LiveKit's microphone publish so
    /// the audio engine never stops and restarts in the background.
    func stopRecording(releaseEngine: Bool = false) {
        switch state {
        case .idle:
            return
        case .starting(let writer, _):
            state = .idle
            stopCapture?(releaseEngine)
            _ = writer.finish()
            try? FileManager.default.removeItem(at: writer.url)
        case .recording(let writer, let began):
            state = .idle
            stopCapture?(releaseEngine)
            let duration = writer.finish()
            guard duration >= Self.minDuration else {
                try? FileManager.default.removeItem(at: writer.url)
                return
            }
            if let old = pending { diag("offline-voice", "kept an untranscribed recording of \(Int(old.duration))s") }
            pending = (writer.url, duration, began)
            diag("offline-voice", "stopped after \(Int(duration))s")
        }
    }

    /// Stops and transcribes. Returns the text said offline, or nil when there was nothing.
    func stopAndTranscribe(releaseEngine: Bool = false) async -> String? {
        stopRecording(releaseEngine: releaseEngine)
        guard let recording = pending else { return nil }
        pending = nil
        let url = recording.url, began = recording.began
        diag("offline-voice", "transcribing on the phone")
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

/// Uniquely owned PCM buffer handed off from WebRTC's callback thread to the writer's serial queue.
private struct OwnedPCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Writes PCM buffers from WebRTC's audio callback thread to a 16 kHz mono AAC file on a serial
/// queue, converting on the fly whenever the hardware sample rate or route changes.
private final class PCMWriter: @unchecked Sendable {
    static let targetRate: Double = 16_000
    let url: URL

    private let queue = DispatchQueue(label: "com.earayu.coachw.offline-voice")
    private let targetFormat: AVAudioFormat
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var writtenFrames: Int64 = 0
    private var closed = false

    init(url: URL) throws {
        self.url = url
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.targetRate, channels: 1, interleaved: false
        ) else {
            throw NSError(domain: "OfflineVoiceRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid audio format"])
        }
        self.targetFormat = format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.targetRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        self.file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.clone(buffer) else { return }
        let owned = OwnedPCMBuffer(buffer: copy)
        queue.async { [self] in
            self.writeOnQueue(owned.buffer)
        }
    }

    private func writeOnQueue(_ copy: AVAudioPCMBuffer) {
        guard !closed, let file else { return }
        do {
            if copy.format == targetFormat {
                try file.write(from: copy)
                writtenFrames += Int64(copy.frameLength)
                return
            }
            if converter?.inputFormat != copy.format {
                converter = AVAudioConverter(from: copy.format, to: targetFormat)
            }
            guard let converter else { return }
            let ratio = targetFormat.sampleRate / copy.format.sampleRate
            let capacity = AVAudioFrameCount((Double(copy.frameLength) * ratio).rounded(.up)) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var convertError: NSError?
            let status = converter.convert(to: out, error: &convertError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return copy
            }
            if (status == .haveData || status == .inputRanDry), out.frameLength > 0 {
                try file.write(from: out)
                writtenFrames += Int64(out.frameLength)
            }
        } catch {
            log.error("writing offline audio failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finish() -> TimeInterval {
        queue.sync {
            closed = true
            file = nil
            converter = nil
            return Double(writtenFrames) / Self.targetRate
        }
    }

    private static func clone(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = src.frameLength
        guard frames > 0, let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: frames) else {
            return nil
        }
        dst.frameLength = frames
        let srcList = UnsafeMutableAudioBufferListPointer(src.mutableAudioBufferList)
        let dstList = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
        guard srcList.count == dstList.count else { return nil }
        for i in 0..<srcList.count {
            let bytes = Int(srcList[i].mDataByteSize)
            if let s = srcList[i].mData, let d = dstList[i].mData, bytes > 0 {
                memcpy(d, s, min(bytes, Int(dstList[i].mDataByteSize)))
                dstList[i].mDataByteSize = UInt32(bytes)
            }
        }
        return dst
    }
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
