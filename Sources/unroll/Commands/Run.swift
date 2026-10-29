import ArgumentParser
import Foundation
import UnrollCore
import UnrollDevice
import UnrollStore

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a sync task.",
        discussion: """
            Checks that the task's destination and device are connected, compares the device \
            against the destination's index and copies only new items. Nothing on the device \
            is changed or deleted.
            """
    )

    @Argument(help: "The task's name, or the start of its ID.")
    var task: String

    @Flag(help: "Check and compare only. Nothing is copied or written.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Don't ask before the first run of a task (or after its device, destination or index changed).")
    var yes = false

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
        let task = try loadTask(task, from: TaskStore())
        let engine = SyncEngine(
            devices: ICCDeviceBrowser(), destinations: VolumeResolver(), indexes: SQLiteIndexProvider(),
            writers: DestinationStoreOpener()
        )
        let renderer = PlainRenderer(destinationLabel: Format.destination(task.destination, resolver: VolumeResolver()))
        var plan: SyncPlan
        do {
            plan = try await engine.makePlan(for: task, unlockTimeout: .seconds(unlockTimeout), events: { renderer.handle($0) })
        } catch {
            printError(error.message)
            throw error.exitCode
        }
        if let limit {
            plan = plan.limited(to: limit)
        }

        if dryRun {
            renderer.printPlan(plan, listItems: list)
            await engine.close(plan)
            print("\nDry run: nothing was copied.")
            return
        }
        guard !plan.items.isEmpty else {
            await engine.close(plan)
            print("\nNothing new to copy.")
            throw plan.summary.unavailable > 0 ? UnrollExit.itemsFailed : UnrollExit.success
        }

        if let reason = plan.confirmation, !yes {
            guard Terminal.isInteractive else {
                await engine.close(plan)
                printError(SyncError.confirmationRequired(reason).message)
                throw UnrollExit.confirmationRequired
            }
            renderer.printPlan(plan, listItems: false)
            print("\n\(Self.question(for: reason, plan: plan, task: task)) [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                await engine.close(plan)
                print("Cancelled. Nothing was copied.")
                return
            }
        }

        let summary: SyncSummary
        do {
            summary = try await engine.execute(plan, confirmed: true, events: { renderer.handle($0) })
        } catch {
            await engine.close(plan)
            printError(error.message)
            throw error.exitCode
        }
        await engine.close(plan)
        try saveRun(of: task, indexID: summary.indexID)

        if let stopped = summary.stoppedBecause {
            printError(stopped.message + " The run was stopped; start it again to continue.")
            throw stopped.exitCode
        }
        if !summary.failed.isEmpty || summary.unavailable > 0 {
            throw UnrollExit.itemsFailed
        }
    }

    /// Records the run and what it was confirmed for, so later runs don't ask again.
    private func saveRun(of task: SyncTask, indexID: String?) throws {
        let store = TaskStore()
        var tasks = try store.loadTasks()
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].lastRun = Date()
        if let indexID {
            tasks[index].confirmation = ConfirmationSnapshot(deviceID: task.device.id, destination: task.destination, indexID: indexID)
        }
        try store.saveTasks(tasks)
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
