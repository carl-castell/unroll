import Foundation
import UnrollCore

/// Turns sync events into one progress line: a colored bar, percentage, count, current file,
/// speed and time left. Used by the menu and by `unroll run` in a terminal.
final class TransferTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let styled: Bool
    private var totalFiles = 0
    private var totalBytes: Int64 = 1
    private var start = ContinuousClock.now
    private var doneFiles = 0
    private var doneBytes: Int64 = 0
    private var currentBytes: Int64 = 0
    private var currentName = ""
    private var lastLine = ContinuousClock.now - .seconds(1)
    private var stopping = false
    /// A phase without byte progress: reading or indexing files already there, adding to Photos.
    private var phase: (label: String, done: Int?, total: Int?, since: ContinuousClock.Instant)?

    init(styled: Bool) {
        self.styled = styled
    }

    /// The new progress line, or nil if nothing worth redrawing happened.
    func handle(_ event: SyncEvent) -> String? {
        lock.withLock {
            switch event {
            case .existingFilesScanning(let done, let total):
                phase = ("Reading files already in the destination", done, total, phase?.since ?? .now)
            case .existingFilesIndexing(let done, let total):
                phase = ("Indexing files already in the destination", done, total, phase?.since ?? .now)
            case .transferStarted(let files, let bytes):
                phase = nil
                totalFiles = files
                totalBytes = max(bytes, 1)
                start = .now
            case .fileStarted(let entry, _):
                currentName = entry.item.filename
                currentBytes = 0
            case .fileProgress(_, let bytes):
                currentBytes = bytes
            case .fileDone(let entry, _), .fileFailed(let entry, _):
                doneFiles += 1
                doneBytes += entry.item.size
                currentBytes = 0
            case .photosImportStarted(let files):
                phase = ("Adding \(files) files to Apple Photos", nil, nil, .now)
            default:
                return nil
            }
            // Redraw at most ten times a second.
            guard ContinuousClock.now - lastLine > .milliseconds(100) else { return nil }
            lastLine = .now
            return line()
        }
    }

    /// After Ctrl-C: the line says the run stops once the current file is done.
    func markStopping() {
        lock.withLock { stopping = true }
    }

    func currentLine() -> String {
        lock.withLock { line() }
    }

    /// True during a phase without events of its own, so the caller keeps the clock running.
    var isWaiting: Bool {
        lock.withLock { phase != nil }
    }

    private func line() -> String {
        if let phase {
            let elapsed = Self.duration(Format.seconds(phase.since.duration(to: .now)))
            if let done = phase.done, let total = phase.total, total > 0 {
                return "\(bar(Double(done) / Double(total))) \(muted("\(phase.label)… \(done) of \(total)"))"
            }
            // Photos doesn't report progress to scripts, so show the time spent instead.
            return "\(phase.label)… \(muted(elapsed))"
        }
        let bytes = doneBytes + currentBytes
        let fraction = min(Double(bytes) / Double(totalBytes), 1)
        let elapsed = Format.seconds(start.duration(to: .now))
        let speed = elapsed > 0 ? Double(bytes) / elapsed : 0
        // Fixed-width fields first and the file name last, so the line doesn't jump as names change.
        let count = String(min(doneFiles + 1, totalFiles)).leftPadded(to: String(totalFiles).count)
        var details = ["\(count)/\(totalFiles)"]
        if elapsed > 2, speed > 0 {
            details.append("\(Format.bytes(Int64(speed)))/s".leftPadded(to: 11))
            details.append("\(Self.duration(Double(totalBytes - bytes) / speed)) left".leftPadded(to: 12))
        }
        if stopping { details.append("stopping after this file") }
        details.append(currentName)
        return "\(bar(fraction)) \(muted(details.joined(separator: " · ")))"
    }

    /// "━━━━━━━━━━──────────  45%": the done part green, the rest dim.
    private func bar(_ fraction: Double) -> String {
        let width = 24
        let filled = Int((fraction * Double(width)).rounded(.down))
        let done = String(repeating: "━", count: filled)
        let left = String(repeating: "─", count: width - filled)
        let percent = String(format: "%3d%%", Int(fraction * 100))
        guard styled else { return "\(done)\(left) \(percent)" }
        return "\u{1B}[38;5;114m\(done)\u{1B}[38;5;238m\(left)\u{1B}[0m \u{1B}[1m\(percent)\u{1B}[0m"
    }

    private func muted(_ text: String) -> String {
        styled ? "\u{1B}[38;5;245m\(text)\u{1B}[0m" : text
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
