import CoachKit
import Foundation

/// Every line of every coach conversation, workout or not, appended to one JSON Lines file per
/// day under Application Support/conversations (docs/spec.md 11). The maintainer wants nothing
/// said to the coach lost (COCH-13); workout records only keep lines while a workout runs.
/// Stays on the phone.
final class ConversationLog: @unchecked Sendable {
    static let shared = ConversationLog()

    let directory: URL
    private let queue = DispatchQueue(label: "com.earayu.coachw.conversations")
    private let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "conversations", directoryHint: .isDirectory)
    }

    func append(_ text: String, source: CoachLine.Source) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let line = CoachLine(at: .now, text: text, source: source)
        queue.async { self.write(line) }
    }

    private func write(_ line: CoachLine) {
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        let url = directory.appending(path: "\(day.string(from: line.at)).jsonl")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                ])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            diag("conversation", "append failed: \(error.localizedDescription)")
        }
    }
}
