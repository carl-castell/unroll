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

/// App settings in `settings.json`, next to the tasks.
public struct Settings: Codable, Sendable, Equatable {
    /// Preselected in the main menu.
    public var lastUsedTaskID: UUID?
    /// Defaults offered when creating a task.
    public var defaultFolderTemplate: FolderTemplate = .default
    public var defaultVersions: VersionPolicy = .original
    public var defaultNotify = false

    public init() {}
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

    // MARK: Settings

    public var settingsURL: URL { directory.appending(path: "settings.json") }

    private struct SettingsFile: Codable {
        var version: Int
        var settings: Settings
    }

    /// Defaults when the file is missing or unreadable; settings are conveniences, not configuration.
    public func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL),
              let file = try? Self.decoder.decode(SettingsFile.self, from: data),
              file.version == Self.currentVersion else { return Settings() }
        return file.settings
    }

    public func saveSettings(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(SettingsFile(version: Self.currentVersion, settings: settings))
        try data.write(to: settingsURL, options: .atomic)
    }

    public func saveLastUsedTask(_ id: UUID) throws {
        var settings = loadSettings()
        settings.lastUsedTaskID = id
        try saveSettings(settings)
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
