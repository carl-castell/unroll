import ArgumentParser
import Foundation
import UnrollCore
import UnrollDevice
import UnrollStore
import UnrollSystem

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a sync task.",
        discussion: """
            Checks that the task's destination and device are connected, compares the device \
            against the destination's index and copies only new items. Nothing on the device \
            is changed or deleted.

            The first run of a task asks once before copying (again after its device, destination \
            or index changed). Without a terminal, such a run stops with exit code 5 instead of \
            waiting; pass --yes to confirm. Ctrl-C finishes the current file, then stops.

            Examples:
              unroll run "iPhone → SSD"
              unroll run "iPhone → SSD" --dry-run
              unroll run "iPhone → SSD" --yes --json
            """
    )

    @Argument(help: "The task's name, or the start of its ID.")
    var task: String

    @Flag(help: "Check and compare only. Nothing is copied or written.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Don't ask before the first run of a task (or after its device, destination or index changed).")
    var yes = false

    @Flag(help: "Machine-readable output: one JSON object per line.")
    var json = false

    @Flag(help: "With --dry-run, list every new item.")
    var list = false

    @Option(help: ArgumentHelp(
        "Copy at most this many new items (a photo and its Live Photo video count as one).",
        visibility: .hidden
    ))
    var limit: Int?

    @Option(help: "Seconds to wait for a locked or untrusted device.")
    var unlockTimeout = 30

    @MainActor
    func run() async throws {
        let store = TaskStore()
        let task: SyncTask
        do {
            task = try findTask(self.task, in: store)
        } catch {
            let renderer: any RunRenderer = json ? JSONRenderer() : PlainRenderer()
            renderer.failure(error.message, code: UnrollExit.invalidTask)
            if json { renderer.result(UnrollExit.invalidTask, log: nil) }
            throw UnrollExit.invalidTask
        }

        let renderer: any RunRenderer
        if json {
            let jsonRenderer = JSONRenderer()
            jsonRenderer.start(task: task, dryRun: dryRun)
            renderer = jsonRenderer
        } else {
            renderer = PlainRenderer(destinationLabel: Format.destination(task.destination, resolver: VolumeResolver()))
        }
        let log = RunLog(task: task, dryRun: dryRun)
        let code = await perform(task, renderer: renderer, log: log)
        log?.write("exit code \(code.rawValue)")
        renderer.result(code, log: log?.url)
        if code != UnrollExit.success { throw code }
    }

    /// Runs the task and returns the exit code; all output goes through the renderer.
    @MainActor
    private func perform(_ task: SyncTask, renderer: any RunRenderer, log: RunLog?) async -> ExitCode {
        let engine = SyncEngine(
            devices: ICCDeviceBrowser(), destinations: VolumeResolver(), indexes: SQLiteIndexProvider(),
            writers: DestinationStoreOpener()
        )
        let events: EventSink = { event in
            renderer.handle(event)
            log?.record(event)
        }

        var plan: SyncPlan
        do {
            plan = try await engine.makePlan(for: task, unlockTimeout: .seconds(unlockTimeout), events: events)
        } catch {
            renderer.failure(error.message, code: error.exitCode)
            return error.exitCode
        }
        if let limit {
            plan = plan.limited(to: limit)
        }

        if dryRun {
            renderer.plan(plan, listItems: list)
            await engine.close(plan)
            renderer.note("Dry run: nothing was copied.")
            return UnrollExit.success
        }
        guard !plan.items.isEmpty else {
            await engine.close(plan)
            renderer.note("Nothing new to copy.")
            return plan.summary.unavailable > 0 ? UnrollExit.itemsFailed : UnrollExit.success
        }

        if let reason = plan.confirmation, !yes {
            // Never prompt without a terminal, or when the output is meant for a program.
            guard Terminal.isInteractive, !json else {
                await engine.close(plan)
                renderer.failure(SyncError.confirmationRequired(reason).message, code: UnrollExit.confirmationRequired)
                return UnrollExit.confirmationRequired
            }
            renderer.plan(plan, listItems: false)
            print("\n\(Self.question(for: reason, plan: plan, task: task)) [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                await engine.close(plan)
                renderer.note("Cancelled. Nothing was copied.")
                return UnrollExit.success
            }
        }

        let photos: (any PhotosImporting)? = task.addToPhotos ? AppleScriptPhotosImporter(checksDuplicates: task.photosChecksDuplicates) : nil
        let work = Task { try await engine.execute(plan, confirmed: true, photos: photos, events: events) }
        // Ctrl-C finishes the current file, then stops; nothing incomplete is recorded.
        let interrupt = CtrlCHandler {
            work.cancel()
            printError("Stopping after the current file…")
        }
        let summary: SyncSummary
        do {
            summary = try await work.value
            interrupt.stop()
        } catch {
            interrupt.stop()
            await engine.close(plan)
            let syncError = error as? SyncError ?? .destinationUnwritable(String(describing: error))
            renderer.failure(syncError.message, code: syncError.exitCode)
            return syncError.exitCode
        }
        await engine.close(plan)
        saveRun(of: task, indexID: summary.indexID)
        await PhotosText.notify(task, summary: summary)

        if let stopped = summary.stoppedBecause {
            renderer.failure(stopped.message + " The run was stopped; start it again to continue.", code: stopped.exitCode)
            return stopped.exitCode
        }
        if summary.cancelled {
            renderer.note("Stopped at your request. Run the task again to continue.")
            return UnrollExit.cancelled
        }
        let photosFailed = summary.photos?.error != nil
        return summary.failed.isEmpty && summary.unavailable == 0 && !photosFailed ? UnrollExit.success : UnrollExit.itemsFailed
    }

    /// Records the run and what it was confirmed for, so later runs don't ask again.
    private func saveRun(of task: SyncTask, indexID: String?) {
        let store = TaskStore()
        guard var tasks = try? store.loadTasks(), let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].lastRun = Date()
        if let indexID {
            tasks[index].confirmation = ConfirmationSnapshot(deviceID: task.device.id, destination: task.destination, indexID: indexID)
        }
        try? store.saveTasks(tasks)
        try? store.saveLastUsedTask(task.id)
    }

    static func question(for reason: ConfirmationReason, plan: SyncPlan, task: SyncTask) -> String {
        let what = "Copy \(plan.items.count) files (\(Format.bytes(plan.items.reduce(0) { $0 + $1.item.size }))) "
            + "from \"\(task.device.name)\" to \(Format.destination(plan.destinationRoot, volumeName: plan.destination.volumeName))?"
        return switch reason {
        case .firstRun: "This is the first run of \"\(task.name)\". \(what)"
        case .destinationOrDeviceChanged: "The task's device or destination changed. \(what)"
        case .indexRebuilt: "The destination's index was rebuilt. \(what)"
        case .indexEmpty: "The destination's index is empty. \(what)"
        }
    }
}
