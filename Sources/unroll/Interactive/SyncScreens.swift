import Foundation
import Noora
import UnrollCore
import UnrollStore

/// Runs a task, or previews it: checks, listing and comparison, each as a progress step.
struct SyncScreen: Screen {
    enum Mode {
        case run, preview
    }

    let taskID: UUID
    let mode: Mode

    func run(_ app: AppContext) async -> Next {
        guard let task = app.task(taskID) else {
            app.showError("That task no longer exists.")
            return .mainMenu
        }
        try? app.store.saveLastUsedTask(task.id)
        print("")
        let plan: SyncPlan
        do {
            plan = try await Self.makePlan(for: task, app: app)
        } catch {
            app.show(error)
            return .mainMenu
        }
        switch mode {
        case .preview: return .screen(PreviewScreen(task: task, plan: plan))
        case .run: return await TransferFlow.run(task: task, plan: plan, app: app)
        }
    }

    static func makePlan(for task: SyncTask, app: AppContext) async throws -> SyncPlan {
        let engine = app.engine
        let volume = task.destination.volumeName
        let destination = try await app.noora.progressStep(
            message: "Checking destination \"\(volume)\"",
            successMessage: "Destination \"\(volume)\" is connected",
            errorMessage: "Destination \"\(volume)\" isn't available",
            showSpinner: true
        ) { @Sendable _ in try engine.checkDestination(for: task, events: { _ in }) }

        let device = task.device.name
        let session: any DeviceSession
        do {
            session = try await app.noora.progressStep(
                message: "Connecting to \"\(device)\"",
                successMessage: "\"\(device)\" is connected",
                errorMessage: "\"\(device)\" is locked or doesn't trust this Mac yet",
                showSpinner: true
            ) { @Sendable _ in try await engine.connectDevice(for: task, unlockTimeout: .seconds(2), events: { _ in }) }
        } catch SyncError.deviceLocked(_) {
            session = try await app.noora.progressStep(
                message: "Unlock \"\(device)\" and tap Trust if asked…",
                successMessage: "\"\(device)\" is connected",
                errorMessage: "\"\(device)\" is still locked",
                showSpinner: true
            ) { @Sendable _ in try await engine.connectDevice(for: task, unlockTimeout: .seconds(60), events: { _ in }) }
        }

        let plan = try await app.noora.progressStep(
            message: "Reading item list",
            successMessage: "Read item list",
            errorMessage: "Couldn't read the item list",
            showSpinner: true
        ) { @Sendable update in
            try await engine.plan(for: task, destination: destination, session: session) { event in
                switch event {
                case .listingProgress(let percent): update("Reading item list… \(percent)%")
                case .itemsListed(let count): update("Comparing \(count) files against the index…")
                default: break
                }
            }
        }

        let summary = plan.summary
        let compared: TerminalText = "Compared against index → \(.primary("\(summary.newCount) new")) (\(Format.bytes(summary.newBytes))), \(summary.alreadyImported) already imported"
        app.printStepLine(compared)
        if summary.excludedByVersions > 0 {
            app.printMuted("\(summary.excludedByVersions) skipped by the task's original/edited setting")
        }
        if summary.unavailable > 0 {
            app.printMuted("\(summary.unavailable) not available on the device; see Help → Troubleshooting")
        }
        return plan
    }
}

/// The dry-run result: what would be copied, then Run now / Show full list / Back.
struct PreviewScreen: Screen {
    enum Action: Equatable {
        case runNow, list, back
    }

    let task: SyncTask
    let plan: SyncPlan

    func run(_ app: AppContext) async -> Next {
        let summary = plan.summary
        guard summary.newCount > 0 else {
            await app.engine.close(plan)
            app.noora.success("\"\(task.name)\" is up to date. Nothing new to copy.")
            return .mainMenu
        }

        print("")
        app.noora.table(
            headers: ["Month", "New items", "Size"],
            rows: summary.months.map { [String(format: "%04d-%02d", $0.year, $0.month), "\($0.count)", Format.bytes($0.bytes)] }
                + [["Total", "\(summary.newCount)", Format.bytes(summary.newBytes)]]
        )
        print(app.noora.format("\(.muted("Into")) \(VolumeResolver.displayPath(plan.destinationRoot))"))
        let folders = summary.folders
        print(app.noora.format("\(.muted("Folders")) \(folders.prefix(6).joined(separator: ", "))\(folders.count > 6 ? " and \(folders.count - 6) more" : "")"))

        while true {
            let choices = [Choice("Run now", Action.runNow), Choice("Show full list", .list), Choice("Back", .back)]
            switch app.noora.menu("Copy these \(summary.newCount) items?", choices) {
            case .runNow:
                // Copy exactly what was previewed, unless the device or destination changed meanwhile.
                guard await app.engine.isStillValid(plan, for: task) else {
                    await app.engine.close(plan)
                    app.noora.warning("The device or destination changed since the preview. Scanning again.")
                    return .screen(SyncScreen(taskID: task.id, mode: .run))
                }
                return await TransferFlow.run(task: task, plan: plan, app: app)
            case .list:
                let rows = plan.items.map { [$0.item.filename, $0.key.captureDate.description, Format.bytes($0.item.size), $0.folder] }
                try? app.noora.paginatedTable(headers: ["File", "Taken", "Size", "Folder"], rows: rows, pageSize: 20)
            case .back:
                await app.engine.close(plan)
                return .mainMenu
            }
        }
    }
}

/// Confirmation (when the rules require it), the transfer with a progress line, and the summary.
@MainActor
enum TransferFlow {
    static func run(task: SyncTask, plan: SyncPlan, app: AppContext) async -> Next {
        let engine = app.engine
        guard !plan.items.isEmpty else {
            await engine.close(plan)
            app.noora.success("\"\(task.name)\" is up to date. Nothing new to copy.")
            return .mainMenu
        }
        let totalBytes = plan.items.reduce(Int64(0)) { $0 + $1.item.size }

        if let reason = plan.confirmation {
            app.noora.info(.alert("\(confirmationTitle(reason, task: task))", takeaways: [
                "Task: \(task.name)",
                "From: \(task.device.name)",
                "To: \(VolumeResolver.displayPath(plan.destinationRoot)) (\(plan.destination.volumeName))",
                "\(plan.items.count) files, \(Format.bytes(totalBytes))",
            ]))
            guard app.noora.yesOrNoChoicePrompt(question: "Copy them now?", defaultAnswer: true) else {
                await engine.close(plan)
                app.noora.info("Nothing was copied.")
                return .mainMenu
            }
        }

        let tracker = TransferTracker(totalFiles: plan.items.count, totalBytes: totalBytes)
        let summary: SyncSummary
        do {
            summary = try await app.noora.progressStep(
                message: "Copying \(plan.items.count) files (\(Format.bytes(totalBytes)))",
                successMessage: "Copied",
                errorMessage: "Copying failed",
                showSpinner: true
            ) { @Sendable update in
                let work = Task {
                    try await engine.execute(plan, confirmed: true) { event in
                        if let line = tracker.handle(event) { update(line) }
                    }
                }
                // Ctrl-C finishes the current file, then stops; nothing incomplete is recorded.
                let interrupt = CtrlCHandler {
                    work.cancel()
                    tracker.markStopping()
                    update(tracker.currentLine())
                }
                defer { interrupt.stop() }
                return try await work.value
            }
        } catch {
            await engine.close(plan)
            app.show(error)
            return .mainMenu
        }
        await engine.close(plan)
        record(task: task, summary: summary, app: app)
        showSummary(summary, plan: plan, app: app)
        return .mainMenu
    }

    private static func confirmationTitle(_ reason: ConfirmationReason, task: SyncTask) -> String {
        switch reason {
        case .firstRun: "This is the first run of \"\(task.name)\". It asks once before copying."
        case .destinationOrDeviceChanged: "The task's device or destination changed, so it asks again before copying."
        case .indexRebuilt: "The destination's index was rebuilt, so it asks again before copying."
        case .indexEmpty: "The destination's index is empty, so everything would be copied."
        }
    }

    /// Saves the last run and what was confirmed, so the next run starts without asking.
    private static func record(task: SyncTask, summary: SyncSummary, app: AppContext) {
        guard var current = app.task(task.id) else { return }
        current.lastRun = Date()
        if let indexID = summary.indexID {
            current.confirmation = ConfirmationSnapshot(deviceID: task.device.id, destination: task.destination, indexID: indexID)
        }
        try? app.save(current)
    }

    private static func showSummary(_ summary: SyncSummary, plan: SyncPlan, app: AppContext) {
        var details: [TerminalText] = ["Into \(VolumeResolver.displayPath(plan.destinationRoot))"]
        if summary.duplicates > 0 { details.append("\(summary.duplicates) identical to files already there; not copied again") }
        if summary.unavailable > 0 { details.append("\(summary.unavailable) not available on the device; see Help → Troubleshooting") }
        if summary.notAttempted > 0 { details.append("\(summary.notAttempted) not copied yet; run the task again to continue") }
        for failure in summary.failed.prefix(5) {
            details.append("\(failure.filename): \(PlainRenderer.describe(failure.reason))")
        }
        if summary.failed.count > 5 { details.append("… and \(summary.failed.count - 5) more failures") }

        let headline = "Imported \(summary.imported) files (\(Format.bytes(summary.bytes)))"
        if let stopped = summary.stoppedBecause {
            app.noora.error(.alert("Stopped: \(stopped.message)", takeaways: ["\(headline)"] + details))
        } else if !summary.failed.isEmpty {
            app.noora.error(.alert("\(headline), \(summary.failed.count) failed", takeaways: details))
        } else if summary.cancelled {
            app.noora.warning(.alert("\(headline). Stopped at your request.", takeaway: details.dropFirst().first))
        } else {
            app.noora.success(.alert("\(headline)", takeaways: details))
        }
    }
}

/// Turns transfer events into a progress line: bar, count, current file, speed, time left.
final class TransferTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalFiles: Int
    private let totalBytes: Int64
    private let start = ContinuousClock.now
    private var doneFiles = 0
    private var doneBytes: Int64 = 0
    private var currentBytes: Int64 = 0
    private var currentName = ""
    private var lastLine = ContinuousClock.now - .seconds(1)
    private var stopping = false

    init(totalFiles: Int, totalBytes: Int64) {
        self.totalFiles = totalFiles
        self.totalBytes = max(totalBytes, 1)
    }

    /// The new progress line, or nil if nothing worth redrawing happened.
    func handle(_ event: SyncEvent) -> String? {
        lock.withLock {
            switch event {
            case .fileStarted(let entry, _):
                currentName = entry.item.filename
                currentBytes = 0
            case .fileProgress(_, let bytes):
                currentBytes = bytes
                // Redraw at most ten times a second.
                guard ContinuousClock.now - lastLine > .milliseconds(100) else { return nil }
            case .fileDone(let entry, _), .fileFailed(let entry, _):
                doneFiles += 1
                doneBytes += entry.item.size
                currentBytes = 0
            default:
                return nil
            }
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

    private func line() -> String {
        let bytes = doneBytes + currentBytes
        let fraction = min(Double(bytes) / Double(totalBytes), 1)
        let filled = Int(fraction * 20)
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
        let elapsed = Double((ContinuousClock.now - start).components.seconds) + 0.001
        let speed = Double(bytes) / elapsed
        var parts = ["\(bar) \(Int(fraction * 100))%", "\(min(doneFiles + 1, totalFiles))/\(totalFiles)", currentName]
        if elapsed > 2, speed > 0 {
            parts.append("\(Format.bytes(Int64(speed)))/s")
            parts.append("\(Self.duration(Double(totalBytes - bytes) / speed)) left")
        }
        if stopping { parts.append("— stopping after this file") }
        return parts.joined(separator: "  ")
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Handles Ctrl-C while it exists, instead of terminating the process.
final class CtrlCHandler: @unchecked Sendable {
    private let source: DispatchSourceSignal

    init(_ handler: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
    }

    func stop() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}
