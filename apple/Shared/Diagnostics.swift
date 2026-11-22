import Foundation
import os

/// A small on-device log of what the user tapped and what the workout and voice code did with it,
/// kept in the app container so it survives a relaunch and can be pulled after a run
/// (`xcrun devicectl device copy from ... --source Library/Application\ Support/diagnostics`) or
/// shared from Settings. Built to answer "I tapped it and nothing happened" (COCH-13).
///
/// Same rule as every other log here (AGENTS.md, spec 11): no metric values, no coordinates, no
/// conversation text. Lines also go to the unified log.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    /// Each file is kept under this size; one older file is kept next to it.
    static let maxBytes = 512 * 1024

    let directory: URL
    var fileURL: URL { directory.appending(path: "diag.log") }
    var previousURL: URL { directory.appending(path: "diag.1.log") }

    private let queue = DispatchQueue(label: "com.earayu.coachw.diagnostics")
    private let logger = Logger(subsystem: "com.earayu.coachw", category: "diag")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()
    private var handle: FileHandle?
    private var size = 0

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "diagnostics", directoryHint: .isDirectory)
    }

    /// Records one line, e.g. `Diagnostics.shared.log("watch", "end tapped, state running")`.
    func log(_ category: String, _ message: String) {
        let now = Date()
        logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        queue.async { self.write("\(self.formatter.string(from: now)) [\(category)] \(message)\n") }
    }

    /// Both files, oldest first, as one text; for sharing.
    func contents() -> String {
        queue.sync {
            try? handle?.synchronize()
            return [previousURL, fileURL]
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                .joined()
        }
    }

    private func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if handle == nil { open() }
        if size + data.count > Self.maxBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            logger.error("diagnostics write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: fileURL)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: previousURL)
        try? fm.moveItem(at: fileURL, to: previousURL)
        open()
    }
}

/// Shorthand used across the app.
func diag(_ category: String, _ message: String) {
    Diagnostics.shared.log(category, message)
}
