import Darwin
import Foundation
import UniformTypeIdentifiers
import UnrollCore

public struct ArrangeResult: Sendable, Equatable {
    public var moved = 0
    public var failed: [String] = []
    public var cancelled = false
    /// Folders removed because moving emptied them.
    public var removedFolders = 0
    /// Every move as "from<TAB>to", so it can be undone by hand.
    public var journal: URL?

    public init() {}
}

/// Moves the files already in a destination into a task's folder structure. Only moves within
/// the destination; never overwrites, copies or deletes a file, and keeps the index up to date.
public struct DestinationArranger: Sendable {
    let cameras: (any CameraModelReading)?

    public init(cameras: (any CameraModelReading)? = CameraModelReader()) {
        self.cameras = cameras
    }

    /// Reads the files in the destination and plans the moves. Writes nothing.
    public func plan(
        root: URL, template: FolderTemplate, rule: OtherFolderRule?,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async -> ArrangePlan {
        let urls = IndexRebuilder.mediaFiles(in: root)
        let inPhotos = (try? SQLiteIndex.openExisting(destinationRoot: root, readOnly: true)?.pathsAddedToPhotos()) ?? []
        var files: [ArrangeFile] = []
        for (done, url) in urls.enumerated() {
            if done % 50 == 0 { progress(done, urls.count) }
            let relative = IndexRebuilder.relativePath(of: url, root: root)
            let kind = Self.kind(of: url)
            var date: LocalTimestamp?
            var model: String?
            if kind != .other, let (key, source) = try? await IndexRebuilder.key(of: url), source != "file-date" {
                date = key.captureDate
            }
            if rule != nil, kind == .photo || kind == .video {
                model = await cameras?.cameraModel(of: url)
            }
            files.append(ArrangeFile(
                relativePath: relative, kind: kind, captureDate: date, cameraModel: model, inPhotos: inPhotos.contains(relative)
            ))
        }
        progress(urls.count, urls.count)
        return ArrangePlanner.plan(files: files, template: template, rule: rule) {
            FileManager.default.fileExists(atPath: root.appending(path: $0).path)
        }
    }

    /// Moves the files. A destination without an index gets one first, so the files stay known.
    /// Stops between files when the calling task is cancelled.
    public func apply(
        _ plan: ArrangePlan, destination: ResolvedDestination,
        indexing: @escaping @Sendable (_ done: Int, _ total: Int) -> Void,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async throws -> ArrangeResult {
        let root = destination.root
        if try SQLiteIndex.openExisting(destinationRoot: root, readOnly: true) == nil {
            _ = try await IndexRebuilder().rebuild(destination: destination, progress: indexing)
        }
        let lock = try DestinationLock(root: root)
        defer { withExtendedLifetime(lock) {} }
        guard let index = try SQLiteIndex.openExisting(destinationRoot: root, readOnly: false) else {
            throw SyncError.indexUnreadable("the index is missing")
        }

        var result = ArrangeResult()
        let journalURL = root.appending(path: SQLiteIndex.directoryName)
            .appending(path: "arrange-\(Self.timestamp()).tsv")
        FileManager.default.createFile(atPath: journalURL.path, contents: Data("from\tto\n".utf8))
        let journal = try FileHandle(forWritingTo: journalURL)
        defer { try? journal.close() }
        try journal.seekToEnd()
        result.journal = journalURL

        var emptied = Set<String>()
        for (done, move) in plan.moves.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }
            progress(done, plan.moves.count)
            do {
                let to = try Self.move(move, root: root)
                try journal.write(contentsOf: Data("\(move.from)\t\(to)\n".utf8))
                // The file has moved; the index follows. If this fails, matching still works,
                // because it uses name, size and capture time, not the path.
                try? index.moveItem(from: move.from, to: to)
                result.moved += 1
                emptied.insert((move.from as NSString).deletingLastPathComponent)
            } catch {
                result.failed.append("\(move.from): \(error.localizedDescription)")
            }
        }
        progress(plan.moves.count, plan.moves.count)
        try? journal.synchronize()
        result.removedFolders = Self.removeEmptyFolders(emptied, root: root)
        return result
    }

    /// Renames without replacing anything. If the planned name was taken meanwhile, the next free
    /// " (n)" name is used. Returns the final relative path.
    static func move(_ move: ArrangeMove, root: URL) throws -> String {
        let source = root.appending(path: move.from)
        let folder = (move.to as NSString).deletingLastPathComponent
        let name = (move.to as NSString).lastPathComponent
        try FileManager.default.createDirectory(
            at: root.appending(path: folder, directoryHint: .isDirectory), withIntermediateDirectories: true
        )
        var suffix = 0
        while true {
            let to = ArrangePlanner.target(name, folder: folder, suffix: suffix)
            if renamex_np(source.path, root.appending(path: to).path, UInt32(RENAME_EXCL)) == 0 { return to }
            guard errno == EEXIST, suffix < 1_000 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            suffix += 1
        }
    }

    /// Removes folders that moving left empty (ignoring .DS_Store), deepest first, and their
    /// parents if those are empty now too. Never removes the destination itself.
    static func removeEmptyFolders(_ folders: Set<String>, root: URL) -> Int {
        var removed = 0
        var candidates = folders.filter { !$0.isEmpty }
        while !candidates.isEmpty {
            var parents = Set<String>()
            for folder in candidates.sorted(by: { $0.count > $1.count }) {
                let url = root.appending(path: folder, directoryHint: .isDirectory)
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                      contents.allSatisfy({ $0 == ".DS_Store" }) else { continue }
                try? FileManager.default.removeItem(at: url.appending(path: ".DS_Store"))
                guard rmdir(url.path) == 0 else { continue }
                removed += 1
                let parent = (folder as NSString).deletingLastPathComponent
                if !parent.isEmpty { parents.insert(parent) }
            }
            candidates = parents
        }
        return removed
    }

    static func kind(of file: URL) -> ArrangeFile.Kind {
        let ext = file.pathExtension.uppercased()
        if ext == "AAE" { return .sidecar }
        guard let type = UTType(filenameExtension: file.pathExtension) else { return .other }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .audiovisualContent) { return .video }
        return .other
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
