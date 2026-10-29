import Foundation

/// Adds files to Apple Photos. Photos references them in place, without copying them into its
/// library, only when "Copy items to the Photos library" is off in Photos settings.
public protocol PhotosImporting: Sendable {
    func importFiles(_ files: [URL]) async throws(PhotosImportError)
}

public enum PhotosImportError: Error, Sendable, Equatable {
    /// macOS didn't allow controlling Photos (Privacy & Security → Automation).
    case notAuthorized
    case failed(String)
}

public struct PhotosImportResult: Sendable, Equatable {
    public var added = 0
    /// Files that weren't added yet; they are retried on the next run of the task.
    public var pending = 0
    public var error: PhotosImportError?

    public init() {}
}

extension SyncEngine {
    /// Files per Photos import call. Each call is one entry under Photos → Imports, so a run is
    /// normally a single import; only very large runs are split, to keep each call manageable.
    static let photosBatchSize = 2_000

    /// Adds this run's imported files, and any left over from earlier runs, to Photos.
    /// Live Photo pairs stay in the same batch so Photos keeps them together. Edit data (AAE)
    /// isn't imported on its own.
    func addToPhotos(
        newPaths: [(path: String, groupKey: String)], writer: any DestinationWriter, root: URL,
        photos: any PhotosImporting, events: EventSink
    ) async -> PhotosImportResult {
        var result = PhotosImportResult()
        let earlier = (try? writer.pendingPhotosImports()) ?? []
        let newSet = Set(newPaths.map(\.path))
        let all = newPaths + earlier.filter { !newSet.contains($0) }.map { ($0, $0) }
        guard !all.isEmpty else { return result }
        try? writer.markPhotosImport(newPaths.map(\.path), state: .pending)

        events(.photosImportStarted(files: all.count))
        for batch in Self.batches(all) {
            do {
                try await photos.importFiles(batch.map { root.appending(path: $0) })
                try? writer.markPhotosImport(batch, state: .done)
                result.added += batch.count
                events(.photosImportProgress(done: result.added, total: all.count))
            } catch {
                result.error = error
                result.pending = all.count - result.added
                break
            }
        }
        events(.photosImportFinished(result))
        return result
    }

    /// Splits into batches without separating files of the same group.
    static func batches(_ files: [(path: String, groupKey: String)]) -> [[String]] {
        var batches: [[String]] = []
        var current: [String] = []
        var index = 0
        while index < files.count {
            var group = [files[index].path]
            while index + group.count < files.count, files[index + group.count].groupKey == files[index].groupKey {
                group.append(files[index + group.count].path)
            }
            if !current.isEmpty, current.count + group.count > photosBatchSize {
                batches.append(current)
                current = []
            }
            current += group
            index += group.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}

public enum PhotosImportState: Int, Sendable {
    case notRequested = 0, done = 1, pending = 2
}
