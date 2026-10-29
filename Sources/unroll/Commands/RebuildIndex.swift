import ArgumentParser
import Foundation
import UnrollCore
import UnrollStore

struct RebuildIndex: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild-index",
        abstract: "Rebuild a task's index from the files in its destination.",
        discussion: """
            Scans the destination folder and records every file with its capture time, size, \
            name and SHA-256 hash. Files are only read: nothing is renamed, changed or deleted. \
            The previous index and its run history are replaced. The next run of the task asks \
            for confirmation again.

            Examples:
              unroll rebuild-index
              unroll rebuild-index "iPhone → SSD" --yes
            """
    )

    @Argument(help: "The task's name, or the start of its ID. May be omitted if there is only one task.", completion: .taskNames)
    var task: String?

    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
    var yes = false

    @MainActor
    func run() async throws {
        let store = TaskStore()
        let task = try resolveTask(task, store: store)
        guard let destination = VolumeResolver().resolve(task.destination) else {
            printError(SyncError.destinationNotConnected(volumeName: task.destination.volumeName).message)
            throw UnrollExit.destinationMissing
        }
        let path = Format.destination(destination.root, volumeName: destination.volumeName)
        guard FileManager.default.fileExists(atPath: destination.root.path) else {
            printError("The destination folder \(path) doesn't exist yet; there is nothing to rebuild.")
            throw UnrollExit.invalidTask
        }

        if !yes {
            guard Terminal.isInteractive else {
                printError("Rebuilding replaces the index of \(path). Pass --yes to confirm.")
                throw UnrollExit.confirmationRequired
            }
            print("Rebuild the index of \"\(task.name)\" from the files in \(path)? Files are only read. [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Cancelled.")
                return
            }
        }

        print("Scanning \(path)…")
        let result: RebuildResult
        do {
            result = try await IndexRebuilder().rebuild(destination: destination) { done, total in
                if done % 500 == 0, done > 0, done < total { print("  \(done) of \(total) files") }
            }
        } catch SyncError.destinationBusy {
            printError(SyncError.destinationBusy.message)
            throw UnrollExit.destinationMissing
        }

        print("Indexed \(result.files - result.duplicateKeys) files.")
        print("  \(result.fromAttributes) with the exact capture time and name recorded by unroll")
        if result.fromMetadata > 0 { print("  \(result.fromMetadata) with the capture time from the photo or video itself") }
        if result.fromFileDate > 0 {
            print("  \(result.fromFileDate) with only the file date (recognized if it is within 2 seconds of the capture time)")
        }
        if result.duplicateKeys > 0 { print("  \(result.duplicateKeys) skipped because another file has the same capture time, size and name") }
    }

}

/// The named task, or the only one when no name is given.
func resolveTask(_ name: String?, store: TaskStore) throws -> SyncTask {
    if let name { return try loadTask(name, from: store) }
    let tasks = (try? store.loadTasks()) ?? []
    guard tasks.count == 1 else {
        printError(tasks.isEmpty
            ? "No sync tasks yet. Create one with `unroll tasks add`."
            : "Several tasks exist; name one: \(tasks.map { "\"\($0.name)\"" }.joined(separator: ", ")).")
        throw UnrollExit.invalidTask
    }
    return tasks[0]
}

enum Terminal {
    /// True when both input and output are a terminal, so prompts and menus can be shown.
    static var isInteractive: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }
}
