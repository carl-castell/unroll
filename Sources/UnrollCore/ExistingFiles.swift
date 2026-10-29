import Foundation

/// Files that are already in a destination that has no index yet, e.g. copied earlier with
/// Image Capture. They are recognized by their name, size and capture time, like `rebuild-index` does.
public protocol ExistingFilesScanning: Sendable {
    /// The keys of the media files in `root`, read from file attributes or metadata, without
    /// hashing. Returns the number of files found and their keys.
    func keys(in root: URL, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async -> (count: Int, keys: ImportedKeys)

    /// Records those files in a new index, with hashes. Returns how many were indexed.
    func index(
        _ destination: ResolvedDestination, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async throws -> Int
}
