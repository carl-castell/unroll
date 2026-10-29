import Foundation
import Noora
import UnrollCore
import UnrollStore
import UnrollSystem

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
        let label = Format.destination(task.destination, resolver: app.resolver)
        let destination = try await app.noora.progressStep(
            message: "Checking destination \(label)",
            successMessage: "Destination \(label) is connected",
            errorMessage: "Destination \(label) isn't available",
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
                case .existingFilesScanning(let done, let total):
                    update("Reading the files already in the destination… \(done) of \(total)")
                default: break
                }
            }
        }

        let summary = plan.summary
        if summary.existingFiles > 0 {
            app.printStepLine("Found \(summary.existingFiles) files already in the destination; matching ones won't be copied again")
        }
        let compared: TerminalText = "Compared against index → \(.primary("\(summary.newCount) new")) (\(Format.bytes(summary.newBytes))), \(summary.alreadyImported) already imported"
        app.printStepLine(compared)
        if summary.excludedByVersions > 0 {
            app.printMuted("\(summary.excludedByVersions) skipped by the task's original/edited setting")
        }
        if summary.goneFromDevice > 0 {
            app.printMuted(Format.goneFromDevice(summary.goneFromDevice))
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
            return .quit
        }

        let space = Format.space(plan)
        print("")
        print(app.noora.format("  \(.primary(Format.newItems(summary)))"))
        print(app.noora.format(space.fits ? "  \(.muted(space.text))" : "  \(.danger(space.text))"))
        print("")

        while true {
            let choices = [Choice("Copy now", Action.runNow), Choice("Show files", .list), Choice("Back", .back)]
            switch app.noora.menu("Copy these \(summary.newCount.formatted()) files?", choices) {
            case .runNow:
                // Copy exactly what was previewed, unless the device or destination changed meanwhile.
                guard await app.engine.isStillValid(plan, for: task) else {
                    await app.engine.close(plan)
                    app.noora.warning("The device or destination changed since the preview. Scanning again.")
                    return .screen(SyncScreen(taskID: task.id, mode: .run))
                }
                // Choosing "Copy now" after seeing the preview is the confirmation; don't ask again.
                return await TransferFlow.run(task: task, plan: plan, app: app, confirmed: true)
            case .list:
                let rows = plan.items.map { [$0.item.filename, $0.key.captureDate.description, Format.bytes($0.item.size), Format.folder(of: $0, in: plan)] }
                try? app.noora.paginatedTable(headers: ["File", "Taken", "Size", "Folder"], rows: rows, pageSize: 20)
            case .back:
                await app.engine.close(plan)
                return .mainMenu
            }
        }
    }
}

/// Confirmation (when the rules require it), the transfer with a progress line, and the summary.
/// After a clean run unroll quits; after problems it returns to the menu.
@MainActor
enum TransferFlow {
    /// - Parameter confirmed: the user already agreed to this plan, e.g. in the preview.
    static func run(task: SyncTask, plan: SyncPlan, app: AppContext, confirmed: Bool = false) async -> Next {
        let engine = app.engine
        guard !plan.items.isEmpty else {
            await engine.close(plan)
            app.noora.success("\"\(task.name)\" is up to date. Nothing new to copy.")
            return .quit
        }
        let totalBytes = plan.items.reduce(Int64(0)) { $0 + $1.item.size }

        if let reason = plan.confirmation, !confirmed {
            app.noora.info(.alert("\(confirmationTitle(reason, task: task))", takeaways: [
                "Task: \(task.name)",
                "From: \(task.device.name)",
                "To: \(Format.destination(plan.destinationRoot, volumeName: plan.destination.volumeName))",
                "\(plan.items.count) files, \(Format.bytes(totalBytes))",
            ]))
            guard app.noora.confirm("Copy them now?", default: true) else {
                await engine.close(plan)
                app.noora.info("Nothing was copied.")
                return .mainMenu
            }
        }

        let tracker = TransferTracker(styled: true)
        let log = RunLog(task: task, dryRun: false)
        let summary: SyncSummary
        do {
            summary = try await app.noora.progressStep(
                message: "Copying \(plan.items.count) files (\(Format.bytes(totalBytes)))",
                successMessage: "Copied \(plan.items.count) files",
                errorMessage: "Copying failed",
                showSpinner: true
            ) { @Sendable update in
                let photos = PhotosText.step(for: task, settings: TaskStore().loadSettings())
                let work = Task {
                    try await engine.execute(plan, confirmed: true, photos: photos) { event in
                        log?.record(event)
                        if let line = tracker.handle(event) { update(line) }
                    }
                }
                // Ctrl-C finishes the current file, then stops; nothing incomplete is recorded.
                let interrupt = CtrlCHandler {
                    work.cancel()
                    tracker.markStopping()
                    update(tracker.currentLine())
                }
                // Keeps the clock running during steps without events of their own (Photos).
                let ticker = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        if tracker.isWaiting { update(tracker.currentLine()) }
                    }
                }
                defer {
                    interrupt.stop()
                    ticker.cancel()
                }
                return try await work.value
            }
        } catch {
            await engine.close(plan)
            log?.write("failed: \((error as? SyncError)?.message ?? String(describing: error))")
            app.show(error)
            return .mainMenu
        }
        await engine.close(plan)
        record(task: task, summary: summary, app: app)
        await PhotosText.notify(task, summary: summary)
        let clean = showSummary(summary, task: task, plan: plan, log: log?.url, app: app)
        return clean ? .quit : .mainMenu
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

    /// Shows the result. Returns true when everything went fine.
    private static func showSummary(_ summary: SyncSummary, task: SyncTask, plan: SyncPlan, log: URL?, app: AppContext) -> Bool {
        let took = TransferTracker.duration(Format.seconds(summary.duration))
        var details: [TerminalText] = [
            "Imported \(summary.imported) files (\(Format.bytes(summary.bytes))) in \(took)",
            "Into \(Format.destination(plan.destinationRoot, volumeName: plan.destination.volumeName))",
        ]
        if summary.duplicates > 0 { details.append("\(summary.duplicates) identical to files already there; not copied again") }
        if summary.unavailable > 0 { details.append("\(summary.unavailable) not available on the device; see Help → Troubleshooting") }
        if plan.summary.goneFromDevice > 0 { details.append("\(Format.goneFromDevice(plan.summary.goneFromDevice))") }
        if summary.notAttempted > 0 { details.append("\(summary.notAttempted) not copied yet; run the task again to continue") }
        for failure in summary.failed.prefix(5) {
            details.append("\(failure.filename): \(PlainRenderer.describe(failure.reason))")
        }
        if summary.failed.count > 5 { details.append("… and \(summary.failed.count - 5) more failures") }
        if let photos = summary.photos {
            if let line = PhotosText.summary(photos) { details.append("\(line)") }
            if photos.added > 0 { details.append("\(PhotosText.copyItemsReminder)") }
        }
        if let log { details.append("Log: \(Format.path(log))") }

        let headline = "Imported \(summary.imported) files (\(Format.bytes(summary.bytes)))"
        if let stopped = summary.stoppedBecause {
            app.noora.error(.alert("Stopped: \(stopped.message)", takeaways: details))
        } else if !summary.failed.isEmpty || summary.photos?.error != nil {
            let what = summary.failed.isEmpty ? "couldn't be added to Apple Photos" : "\(summary.failed.count) failed"
            app.noora.error(.alert("Sync finished with problems: \(what)", takeaways: details))
        } else if summary.cancelled {
            app.noora.warning(.alert(
                "\(headline). Stopped at your request.",
                takeaway: "\(summary.notAttempted) not copied yet; run the task again to continue"
            ))
        } else {
            app.noora.success(.alert("Sync complete. \"\(task.name)\" is up to date.", takeaways: details))
            return true
        }
        return false
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
