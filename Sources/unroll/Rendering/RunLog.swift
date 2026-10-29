import Foundation
import UnrollCore

/// A plain-text record of each run in `~/Library/Logs/unroll/`, one file per day.
/// Logging is best effort: if the file can't be written, the run continues without it.
final class RunLog: @unchecked Sendable {
    /// Log files older than this are removed when a new run starts.
    static let retention: TimeInterval = 90 * 24 * 3600

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/unroll", directoryHint: .isDirectory)
    }

    let url: URL
    private let handle: FileHandle
    private let lock = NSLock()

    init?(task: SyncTask, dryRun: Bool) {
        let directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.removeOldLogs(in: directory)
        url = directory.appending(path: "unroll-\(Self.day.string(from: Date())).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        _ = try? handle.seekToEnd()
        write("")
        write("=== \(dryRun ? "Dry run" : "Run") of \"\(task.name)\": \(task.device.name) → /\(task.destination.path) (\(task.destination.volumeName))")
    }

    deinit {
        try? handle.close()
    }

    func record(_ event: SyncEvent) {
        if let line = Self.line(for: event) { write(line) }
    }

    func write(_ text: String) {
        let line = text.isEmpty ? "\n" : "\(Self.time.string(from: Date()))  \(text)\n"
        lock.withLock { try? handle.write(contentsOf: Data(line.utf8)) }
    }

    private static func line(for event: SyncEvent) -> String? {
        switch event {
        case .checkStarted, .listingStarted, .listingProgress, .fileStarted, .fileProgress,
             .existingFilesScanning, .existingFilesIndexing:
            nil
        case .existingFilesFound(let count):
            "found \(count) files already in the destination without an index; they are recognized and indexed"
        case .checkPassed(let check, let detail):
            "\(check.rawValue) ok: \(detail)"
        case .checkFailed(let check, let error):
            "\(check.rawValue) failed: \(error.message)"
        case .itemsListed(let count):
            "listed \(count) files"
        case .comparisonDone(let summary):
            "compared: \(summary.newCount) new (\(summary.newBytes) bytes), \(summary.alreadyImported) already imported, "
                + "\(summary.excludedByVersions) excluded by versions, \(summary.unavailable) unavailable"
        case .recovered(let result):
            "recovered interrupted run: \(result.committed) committed, \(result.discarded) discarded"
        case .transferStarted(let files, let bytes):
            "copying \(files) files (\(bytes) bytes)"
        case .fileDone(let entry, .imported(let path)):
            "imported \(entry.item.filename) → \(path)"
        case .fileDone(let entry, .duplicate(let existing)):
            "duplicate \(entry.item.filename) = \(existing)"
        case .fileFailed(let entry, let failure):
            "FAILED \(entry.item.filename): \(PlainRenderer.describe(failure))"
        case .photosImportStarted(let files):
            "adding \(files) files to Apple Photos"
        case .photosImportProgress:
            nil
        case .photosImportFinished(let result):
            result.error.map { "Photos: \(result.added) added, \(result.pending) pending: \(PhotosText.describe($0))" }
                ?? "Photos: \(result.added) added"
        case .finished(let summary):
            "finished: \(summary.imported) imported, \(summary.duplicates) duplicates, \(summary.failed.count) failed, "
                + "\(summary.unavailable) unavailable, \(summary.notAttempted) not attempted"
                + (summary.cancelled ? ", cancelled" : "")
                + (summary.stoppedBecause.map { ", stopped: \($0.message)" } ?? "")
        }
    }

    private static func removeOldLogs(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-retention)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where file.lastPathComponent.hasPrefix("unroll-") && file.pathExtension == "log" {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
