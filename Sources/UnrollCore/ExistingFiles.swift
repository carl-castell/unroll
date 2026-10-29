import Foundation

/// A file already in the destination, as read from its attributes or metadata.
public struct ExistingFile: Sendable, Equatable {
    /// Relative to the destination root.
    public let relativePath: String
    public let key: ItemKey
    /// Where the capture time came from: `attributes`, `metadata` or `file-date`.
    public let dateSource: String

    public init(relativePath: String, key: ItemKey, dateSource: String) {
        self.relativePath = relativePath
        self.key = key
        self.dateSource = dateSource
    }
}

/// What a scan of a destination without an index found.
public struct ExistingFiles: Sendable, Equatable {
    /// Regular files seen, including ones whose key couldn't be read.
    public var count: Int
    public var files: [ExistingFile]

    public init(count: Int = 0, files: [ExistingFile] = []) {
        self.count = count
        self.files = files
    }

    /// Keys from unroll's own attributes match exactly; keys read from metadata or the file
    /// date match with a small tolerance.
    public var keys: ImportedKeys {
        ImportedKeys(
            exact: Set(files.filter { $0.dateSource == "attributes" }.map(\.key)),
            approximate: files.filter { $0.dateSource != "attributes" }.map(\.key)
        )
    }
}

/// Files in a destination that its index doesn't know: all of them when there is no index yet
/// (e.g. copied earlier with Image Capture), or files added by hand later. They are recognized by
/// their name, size and capture time, like `rebuild-index` does.
public protocol ExistingFilesScanning: Sendable {
    /// Reads the keys of the files in `root` from file attributes or metadata, without hashing.
    /// Files at the `skipping` paths (already indexed) aren't read or counted.
    func scan(
        in root: URL, skipping: Set<String>, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async -> ExistingFiles

    /// Records the files in a new index, with hashes. `known` are the results of an earlier
    /// `scan`; files that haven't changed since are not read again. Returns how many were indexed.
    func index(
        _ destination: ResolvedDestination, known: [ExistingFile],
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async throws -> Int

    /// Adds files found by `scan` to the destination's existing index, with hashes.
    /// Returns how many were added.
    func add(
        _ files: [ExistingFile], to destination: ResolvedDestination,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async throws -> Int
}
