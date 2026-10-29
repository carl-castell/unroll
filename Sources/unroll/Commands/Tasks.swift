import ArgumentParser
import Foundation
import UnrollCore
import UnrollDevice
import UnrollStore

struct Tasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create, list and remove sync tasks.",
        subcommands: [List.self, Add.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List sync tasks.")

        func run() throws {
            let tasks: [SyncTask]
            do {
                tasks = try TaskStore().loadTasks()
            } catch {
                printError(String(describing: error))
                throw UnrollExit.invalidTask
            }
            if tasks.isEmpty {
                print("No sync tasks yet. Create one with `unroll tasks add`.")
            }
            let resolver = VolumeResolver()
            for task in tasks {
                let connected = resolver.resolve(task.destination) != nil
                let destination = Format.destination(task.destination, resolver: resolver) + (connected ? "" : ", not connected")
                print("\(task.name)")
                print("  device:      \(task.device.name)")
                print("  destination: \(destination)")
                print("  folders:     \(task.folderTemplate)   versions: \(task.versions.rawValue)")
                print("  last run:    \(task.lastRun?.formatted() ?? "never")")
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a sync task without the interactive wizard.",
            discussion: "The device must be connected. The destination folder is created on the first run."
        )

        @Option(help: "Name of the task, e.g. \"iPhone → SSD\".")
        var name: String

        @Option(help: "Device name or ID. Defaults to the only connected device.")
        var device: String?

        @Option(help: "Destination folder.", completion: .directory)
        var destination: String

        @Option(help: "Folder structure inside the destination. Tokens: YYYY, MM, DD.")
        var folderTemplate = FolderTemplate.default.pattern

        @Option(help: "Which versions of edited photos to copy: original, edited or both.")
        var versions = VersionPolicy.original

        @MainActor
        func run() async throws {
            let store = TaskStore()
            var tasks: [SyncTask]
            do {
                tasks = try store.loadTasks()
            } catch {
                printError(String(describing: error))
                throw UnrollExit.invalidTask
            }
            guard SyncTask.find(name, in: tasks) == nil else {
                printError("A task named \"\(name)\" already exists.")
                throw UnrollExit.invalidTask
            }
            guard let template = try? FolderTemplate(folderTemplate) else {
                printError("\"\(folderTemplate)\" isn't a valid folder structure. Example: YYYY/YYYY-MM")
                throw UnrollExit.invalidTask
            }

            let deviceInfo = try await pickDevice()
            let folder = URL(filePath: (destination as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            let target: Destination
            do {
                target = try VolumeResolver().destination(forFolder: folder)
            } catch {
                printError(String(describing: error))
                throw UnrollExit.destinationMissing
            }

            let task = SyncTask(
                name: name,
                device: .init(id: deviceInfo.id, name: deviceInfo.name),
                destination: target,
                folderTemplate: template,
                versions: versions
            )
            tasks.append(task)
            try store.saveTasks(tasks)
            print("Created \"\(task.name)\": \(deviceInfo.name) → \(Format.destination(folder, volumeName: target.volumeName))")
            print("Preview it with: unroll run \"\(task.name)\" --dry-run")
        }

        @MainActor
        private func pickDevice() async throws -> DeviceInfo {
            let devices = await ICCDeviceBrowser().connectedDevices()
            if let device {
                guard let match = devices.first(where: {
                    $0.id.rawValue == device || $0.name.localizedCaseInsensitiveCompare(device) == .orderedSame
                }) else {
                    printError("No connected device matches \"\(device)\".")
                    throw UnrollExit.deviceUnavailable
                }
                return match
            }
            switch devices.count {
            case 0:
                printError("No iPhone or iPad connected. Connect one with a cable and unlock it.")
                throw UnrollExit.deviceUnavailable
            case 1:
                return devices[0]
            default:
                printError("Several devices are connected; choose one with --device: "
                    + devices.map { "\"\($0.name)\"" }.joined(separator: ", "))
                throw UnrollExit.deviceUnavailable
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a sync task. Files and the index on the destination are kept."
        )

        @Argument(help: "The task's name, or the start of its ID.")
        var task: String

        func run() throws {
            let store = TaskStore()
            let task = try loadTask(task, from: store)
            try store.saveTasks(try store.loadTasks().filter { $0.id != task.id })
            print("Removed \"\(task.name)\". Files and the index on the destination were not touched.")
        }
    }
}

extension VersionPolicy: ExpressibleByArgument {}
