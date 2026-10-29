import Foundation
import UnrollCore
import UnrollStore

/// Line-oriented output without colors or animation, for pipes, scripts and Shortcuts.
struct PlainRenderer: Sendable {
    /// How to show the destination, e.g. "~/unroll-test (Macintosh HD)"; the core reports only the drive.
    var destinationLabel: String?

    func handle(_ event: SyncEvent) {
        switch event {
        case .checkStarted, .listingProgress, .fileStarted, .fileProgress:
            break
        case .checkPassed(.destination, let detail):
            print("✓ Destination: \(destinationLabel ?? detail)")
        case .checkPassed(let check, let detail):
            print("✓ \(Self.label(check)): \(detail)")
        case .checkFailed(let check, _):
            print("✗ \(Self.label(check))")
        case .listingStarted:
            print("Reading item list…")
        case .itemsListed(let count):
            print("Listed \(count) files")
        case .comparisonDone(let summary):
            print("Compared against index: \(summary.newCount) new (\(Format.bytes(summary.newBytes))), "
                + "\(summary.alreadyImported) already imported")
            if summary.excludedByVersions > 0 {
                print("  \(summary.excludedByVersions) skipped by the task's original/edited setting")
            }
            if summary.unavailable > 0 {
                print("  \(summary.unavailable) not available on the device (see `unroll help troubleshooting`)")
            }
        case .recovered(let result):
            print("Cleaned up an interrupted run: \(result.committed) finished, \(result.discarded) incomplete files removed")
        case .transferStarted(let count, let bytes):
            print("\nCopying \(count) files (\(Format.bytes(bytes)))…")
        case .fileDone(let entry, .imported(let path)):
            print("  ✓ \(path)  \(Format.bytes(entry.item.size))")
        case .fileDone(let entry, .duplicate(let existing)):
            print("  = \(entry.item.filename) is identical to \(existing), not copied again")
        case .fileFailed(let entry, let failure):
            print("  ✗ \(entry.item.filename): \(Self.describe(failure))")
        case .finished(let summary):
            printSummary(summary)
        }
    }

    func printPlan(_ plan: SyncPlan, listItems: Bool) {
        let summary = plan.summary
        guard summary.newCount > 0 else {
            print("\nNothing new to copy.")
            return
        }
        print("\nNew items by month:")
        for month in summary.months {
            let label = String(format: "%04d-%02d", month.year, month.month)
            print("  \(label)  \(String(month.count).leftPadded(to: 6))  \(Format.bytes(month.bytes).leftPadded(to: 10))")
        }
        print("\nDestination folders in \(Format.destination(plan.destinationRoot, volumeName: plan.destination.volumeName)):")
        for folder in summary.folders.prefix(listItems ? .max : 12) {
            print("  \(folder)")
        }
        if !listItems, summary.folders.count > 12 {
            print("  … \(summary.folders.count - 12) more")
        }
        if listItems {
            print("\nNew items:")
            for entry in plan.items {
                print("  \(entry.folder)/\(entry.item.filename)  \(entry.key.captureDate)  \(Format.bytes(entry.item.size))")
            }
        }
    }

    private func printSummary(_ summary: SyncSummary) {
        let seconds = Double(summary.duration.components.seconds) + Double(summary.duration.components.attoseconds) / 1e18
        let speed = seconds > 0 ? " at \(Format.bytes(Int64(Double(summary.bytes) / seconds)))/s" : ""
        print("\nImported \(summary.imported) files (\(Format.bytes(summary.bytes)))\(speed) in \(Int(seconds.rounded())) s")
        if summary.duplicates > 0 { print("  \(summary.duplicates) duplicates of files already in the destination") }
        if !summary.failed.isEmpty { print("  \(summary.failed.count) failed") }
        if summary.notAttempted > 0 { print("  \(summary.notAttempted) not attempted") }
        if summary.unavailable > 0 { print("  \(summary.unavailable) not available on the device") }
    }

    static func describe(_ failure: ItemFailure) -> String {
        switch failure {
        case .downloadFailed(let reason): "download failed: \(reason)"
        case .incomplete(let expected, let actual): "incomplete (\(actual) of \(expected) bytes)"
        case .writeFailed(let reason): "couldn't write: \(reason)"
        case .deviceDisconnected: "the device was disconnected"
        }
    }

    static func label(_ check: Check) -> String {
        switch check {
        case .destination: "Destination"
        case .device: "Device"
        }
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "~/unroll-test", "/Volumes/Photos-SSD/Photos".
    static func path(_ url: URL) -> String {
        let path = VolumeResolver.displayPath(url)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The folder, with its drive in brackets: "~/unroll-test (Macintosh HD)".
    static func destination(_ url: URL, volumeName: String) -> String {
        "\(path(url)) (\(volumeName))"
    }

    /// Like `destination(_:volumeName:)`; when the drive isn't connected, the folder's path on the drive.
    static func destination(_ destination: Destination, resolver: VolumeResolver) -> String {
        if let resolved = resolver.resolve(destination) {
            return self.destination(resolved.root, volumeName: destination.volumeName)
        }
        return "/\(destination.path) (\(destination.volumeName))"
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
