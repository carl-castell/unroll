import Foundation
import UnrollCore
import UnrollSystem

/// Wording for Apple Photos imports and the finish notification, shared by all interfaces.
enum PhotosText {
    static let copyItemsReminder =
        "Photos keeps them on the destination only if \"Copy items to the Photos library\" is off (Photos → Settings → General)."

    static func describe(_ error: PhotosImportError) -> String {
        switch error {
        case .notAuthorized:
            "macOS didn't allow controlling Photos. Allow it in System Settings → Privacy & Security → Automation "
                + "(your terminal app → Photos), then run the task again."
        case .failed(let reason):
            "Photos reported an error: \(reason)"
        }
    }

    /// One line about the Photos step, or nil if it didn't run.
    static func summary(_ result: PhotosImportResult?) -> String? {
        guard let result else { return nil }
        if let error = result.error {
            return "\(result.added) added to Photos, \(result.pending) not yet (retried next run). \(describe(error))"
        }
        return result.added > 0 ? "\(result.added) added to Apple Photos." : nil
    }

    /// The finish notification, when the task asks for one.
    static func notify(_ task: SyncTask, summary: SyncSummary) async {
        guard task.notify else { return }
        var message = "Imported \(summary.imported) files"
        if !summary.failed.isEmpty { message += ", \(summary.failed.count) failed" }
        if summary.stoppedBecause != nil { message += ". Stopped: the device was disconnected." }
        if summary.cancelled { message += ". Stopped at your request." }
        await Notifier.post(title: "unroll", subtitle: task.name, message: message)
    }
}
