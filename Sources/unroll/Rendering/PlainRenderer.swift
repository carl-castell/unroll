import ArgumentParser
import Foundation
import UnrollCore
import UnrollStore

/// Output of `unroll run` without the menu. In a terminal: colors and one live progress line.
/// Elsewhere (pipes, scripts, Shortcuts): plain lines without animation. Either way, files are
/// only listed when they fail; `--dry-run --list` lists what would be copied.
struct PlainRenderer: RunRenderer {
    /// How to show the destination, e.g. "~/unroll-test (Macintosh HD)"; the core reports only the drive.
    var destinationLabel: String?
    /// Colors and a live progress line; only when standard output is a terminal.
    let live: Bool
    private let tracker: TransferTracker
    private let ticker = Ticker()

    init(destinationLabel: String? = nil, live: Bool = isatty(STDOUT_FILENO) != 0) {
        self.destinationLabel = destinationLabel
        self.live = live
        tracker = TransferTracker(styled: live)
    }

    func handle(_ event: SyncEvent) {
        if live, let line = tracker.handle(event) {
            show(line)
        }
        switch event {
        case .checkStarted, .listingProgress, .fileStarted, .fileProgress, .photosImportProgress,
             .existingFilesScanning, .existingFilesIndexing, .fileDone(_, .imported):
            break
        case .existingFilesFound(let count):
            say(mark(true) + " \(Format.notIndexed(count))")
        case .photosImportStarted(let files):
            if live {
                // Photos sends no progress; keep the clock running.
                ticker.start { [tracker] in show(tracker.currentLine()) }
            } else {
                say("Adding \(files) files to Apple Photos… (Photos doesn't report progress; this can take a while)")
            }
        case .photosImportFinished(let result):
            ticker.stop()
            if let error = result.error {
                say(mark(false) + " " + PhotosText.describe(error), error: true)
            } else if result.added > 0 {
                say(mark(true) + " Added \(result.added) files to Apple Photos. " + dim(PhotosText.copyItemsReminder))
            }
        case .checkPassed(.destination, let detail):
            say(mark(true) + " Destination: \(destinationLabel ?? detail)")
        case .checkPassed(let check, let detail):
            say(mark(true) + " \(Self.label(check)): \(detail)")
        case .checkFailed(let check, _):
            say(mark(false) + " \(Self.label(check))")
        case .listingStarted:
            if !live { say("Reading item list…") }
        case .itemsListed(let count):
            say(mark(true) + " Listed \(count) files on the device")
        case .comparisonDone(let summary):
            say(mark(true) + " Compared against index: \(bold("\(summary.newCount) new")) (\(Format.bytes(summary.newBytes))), "
                + "\(summary.alreadyImported) already imported")
            if summary.excludedByVersions > 0 {
                say(dim("  \(summary.excludedByVersions) skipped by the task's original/edited setting"))
            }
            if summary.goneFromDevice > 0 { say(dim("  \(Format.goneFromDevice(summary.goneFromDevice))")) }
            if summary.unavailable > 0 {
                say(dim("  \(summary.unavailable) not available on the device (see `unroll help troubleshooting`)"))
            }
        case .recovered(let result):
            say(dim("Cleaned up an interrupted run: \(result.committed) finished, \(result.discarded) incomplete files removed"))
        case .transferStarted(let count, let bytes):
            if !live { say("Copying \(count) files (\(Format.bytes(bytes)))…") }
        case .fileDone(let entry, .duplicate(let existing)):
            if !live { say("  = \(entry.item.filename) is identical to \(existing), not copied again") }
        case .fileFailed(let entry, let failure):
            say(mark(false) + " \(entry.item.filename): \(Self.describe(failure))")
        case .finished(let summary):
            ticker.stop()
            printSummary(summary)
        }
    }

    func plan(_ plan: SyncPlan, listItems: Bool) {
        printPlan(plan, listItems: listItems)
    }

    func note(_ text: String) {
        say(text)
    }

    func failure(_ message: String, code: ExitCode) {
        say(message, error: true)
    }

    func result(_ code: ExitCode, log: URL?) {
        if let log { say(dim("Log: \(Format.path(log))")) }
    }

    func printPlan(_ plan: SyncPlan, listItems: Bool) {
        let summary = plan.summary
        guard summary.newCount > 0 else {
            print("\nNothing new to copy.")
            return
        }
        print("\n\(Format.newItems(summary))")
        print(Format.space(plan).text)
        if listItems {
            print("\nNew items by month:")
            for month in summary.months {
                let label = String(format: "%04d-%02d", month.year, month.month)
                print("  \(label)  \(String(month.count).leftPadded(to: 6))  \(Format.bytes(month.bytes).leftPadded(to: 10))")
            }
            if !plan.goneFromDevice.isEmpty {
                print("\nIn the destination but no longer on the device (kept):")
                for path in plan.goneFromDevice { print("  \(path)") }
            }
            print("\nNew items:")
            for entry in plan.items {
                print("  \(entry.item.filename)  \(entry.key.captureDate)  \(Format.bytes(entry.item.size))  → \(Format.folder(of: entry, in: plan))")
            }
        }
    }

    /// The result: a clear "Sync complete" line, then the details.
    private func printSummary(_ summary: SyncSummary) {
        let took = TransferTracker.duration(Format.seconds(summary.duration))
        let seconds = Format.seconds(summary.duration)
        let speed = seconds > 1 ? ", \(Format.bytes(Int64(Double(summary.bytes) / seconds)))/s" : ""
        let copied = "Imported \(summary.imported) files (\(Format.bytes(summary.bytes))) in \(took)\(speed)"
        let problems = !summary.failed.isEmpty || summary.photos?.error != nil || summary.stoppedBecause != nil
        say("")
        if summary.cancelled {
            say(bold("Stopped at your request.") + " \(copied).")
        } else if problems {
            say(mark(false) + " " + bold("Sync finished with problems.") + " \(copied).", error: summary.stoppedBecause == nil)
        } else {
            say(mark(true) + " " + bold("Sync complete.") + " \(copied).")
        }
        if summary.duplicates > 0 { say(dim("  \(summary.duplicates) identical to files already in the destination; not copied again")) }
        if !summary.failed.isEmpty { say("  \(summary.failed.count) failed (listed above)") }
        if summary.notAttempted > 0 { say("  \(summary.notAttempted) not copied yet; run the task again to continue") }
        if summary.unavailable > 0 { say("  \(summary.unavailable) not available on the device") }
        if let photos = PhotosText.summary(summary.photos) { say(dim("  \(photos)")) }
    }

    // MARK: Output

    /// Replaces the live progress line.
    private func show(_ line: String) {
        print("\r\u{1B}[2K\(line)", terminator: "")
        fflush(stdout)
    }

    /// Prints a line above the live progress line, which is redrawn on the next update.
    private func say(_ text: String, error: Bool = false) {
        if live { print("\r\u{1B}[2K", terminator: "") }
        if error { printError(text) } else { print(text) }
    }

    private func mark(_ ok: Bool) -> String {
        guard live else { return ok ? "✓" : "✗" }
        return ok ? "\u{1B}[38;5;114m✔\u{1B}[0m" : "\u{1B}[38;5;203m✗\u{1B}[0m"
    }

    private func bold(_ text: String) -> String {
        live ? "\u{1B}[1m\(text)\u{1B}[0m" : text
    }

    private func dim(_ text: String) -> String {
        live ? "\u{1B}[38;5;245m\(text)\u{1B}[0m" : text
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

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// "12 copied earlier are no longer on the device; their copies are kept".
    static func goneFromDevice(_ count: Int) -> String {
        "\(count.formatted()) copied earlier \(count == 1 ? "is" : "are") no longer on the device; \(count == 1 ? "its copy is" : "their copies are") kept"
    }

    /// Files in the destination that its index didn't know yet.
    static func notIndexed(_ count: Int) -> String {
        "Found \(count.formatted()) \(count == 1 ? "file" : "files") in the destination that \(count == 1 ? "isn't" : "aren't") in its index yet; matching items won't be copied again, and the run adds them to the index"
    }

    /// "1,234 new files · 18.4 GB".
    static func newItems(_ summary: PlanSummary) -> String {
        "\(summary.newCount.formatted()) new \(summary.newCount == 1 ? "file" : "files") · \(bytes(summary.newBytes))"
    }

    /// Where the files go and the space left afterwards. `fits` is false when the drive is too full.
    static func space(_ plan: SyncPlan) -> (text: String, fits: Bool) {
        let into = "Into \(destination(plan.destinationRoot, volumeName: plan.destination.volumeName))"
        guard let available = plan.destination.availableBytes else { return (into, true) }
        let left = available - plan.summary.newBytes
        if left < SyncEngine.spaceMargin {
            return ("\(into) · not enough space: \(bytes(available)) free, \(bytes(plan.summary.newBytes)) needed", false)
        }
        return ("\(into) · \(bytes(left)) free after copying", true)
    }

    /// Where an item will go. With a separate Other folder, the camera model decides while copying.
    static func folder(of entry: PlannedItem, in plan: SyncPlan) -> String {
        let folder = entry.folder.isEmpty ? "(destination folder)" : entry.folder
        guard Features.otherFolder, let rule = plan.otherRule else { return folder }
        return "\(folder) or \(rule.otherFolder(for: entry.key.captureDate))"
    }

    /// The terminal's width in columns, or 80 when it can't be read.
    static func terminalWidth() -> Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 20 else { return 80 }
        return Int(size.ws_col)
    }

    /// Breaks text into lines of at most `width` characters at spaces. Continuation lines are
    /// indented by `indent` spaces, to line up with a first line that the caller indents.
    static func wrapped(_ text: String, width: Int, indent: Int = 0) -> String {
        let limit = max(width - indent, 20)
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in paragraph.split(separator: " ") {
                if line.isEmpty {
                    line = String(word)
                } else if line.count + 1 + word.count <= limit {
                    line += " \(word)"
                } else {
                    lines.append(line)
                    line = String(word)
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n" + String(repeating: " ", count: indent))
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

/// Calls a closure every second while running, for steps that send no events.
final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func start(_ tick: @escaping @Sendable () -> Void) {
        lock.withLock {
            task?.cancel()
            task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled { tick() }
                }
            }
        }
    }

    func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
