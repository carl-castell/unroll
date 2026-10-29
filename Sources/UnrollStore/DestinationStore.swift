import CryptoKit
import Darwin
import Foundation
import UnrollCore

/// Extended attributes written on every imported file, so `rebuild-index` can restore the exact key.
public enum UnrollAttribute {
    public static let filename = "com.unroll.filename"
    public static let captureDate = "com.unroll.capture-date"
    public static let deviceID = "com.unroll.device-id"
}

/// Writes into one destination folder. Holds an exclusive lock on the destination while open,
/// so two runs can't import into the same folder at once. Writes only inside the destination.
public final class DestinationStore: DestinationWriter, @unchecked Sendable {
    public let root: URL
    public let partialDirectory: URL
    private let index: SQLiteIndex
    private let lock: DestinationLock

    public init(destination: ResolvedDestination) throws {
        root = destination.root
        lock = try DestinationLock(root: root)
        partialDirectory = Self.partialDirectory(root: root)
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        index = try SQLiteIndex.openOrCreate(destinationRoot: root, useWAL: destination.kind != .network)
    }

    static func partialDirectory(root: URL) -> URL {
        root.appending(path: SQLiteIndex.directoryName).appending(path: "partial", directoryHint: .isDirectory)
    }

    public func recoverInterrupted() throws -> RecoveryResult {
        try index.markUnfinishedRunsInterrupted()
        var committed = 0, discarded = 0
        for pending in try index.pendingTransfers() {
            if let item = pending.item, isComplete(item) {
                // Moved into place, but the process stopped before recording it.
                try index.commitPending(tempName: pending.tempName, item: item)
                committed += 1
            } else {
                try? FileManager.default.removeItem(at: partialDirectory.appending(path: pending.tempName))
                try index.deletePending(tempName: pending.tempName)
                discarded += 1
            }
        }
        // Anything else in the temp area is left over from an interrupted download.
        for leftover in (try? FileManager.default.contentsOfDirectory(at: partialDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: leftover)
            discarded += 1
        }
        return RecoveryResult(committed: committed, discarded: discarded)
    }

    public func importedKeys() throws -> ImportedKeys {
        try index.importedKeys()
    }

    public func meta() throws -> IndexMeta {
        try index.meta()
    }

    public func beginTransfer(tempName: String, key: ItemKey) throws {
        try index.beginPending(tempName: tempName, key: key)
    }

    public func hash(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    public func existingPath(forHash hash: Data) throws -> String? {
        try index.path(forHash: hash)
    }

    public func fileExists(atRelativePath path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    public func commit(tempFile: URL, tempName: String, item: IndexedItem, captureDate: LocalTimestamp) throws {
        let target = root.appending(path: item.relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try label(tempFile, item: item, captureDate: captureDate)
        try flushToDisk(tempFile)
        try index.setPendingTarget(tempName: tempName, item: item)
        // RENAME_EXCL fails instead of replacing an existing file.
        guard renamex_np(tempFile.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw DestinationWriteError.targetExists }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        try index.commitPending(tempName: tempName, item: item)
    }

    public func recordDuplicate(key: ItemKey, of path: String, deviceID: DeviceID, tempFile: URL, tempName: String) throws {
        try index.commitAlias(tempName: tempName, key: key, of: path, deviceID: deviceID)
        try? FileManager.default.removeItem(at: tempFile)
    }

    public func abandonTransfer(tempName: String, tempFile: URL?) {
        try? FileManager.default.removeItem(at: tempFile ?? partialDirectory.appending(path: tempName))
        try? index.deletePending(tempName: tempName)
    }

    public func startRun(taskID: UUID, deviceID: DeviceID) throws -> Int64 {
        try index.startRun(taskID: taskID, deviceID: deviceID)
    }

    public func finishRun(_ runID: Int64, summary: SyncSummary) {
        try? index.finishRun(runID, summary: summary)
    }

    // MARK: Helpers

    private func isComplete(_ item: IndexedItem) -> Bool {
        let target = root.appending(path: item.relativePath)
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        return (try? hash(of: target)) == item.sha256
    }

    /// Stores the key in extended attributes and sets the file dates to the capture time.
    private func label(_ file: URL, item: IndexedItem, captureDate: LocalTimestamp) throws {
        try setAttribute(UnrollAttribute.filename, item.key.filename, on: file)
        try setAttribute(UnrollAttribute.captureDate, captureDate.description, on: file)
        if let deviceID = item.deviceID {
            try setAttribute(UnrollAttribute.deviceID, deviceID.rawValue, on: file)
        }
        let date = captureDate.date(in: .current)
        // Downloads arrive owner-only (0600); photos are normally readable by backup tools.
        try? FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date, .posixPermissions: 0o644], ofItemAtPath: file.path
        )
    }

    private func setAttribute(_ name: String, _ value: String, on file: URL) throws {
        let data = Array(value.utf8)
        guard setxattr(file.path, name, data, data.count, 0, 0) == 0 else {
            // Some file systems (e.g. FAT) don't support extended attributes; the index still has the key.
            if errno == ENOTSUP { return }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func flushToDisk(_ file: URL) throws {
        let descriptor = open(file.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        // F_FULLFSYNC asks the drive itself to flush, not just the OS.
        if fcntl(descriptor, F_FULLFSYNC) != 0 {
            fsync(descriptor)
        }
    }
}

public struct DestinationStoreOpener: DestinationOpening {
    public init() {}

    public func openForWriting(_ destination: ResolvedDestination) throws -> any DestinationWriter {
        try DestinationStore(destination: destination)
    }
}
