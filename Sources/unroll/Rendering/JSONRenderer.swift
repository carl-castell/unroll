import ArgumentParser
import Foundation
import UnrollCore
import UnrollStore

/// How a non-interactive command reports progress and results.
protocol RunRenderer: Sendable {
    func handle(_ event: SyncEvent)
    func plan(_ plan: SyncPlan, listItems: Bool)
    /// Information for the user that isn't an event, e.g. "Dry run: nothing was copied."
    func note(_ text: String)
    func failure(_ message: String, code: ExitCode)
    /// The last output of a command.
    func result(_ code: ExitCode, log: URL?)
}

/// One JSON object per line ("JSON Lines"), for scripts and Shortcuts. Every object has `event`
/// and `time`; the first is `start` with the format version, the last is `result` with the exit code.
/// Nothing else is written to standard output.
struct JSONRenderer: RunRenderer {
    static let formatVersion = 1

    func start(task: SyncTask, dryRun: Bool) {
        emit("start", ["unroll": unrollVersion, "format": Self.formatVersion, "task": task.name, "dryRun": dryRun])
    }

    func handle(_ event: SyncEvent) {
        switch event {
        case .checkStarted, .listingProgress, .fileProgress, .photosImportProgress, .existingFilesScanning:
            break
        case .existingFilesFound(let count):
            emit("existingFiles", ["count": count])
        case .existingFilesIndexing(let done, let total):
            if done == total { emit("existingFilesIndexed", ["count": total]) }
        case .photosImportStarted(let files):
            emit("photosStarted", ["files": files])
        case .photosImportFinished(let result):
            var fields: [String: Any] = ["added": result.added, "pending": result.pending]
            if let error = result.error {
                fields["error"] = error == .notAuthorized ? "notAuthorized" : "failed"
                fields["message"] = PhotosText.describe(error)
            }
            emit("photosFinished", fields)
        case .checkPassed(let check, let detail):
            emit("check", ["check": check.rawValue, "status": "passed", "detail": detail])
        case .checkFailed(let check, let error):
            emit("check", ["check": check.rawValue, "status": "failed", "message": error.message])
        case .listingStarted:
            emit("listing", [:])
        case .itemsListed(let count):
            emit("listed", ["count": count])
        case .comparisonDone(let summary):
            emit("compared", [
                "new": summary.newCount, "bytes": summary.newBytes, "alreadyImported": summary.alreadyImported,
                "excludedByVersions": summary.excludedByVersions, "unavailable": summary.unavailable,
                "existingFiles": summary.existingFiles, "goneFromDevice": summary.goneFromDevice,
            ])
        case .recovered(let result):
            emit("recovered", ["committed": result.committed, "discarded": result.discarded])
        case .transferStarted(let files, let bytes):
            emit("transferStarted", ["files": files, "bytes": bytes])
        case .fileStarted(let entry, let index):
            emit("fileStarted", ["index": index, "filename": entry.item.filename, "bytes": entry.item.size])
        case .fileDone(let entry, .imported(let path)):
            emit("fileDone", ["filename": entry.item.filename, "outcome": "imported", "path": path, "bytes": entry.item.size])
        case .fileDone(let entry, .duplicate(let existing)):
            emit("fileDone", ["filename": entry.item.filename, "outcome": "duplicate", "duplicateOf": existing, "bytes": entry.item.size])
        case .fileFailed(let entry, let failure):
            emit("fileFailed", ["filename": entry.item.filename, "reason": Self.code(failure), "message": PlainRenderer.describe(failure)])
        case .finished(let summary):
            var fields: [String: Any] = [
                "imported": summary.imported, "duplicates": summary.duplicates, "failed": summary.failed.count,
                "unavailable": summary.unavailable, "notAttempted": summary.notAttempted, "bytes": summary.bytes,
                "seconds": NSDecimalNumber(string: String(format: "%.1f", Format.seconds(summary.duration))), "cancelled": summary.cancelled,
            ]
            if let stopped = summary.stoppedBecause { fields["stopped"] = stopped.message }
            if let photos = summary.photos {
                fields["addedToPhotos"] = photos.added
                fields["pendingForPhotos"] = photos.pending
                fields["photosDeferred"] = photos.deferred
            }
            emit("finished", fields)
        }
    }

    func plan(_ plan: SyncPlan, listItems: Bool) {
        let summary = plan.summary
        var fields: [String: Any] = [
            "new": summary.newCount,
            "bytes": summary.newBytes,
            "destination": plan.destinationRoot.path,
            "months": summary.months.map { ["month": String(format: "%04d-%02d", $0.year, $0.month), "count": $0.count, "bytes": $0.bytes] },
            "folders": summary.folders,
        ]
        if let reason = plan.confirmation { fields["confirmationRequired"] = reason.rawValue }
        if listItems {
            fields["items"] = plan.items.map {
                ["filename": $0.item.filename, "folder": $0.folder, "captureDate": $0.key.captureDate.description, "bytes": $0.item.size]
            }
        }
        emit("plan", fields)
    }

    func note(_ text: String) {
        emit("note", ["message": text])
    }

    func failure(_ message: String, code: ExitCode) {
        emit("error", ["message": message, "exitCode": Int(code.rawValue)])
        // Also on standard error, for people watching a script.
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    func result(_ code: ExitCode, log: URL?) {
        var fields: [String: Any] = ["exitCode": Int(code.rawValue)]
        if let log { fields["log"] = log.path }
        emit("result", fields)
    }

    private func emit(_ event: String, _ fields: [String: Any]) {
        var object = fields
        object["event"] = event
        object["time"] = Date().ISO8601Format()
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }

    private static func code(_ failure: ItemFailure) -> String {
        switch failure {
        case .downloadFailed: "downloadFailed"
        case .incomplete: "incomplete"
        case .writeFailed: "writeFailed"
        case .deviceDisconnected: "deviceDisconnected"
        }
    }
}
