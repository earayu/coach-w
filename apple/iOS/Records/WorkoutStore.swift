import CoachKit
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.earayu.coachw", category: "records")

/// Finished workouts kept on this iPhone only, one JSON file each in Application Support
/// (docs/spec.md 2 step 6, 11). The full workout and route live in Apple Health.
@MainActor
@Observable
final class WorkoutStore {
    static let shared = WorkoutStore()

    /// Newest first.
    private(set) var records: [WorkoutRecord] = []

    @ObservationIgnored private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "workouts", directoryHint: .isDirectory)
        load()
    }

    func save(_ record: WorkoutRecord) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // protected while the phone is locked, but writable once it was unlocked after boot
            try record.encoded().write(to: url(for: record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            records.removeAll { $0.id == record.id }
            records.insert(record, at: 0)
            records.sort { $0.startedAt > $1.startedAt }
        } catch {
            log.error("saving workout record failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(_ record: WorkoutRecord) {
        try? FileManager.default.removeItem(at: url(for: record.id))
        records.removeAll { $0.id == record.id }
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        records = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? WorkoutRecord.decode(Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}
