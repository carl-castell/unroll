import ArgumentParser
import Foundation
import UnrollCore
import UnrollDevice
import UnrollStore

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show connected devices and whether each task is ready to run.",
        discussion: """
            A task is ready when its device and its destination are both connected.

            Examples:
              unroll status
              unroll status --json
            """
    )

    @Flag(help: "Machine-readable output: a single JSON object.")
    var json = false

    @MainActor
    func run() async throws {
        let tasks: [SyncTask]
        do {
            tasks = try TaskStore().loadTasks()
        } catch {
            printError(String(describing: error))
            throw UnrollExit.invalidTask
        }
        let devices = await ICCDeviceBrowser().connectedDevices()
        let resolver = VolumeResolver()
        let rows = tasks.map { task -> TaskStatus in
            let destination = resolver.resolve(task.destination)
            let files = destination.flatMap { try? SQLiteIndex.openExisting(destinationRoot: $0.root, readOnly: true)?.meta().itemCount }
            return TaskStatus(
                task: task,
                deviceConnected: devices.contains { $0.id == task.device.id },
                destination: destination,
                files: files
            )
        }
        if json {
            printJSON(devices: devices, rows: rows)
        } else {
            printText(devices: devices, rows: rows, resolver: resolver)
        }
    }

    private struct TaskStatus {
        let task: SyncTask
        let deviceConnected: Bool
        let destination: ResolvedDestination?
        let files: Int?

        var ready: Bool { deviceConnected && destination != nil }
    }

    private func printText(devices: [DeviceInfo], rows: [TaskStatus], resolver: VolumeResolver) {
        print("Connected devices: " + (devices.isEmpty ? "none" : devices.map { "\($0.name) (\($0.productKind ?? "device"))" }.joined(separator: ", ")))
        if rows.isEmpty {
            print("\nNo sync tasks yet. Create one with `unroll tasks add`, or run `unroll` in a terminal.")
            return
        }
        for row in rows {
            let task = row.task
            print("\n\(row.ready ? "●" : "○") \(task.name)  \(row.ready ? "ready" : "not ready")")
            print("    device:      \(task.device.name) \(row.deviceConnected ? "✓" : "✗ not connected")")
            print("    destination: \(Format.destination(task.destination, resolver: resolver)) \(row.destination != nil ? "✓" : "✗ not connected")")
            print("    last run:    \(task.lastRun?.formatted(date: .abbreviated, time: .shortened) ?? "never")"
                + (row.files.map { "   files in destination: \($0)" } ?? ""))
        }
    }

    private func printJSON(devices: [DeviceInfo], rows: [TaskStatus]) {
        let object: [String: Any] = [
            "format": JSONRenderer.formatVersion,
            "devices": devices.map { ["id": $0.id.rawValue, "name": $0.name, "kind": $0.productKind ?? ""] },
            "tasks": rows.map { row -> [String: Any] in
                var task: [String: Any] = [
                    "id": row.task.id.uuidString,
                    "name": row.task.name,
                    "ready": row.ready,
                    "device": ["id": row.task.device.id.rawValue, "name": row.task.device.name, "connected": row.deviceConnected],
                    "destination": [
                        "volume": row.task.destination.volumeName,
                        "connected": row.destination != nil,
                        "path": row.destination?.root.path ?? "/" + row.task.destination.path,
                    ] as [String: Any],
                ]
                if let lastRun = row.task.lastRun { task["lastRun"] = lastRun.ISO8601Format() }
                if let files = row.files { task["files"] = files }
                return task
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}
