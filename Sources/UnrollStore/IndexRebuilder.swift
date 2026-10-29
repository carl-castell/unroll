import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UnrollCore

public struct RebuildResult: Sendable, Equatable {
    public var files = 0
    /// Keys restored exactly from the attributes unroll writes on every import.
    public var fromAttributes = 0
    /// Capture time read from EXIF or QuickTime metadata.
    public var fromMetadata = 0
    /// Only the file's date was available.
    public var fromFileDate = 0
    /// Files whose key matched a file indexed earlier in the rebuild; indexed once.
    public var duplicateKeys = 0

    public init() {}
}

/// Recreates a destination's index from the files in it. Reads the files only; nothing in
/// the destination is renamed, changed or deleted, except unroll's own `.unroll/` folder.
public struct IndexRebuilder: Sendable {
    public init() {}

    /// - Parameter known: files read by an earlier scan. A file whose path and size are unchanged
    ///   keeps the key read then, so only its hash is computed.
    public func rebuild(
        destination: ResolvedDestination, known: [ExistingFile] = [],
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async throws -> RebuildResult {
        let root = destination.root
        let lock = try DestinationLock(root: root)
        defer { withExtendedLifetime(lock) {} }

        let files = Self.mediaFiles(in: root)
        let imageBases = Self.imageBases(of: files)
        let finalURL = SQLiteIndex.url(forDestinationRoot: root)
        let rebuildURL = finalURL.deletingLastPathComponent().appending(path: "index.rebuild.sqlite")
        var result = RebuildResult()
        let knownByPath = Dictionary(known.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        do {
            let index = try SQLiteIndex.createForRebuild(at: rebuildURL)
            var seen = Set<ItemKey>()
            for (done, file) in files.enumerated() {
                progress(done, files.count)
                let entry = try await Self.describe(file, root: root, imageBases: imageBases, known: knownByPath)
                result.files += 1
                switch entry.dateSource {
                case "attributes": result.fromAttributes += 1
                case "metadata": result.fromMetadata += 1
                default: result.fromFileDate += 1
                }
                guard seen.insert(entry.item.key).inserted else {
                    result.duplicateKeys += 1
                    continue
                }
                try index.record(entry.item, dateSource: entry.dateSource)
            }
            progress(files.count, files.count)
        }

        // Replace the old index only once the new one is complete.
        try SQLiteIndex.checkpoint(at: finalURL)
        guard rename(rebuildURL.path, finalURL.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: finalURL.path + suffix)
        }
        // No run can be active while the lock is held, so the temp area holds only leftovers.
        let partial = DestinationStore.partialDirectory(root: root)
        for leftover in (try? FileManager.default.contentsOfDirectory(at: partial, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: leftover)
        }
        return result
    }

    // MARK: Scanning

    /// Regular files in the destination, skipping hidden files, unroll's own `.unroll/` folder, and
    /// the inside of packages such as a `.photoslibrary` kept in the same folder.
    public static func mediaFiles(in root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
    }

    /// The file's path relative to the destination root.
    static func relativePath(of file: URL, root: URL) -> String {
        let base = root.resolvingSymlinksInPath().path
        return String(file.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
    }

    /// Photos by folder and name without extension, to recognize Live Photo videos next to them.
    static func imageBases(of files: [URL]) -> Set<String> {
        Set(files.filter { type(of: $0)?.conforms(to: .image) == true }.map(baseKey))
    }

    static func describe(
        _ file: URL, root: URL, imageBases: Set<String>, known: [String: ExistingFile]
    ) async throws -> (item: IndexedItem, dateSource: String) {
        let relative = relativePath(of: file, root: root)
        let key: ItemKey
        let source: String
        if let earlier = known[relative],
           let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == earlier.key.size {
            (key, source) = (earlier.key, earlier.dateSource)
        } else {
            (key, source) = try await self.key(of: file)
        }
        let filename = key.filename
        let item = IndexedItem(
            key: key,
            relativePath: relative,
            sha256: try hash(of: file),
            role: role(of: file, filename: filename, imageBases: imageBases),
            assetID: nil,
            deviceID: attribute(UnrollAttribute.deviceID, of: file).map(DeviceID.init),
            originalFilename: nil,
            importedAt: Date()
        )
        return (item, source)
    }

    /// A file's key: name and capture time from unroll's attributes, else from EXIF or QuickTime
    /// metadata, else the file date. Also returns where the time came from.
    static func key(of file: URL) async throws -> (key: ItemKey, dateSource: String) {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let filename = attribute(UnrollAttribute.filename, of: file) ?? withoutCollisionSuffix(file.lastPathComponent)
        let captureDate: LocalTimestamp
        let source: String
        if let stored = attribute(UnrollAttribute.captureDate, of: file).flatMap(LocalTimestamp.init(parsing:)) {
            (captureDate, source) = (stored, "attributes")
        } else if let embedded = await metadataDate(of: file) {
            (captureDate, source) = (embedded, "metadata")
        } else {
            let date = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            (captureDate, source) = (LocalTimestamp(date: date, interpretedIn: .current), "file-date")
        }
        return (ItemKey(captureDate: captureDate, size: Int64(values.fileSize ?? 0), filename: filename), source)
    }

    /// The capture clock time from EXIF DateTimeOriginal (photos) or the QuickTime creation date (videos).
    private static func metadataDate(of file: URL) async -> LocalTimestamp? {
        guard let type = type(of: file) else { return nil }
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
                  let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
            return LocalTimestamp(parsing: original)
        }
        if type.conforms(to: .audiovisualContent) {
            let asset = AVURLAsset(url: file)
            guard let metadata = try? await asset.load(.metadata) else { return nil }
            let creation = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate)
            // e.g. "2026-06-02T11:46:26+0400": the leading part is the clock time.
            guard let text = try? await creation.first?.load(.stringValue) else { return nil }
            return LocalTimestamp(parsing: text)
        }
        return nil
    }

    private static func role(of file: URL, filename: String, imageBases: Set<String>) -> ItemRole {
        let ext = (filename as NSString).pathExtension.uppercased()
        if ext == "AAE" || ext == "DAT" { return .sidecar }
        if filename.range(of: #"^[A-Z]+_E\d"#, options: .regularExpression) != nil { return .edited }
        if type(of: file)?.conforms(to: .audiovisualContent) == true, imageBases.contains(baseKey(file)) {
            return .livePhotoVideo
        }
        return .original
    }

    // MARK: Helpers

    /// "IMG_1234 (1).HEIC" → "IMG_1234.HEIC", for files without unroll's attributes.
    static func withoutCollisionSuffix(_ name: String) -> String {
        name.replacingOccurrences(of: #" \(\d+\)(?=\.[^.]+$|$)"#, with: "", options: .regularExpression)
    }

    /// Folder plus file name without extension, to pair a Live Photo's video with its photo.
    private static func baseKey(_ file: URL) -> String {
        file.deletingPathExtension().path
    }

    private static func type(of file: URL) -> UTType? {
        UTType(filenameExtension: file.pathExtension)
    }

    private static func attribute(_ name: String, of file: URL) -> String? {
        var buffer = [UInt8](repeating: 0, count: 1_024)
        let length = getxattr(file.path, name, &buffer, buffer.count, 0, 0)
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }

    private static func hash(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}

/// Recognizes files already in a destination without an index, using the same rules as a rebuild.
public struct ExistingFilesScanner: ExistingFilesScanning {
    public init() {}

    public func scan(
        in root: URL, skipping: Set<String>, progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> ExistingFiles {
        let files = IndexRebuilder.mediaFiles(in: root)
            .map { ($0, IndexRebuilder.relativePath(of: $0, root: root)) }
            .filter { !skipping.contains($0.1) }
        var found = ExistingFiles(count: files.count)
        for (done, (file, relative)) in files.enumerated() {
            if done % 50 == 0 { progress(done, files.count) }
            guard let (key, source) = try? await IndexRebuilder.key(of: file) else { continue }
            found.files.append(ExistingFile(relativePath: relative, key: key, dateSource: source))
        }
        progress(files.count, files.count)
        return found
    }

    public func index(
        _ destination: ResolvedDestination, known: [ExistingFile], progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> Int {
        let result = try await IndexRebuilder().rebuild(destination: destination, known: known, progress: progress)
        return result.files - result.duplicateKeys
    }

    public func add(
        _ files: [ExistingFile], to destination: ResolvedDestination, progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> Int {
        let root = destination.root
        let lock = try DestinationLock(root: root)
        defer { withExtendedLifetime(lock) {} }
        guard let index = try SQLiteIndex.openExisting(destinationRoot: root, readOnly: false) else { return 0 }
        let imageBases = IndexRebuilder.imageBases(of: IndexRebuilder.mediaFiles(in: root))
        var added = 0
        for (done, file) in files.enumerated() {
            progress(done, files.count)
            let url = root.appending(path: file.relativePath)
            guard let entry = try? await IndexRebuilder.describe(
                url, root: root, imageBases: imageBases, known: [file.relativePath: file]
            ) else { continue }
            // A file with the same name, size and capture time as an indexed one (a second copy)
            // can't be recorded under that key; it still counts as imported through the first.
            if (try? index.record(entry.item, dateSource: entry.dateSource)) != nil { added += 1 }
        }
        progress(files.count, files.count)
        return added
    }
}
