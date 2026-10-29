import Darwin
import Foundation
import UnrollCore

/// An exclusive lock on a destination (`.unroll/lock`), held while a run or rebuild writes to it.
/// Released when the object is deallocated, and by the system if the process dies.
final class DestinationLock {
    private let descriptor: Int32

    /// Creates `.unroll/` if needed. Throws `SyncError.destinationBusy` if another process holds the lock.
    init(root: URL) throws {
        let unroll = root.appending(path: SQLiteIndex.directoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unroll, withIntermediateDirectories: true)
        let descriptor = open(unroll.appending(path: "lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SyncError.destinationBusy
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
