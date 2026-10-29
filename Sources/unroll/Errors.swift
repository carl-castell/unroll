import ArgumentParser
import Foundation
import UnrollCore
import UnrollStore

/// Prints to standard error, so messages don't mix with machine-readable output.
func printError(_ message: String) {
    // Keep the order of mixed output when stdout is piped and therefore buffered.
    fflush(stdout)
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

extension SyncError {
    var message: String {
        switch self {
        case .destinationNotConnected(let name):
            "The destination \"\(name)\" isn't connected. Connect it and try again."
        case .destinationReadOnly(let name):
            "The destination \"\(name)\" is read-only, so nothing can be copied to it."
        case .destinationBusy:
            "Another unroll run is already copying into this destination."
        case .destinationUnwritable(let reason):
            "Couldn't write to the destination: \(reason)"
        case .notEnoughSpace(let needed, let available):
            "Not enough space on the destination: \(Format.bytes(needed)) to copy, \(Format.bytes(available)) free."
        case .deviceNotConnected(let name):
            "\"\(name)\" isn't connected. Connect it with a cable and unlock it."
        case .deviceLocked(let name):
            "\"\(name)\" is locked or doesn't trust this Mac. Unlock it, tap Trust if asked, and try again."
        case .deviceFailed(let reason):
            "Couldn't read the device: \(reason)"
        case .confirmationRequired(let reason):
            "This run needs confirmation (\(reason.explanation)). Run it once in a terminal, or pass --yes."
        case .indexUnreadable(let reason):
            "The destination's index can't be read: \(reason). `unroll rebuild-index` can recreate it."
        }
    }

    var exitCode: ExitCode {
        switch self {
        case .destinationNotConnected, .destinationReadOnly, .destinationBusy, .destinationUnwritable,
             .notEnoughSpace, .indexUnreadable:
            UnrollExit.destinationMissing
        case .deviceNotConnected, .deviceLocked, .deviceFailed: UnrollExit.deviceUnavailable
        case .confirmationRequired: UnrollExit.confirmationRequired
        }
    }
}

struct TaskLookupError: Error {
    let message: String
}

/// Finds a task by name or ID prefix.
func findTask(_ query: String, in store: TaskStore) throws(TaskLookupError) -> SyncTask {
    let tasks: [SyncTask]
    do {
        tasks = try store.loadTasks()
    } catch {
        throw TaskLookupError(message: String(describing: error))
    }
    guard let task = SyncTask.find(query, in: tasks) else {
        throw TaskLookupError(message: tasks.isEmpty
            ? "No sync tasks yet. Create one with `unroll tasks add`, or run `unroll` in a terminal."
            : "No task named \"\(query)\". Existing tasks: \(tasks.map { "\"\($0.name)\"" }.joined(separator: ", ")).")
    }
    return task
}

/// Loads a task by name or ID prefix, exiting with code 4 if it can't.
func loadTask(_ query: String, from store: TaskStore) throws -> SyncTask {
    do {
        return try findTask(query, in: store)
    } catch {
        printError(error.message)
        throw UnrollExit.invalidTask
    }
}

extension ConfirmationReason {
    var explanation: String {
        switch self {
        case .firstRun: "first run of this task"
        case .destinationOrDeviceChanged: "the task's device or destination changed"
        case .indexRebuilt: "the destination's index was rebuilt"
        case .indexEmpty: "the destination's index is empty"
        }
    }
}
