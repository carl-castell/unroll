import Foundation

/// Write access to one destination during a run. Implementations hold an exclusive lock
/// on the destination for as long as they are open.
///
/// Every file goes through the same steps, so an interruption at any point is safe:
/// `beginTransfer` (journal) → download into `partialDirectory` → `hash` → `commit` or
/// `recordDuplicate` (journal cleared) — or `abandonTransfer` on failure.
public protocol DestinationWriter: Sendable {
    /// Where downloads land before they are verified. On the destination volume.
    var partialDirectory: URL { get }

    /// Commits transfers that were moved into place but not recorded, and discards the rest.
    func recoverInterrupted() throws -> RecoveryResult
    func importedKeys() throws -> ImportedKeys
    func meta() throws -> IndexMeta

    func beginTransfer(tempName: String, key: ItemKey) throws
    /// SHA-256 of a file, streamed.
    func hash(of file: URL) throws -> Data
    /// The relative path of an indexed file with this content, if any.
    func existingPath(forHash hash: Data) throws -> String?
    func fileExists(atRelativePath path: String) -> Bool
    /// Moves the verified temp file to `item.relativePath` without overwriting, then records it.
    /// Throws `DestinationWriteError.targetExists` if something is already there.
    func commit(tempFile: URL, tempName: String, item: IndexedItem, captureDate: LocalTimestamp) throws
    /// Records `key` as another name for the indexed file at `path` and removes the temp file.
    func recordDuplicate(key: ItemKey, of path: String, deviceID: DeviceID, tempFile: URL, tempName: String) throws
    /// Removes a temp file and its journal entry. Never touches anything outside `partialDirectory`.
    func abandonTransfer(tempName: String, tempFile: URL?)

    func startRun(taskID: UUID, deviceID: DeviceID) throws -> Int64
    func finishRun(_ runID: Int64, summary: SyncSummary)
}

public enum DestinationWriteError: Error, Equatable {
    case targetExists
}

public struct RecoveryResult: Sendable, Equatable {
    public let committed: Int
    public let discarded: Int

    public init(committed: Int, discarded: Int) {
        self.committed = committed
        self.discarded = discarded
    }
}

public protocol DestinationOpening: Sendable {
    func openForWriting(_ destination: ResolvedDestination) throws -> any DestinationWriter
}

public enum ItemFailure: Error, Sendable, Equatable {
    case downloadFailed(String)
    case incomplete(expected: Int64, actual: Int64)
    case writeFailed(String)
    case deviceDisconnected
}

public enum FileOutcome: Sendable, Equatable {
    case imported(relativePath: String)
    /// Same content as a file that is already in the destination.
    case duplicate(of: String)
}

public struct SyncSummary: Sendable, Equatable {
    public var imported = 0
    public var duplicates = 0
    public var failed: [(filename: String, reason: ItemFailure)] = []
    public var unavailable = 0
    public var notAttempted = 0
    public var bytes: Int64 = 0
    public var duration: Duration = .zero
    public var recovered = RecoveryResult(committed: 0, discarded: 0)
    /// Set when the run stopped before all items were attempted.
    public var stoppedBecause: SyncError?

    public init() {}

    public static func == (lhs: SyncSummary, rhs: SyncSummary) -> Bool {
        lhs.imported == rhs.imported && lhs.duplicates == rhs.duplicates
            && lhs.failed.map(\.filename) == rhs.failed.map(\.filename)
            && lhs.unavailable == rhs.unavailable && lhs.notAttempted == rhs.notAttempted && lhs.bytes == rhs.bytes
    }
}
