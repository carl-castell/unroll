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
            against the destination's index and copies only new items.
            """
    )

    @Argument(help: "The task's name, or the start of its ID.")
    var task: String

    @Flag(help: "Check and compare only. Nothing is copied or written.")
    var dryRun = false

    @Flag(help: "With --dry-run, list every new item.")
    var list = false

    @Option(help: "Seconds to wait for a locked or untrusted device.")
    var unlockTimeout = 30

    @MainActor
    func run() async throws {
        guard dryRun else {
            printError("Copying isn't available yet in this development version. Use --dry-run.")
            throw UnrollExit.invalidTask
        }
        let task = try loadTask(task, from: TaskStore())
        let engine = SyncEngine(devices: ICCDeviceBrowser(), destinations: VolumeResolver(), indexes: SQLiteIndexProvider())
        let renderer = PlainRenderer()
        do {
            let plan = try await engine.makePlan(
                for: task, unlockTimeout: .seconds(unlockTimeout), events: { renderer.handle($0) }
            )
            renderer.printPlan(plan, listItems: list)
            print("\nDry run: nothing was copied.")
        } catch {
            printError(error.message)
            throw error.exitCode
        }
    }
}
