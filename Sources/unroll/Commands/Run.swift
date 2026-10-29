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
        let renderer = PlainRenderer()
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

        let summary: SyncSummary
        do {
            summary = try await engine.execute(plan, events: { renderer.handle($0) })
        } catch {
            await engine.close(plan)
            printError(error.message)
            throw error.exitCode
        }
        await engine.close(plan)
        try saveLastRun(of: task)

        if let stopped = summary.stoppedBecause {
            printError(stopped.message + " The run was stopped; start it again to continue.")
            throw stopped.exitCode
        }
        if !summary.failed.isEmpty || summary.unavailable > 0 {
            throw UnrollExit.itemsFailed
        }
    }

    private func saveLastRun(of task: SyncTask) throws {
        let store = TaskStore()
        var tasks = try store.loadTasks()
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index].lastRun = Date()
            try store.saveTasks(tasks)
        }
    }
}
