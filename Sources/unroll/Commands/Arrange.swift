import ArgumentParser
import Foundation
import UnrollCore
import UnrollStore

struct Arrange: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move the files already in a task's destination into its folder structure.",
        discussion: """
            Photos and videos with a capture time are moved into the task's folder structure, \
            with a Live Photo's video and edit data next to their photo. Files are only moved \
            within the destination, never replaced or deleted. Files without a capture time, \
            other files and files added to Apple Photos stay where they are. Every move is \
            listed in .unroll/arrange-<time>.tsv. A destination without an index gets one first.

            Examples:
              unroll arrange "iPhone → SSD" --dry-run
              unroll arrange "iPhone → SSD" --yes
            """
    )

    @Argument(help: "The task's name, or the start of its ID. May be omitted if there is only one task.", completion: .taskNames)
    var task: String?

    @Flag(help: "Only show what would be moved.")
    var dryRun = false

    @Flag(help: "With --dry-run, list every move.")
    var list = false

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    @MainActor
    func run() async throws {
        let task = try resolveTask(task, store: TaskStore())
        guard let destination = VolumeResolver().resolve(task.destination) else {
            printError(SyncError.destinationNotConnected(volumeName: task.destination.volumeName).message)
            throw UnrollExit.destinationMissing
        }
        let path = Format.destination(destination.root, volumeName: destination.volumeName)
        let arranger = DestinationArranger()
        let plan = await arranger.plan(root: destination.root, template: task.folderTemplate, rule: task.activeOtherFolderRule) { _, _ in }

        print("\(plan.moves.count) \(plan.moves.count == 1 ? "file" : "files") to move into \(task.folderTemplate.isNone ? "one folder" : task.folderTemplate.pattern) in \(path)")
        if plan.inPlace > 0 { print("  \(plan.inPlace) already in place") }
        if plan.undated > 0 { print("  \(plan.undated) without a capture time stay where they are") }
        if plan.otherFiles > 0 { print("  \(plan.otherFiles) other \(plan.otherFiles == 1 ? "file stays" : "files stay") where they are") }
        if plan.inPhotos > 0 { print("  \(plan.inPhotos) added to Apple Photos stay where they are") }
        guard !plan.moves.isEmpty else { return }
        if dryRun {
            for move in plan.moves.prefix(list ? .max : 10) { print("  \(move.from) → \(move.to)") }
            if !list, plan.moves.count > 10 { print("  … \(plan.moves.count - 10) more (--list shows all)") }
            return
        }

        if !yes {
            guard Terminal.isInteractive else {
                printError("Arranging moves files in \(path). Pass --yes to confirm.")
                throw UnrollExit.confirmationRequired
            }
            print("Move them? Files are only moved, never replaced or deleted. [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Nothing was moved.")
                return
            }
        }

        let result: ArrangeResult
        do {
            result = try await arranger.apply(
                plan, destination: destination,
                indexing: { done, total in if done % 500 == 0, done > 0 { print("  indexing \(done) of \(total)") } },
                progress: { done, total in if done % 500 == 0, done > 0 { print("  moved \(done) of \(total)") } }
            )
        } catch SyncError.destinationBusy {
            printError(SyncError.destinationBusy.message)
            throw UnrollExit.destinationMissing
        }
        print("Moved \(result.moved) files.")
        if result.removedFolders > 0 { print("  removed \(result.removedFolders) folders that were left empty") }
        if let journal = result.journal { print("  list of moves: \(Format.path(journal))") }
        for failure in result.failed { printError("  \(failure)") }
        if !result.failed.isEmpty { throw UnrollExit.itemsFailed }
    }
}
