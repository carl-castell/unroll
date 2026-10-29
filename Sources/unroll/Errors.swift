import ArgumentParser
import Foundation
import UnrollCore
import UnrollStore

/// Prints to standard error, so messages don't mix with machine-readable output.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

extension SyncError {
    var message: String {
        switch self {
        case .destinationNotConnected(let name):
            "The destination \"\(name)\" isn't connected. Connect it and try again."
        case .destinationReadOnly(let name):
            "The destination \"\(name)\" is read-only, so nothing can be copied to it."
        case .deviceNotConnected(let name):
            "\"\(name)\" isn't connected. Connect it with a cable and unlock it."
        case .deviceLocked(let name):
            "\"\(name)\" is locked or doesn't trust this Mac. Unlock it, tap Trust if asked, and try again."
        case .deviceFailed(let reason):
            "Couldn't read the device: \(reason)"
        case .indexUnreadable(let reason):
            "The destination's index can't be read: \(reason). `unroll rebuild-index` can recreate it."
        }
    }

    var exitCode: ExitCode {
        switch self {
        case .destinationNotConnected, .destinationReadOnly, .indexUnreadable: UnrollExit.destinationMissing
        case .deviceNotConnected, .deviceLocked, .deviceFailed: UnrollExit.deviceUnavailable
        }
    }
}

/// Loads a task by name or ID prefix, exiting with code 4 if it can't.
func loadTask(_ query: String, from store: TaskStore) throws -> SyncTask {
    let tasks: [SyncTask]
    do {
        tasks = try store.loadTasks()
    } catch {
        printError(String(describing: error))
        throw UnrollExit.invalidTask
    }
    guard let task = SyncTask.find(query, in: tasks) else {
        printError(tasks.isEmpty
            ? "No sync tasks yet. Create one with `unroll tasks add`."
            : "No task named \"\(query)\". Existing tasks: \(tasks.map { "\"\($0.name)\"" }.joined(separator: ", ")).")
        throw UnrollExit.invalidTask
    }
    return task
}
