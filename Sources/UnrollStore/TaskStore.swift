import Foundation
import UnrollCore

public enum TaskStoreError: Error, Equatable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case unsupportedVersion(path: String, version: Int)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason): "Couldn't read \(path): \(reason)"
        case .unsupportedVersion(let path, let version): "\(path) has version \(version), which this unroll doesn't support."
        }
    }
}

/// Sync tasks in `~/.config/unroll/tasks.json` (or `$XDG_CONFIG_HOME/unroll`).
public struct TaskStore: Sendable {
    public let directory: URL

    public init(directory: URL = TaskStore.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
        return base.appending(path: "unroll", directoryHint: .isDirectory)
    }

    public var tasksURL: URL { directory.appending(path: "tasks.json") }

    private struct TasksFile: Codable {
        var version: Int
        var tasks: [SyncTask]
    }

    private static let currentVersion = 1

    public func loadTasks() throws -> [SyncTask] {
        guard FileManager.default.fileExists(atPath: tasksURL.path) else { return [] }
        let file: TasksFile
        do {
            file = try Self.decoder.decode(TasksFile.self, from: Data(contentsOf: tasksURL))
        } catch {
            throw TaskStoreError.unreadable(path: tasksURL.path, reason: String(describing: error))
        }
        guard file.version == Self.currentVersion else {
            throw TaskStoreError.unsupportedVersion(path: tasksURL.path, version: file.version)
        }
        return file.tasks
    }

    public func saveTasks(_ tasks: [SyncTask]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(TasksFile(version: Self.currentVersion, tasks: tasks))
        try data.write(to: tasksURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
