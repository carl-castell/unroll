import Foundation
import Noora
import UnrollCore
import UnrollStore

struct MainMenuScreen: Screen {
    enum Action: Equatable {
        case run(UUID), preview(UUID), newTask, manage, status, rebuild, help, settings, quit
    }

    func run(_ app: AppContext) async -> Next {
        let tasks = app.loadTasks()
        let lastUsedID = app.store.loadSettings().lastUsedTaskID
        let last = tasks.first { $0.id == lastUsedID } ?? tasks.first
        await printHeader(app, task: last)

        // Noora's menus have no unselectable lines, so there is no separator and no extra arrow:
        // the selector is the only marker, and the last used task comes first so Enter runs it.
        var choices: [Choice<Action>] = []
        if let last {
            choices.append(Choice("Run \"\(last.name)\"  \(Self.lastRunText(last))", .run(last.id)))
            choices.append(Choice("Preview \"\(last.name)\"  (dry run)", .preview(last.id)))
        }
        for task in tasks where task.id != last?.id {
            choices.append(Choice("Run \"\(task.name)\"", .run(task.id)))
        }
        choices.append(Choice("New sync task", .newTask))
        if !tasks.isEmpty {
            choices.append(Choice("Edit / delete task", .manage))
        }
        choices.append(Choice("Status & history", .status))
        if !tasks.isEmpty {
            choices.append(Choice("Rebuild index", .rebuild))
        }
        choices += [Choice("Help", .help), Choice("Settings", .settings), Choice("Quit", .quit)]

        switch app.noora.menu("What do you want to do?", choices) {
        case .run(let id): return .screen(SyncScreen(taskID: id, mode: .run))
        case .preview(let id): return .screen(SyncScreen(taskID: id, mode: .preview))
        case .newTask: return .screen(NewTaskScreen())
        case .manage: return .screen(ManageTasksScreen())
        case .status: return .screen(StatusScreen())
        case .rebuild: return .screen(RebuildScreen())
        case .help: return .screen(HelpScreen())
        case .settings: return .screen(SettingsScreen())
        case .quit: return .quit
        }
    }

    /// "unroll" and whether the last task's destination and device are connected.
    private func printHeader(_ app: AppContext, task: SyncTask?) async {
        print("")
        print(app.noora.format("\(.primary("unroll"))"))
        guard let task else { return }
        let destination = app.resolver.resolve(task.destination) != nil
        let device = await app.browser.connectedDevices().contains { $0.id == task.device.id }
        func mark(_ ok: Bool) -> TerminalText.Component { ok ? .success("✓") : .danger("✗") }
        let status: TerminalText = "\(.muted("Destination")) \"\(task.destination.volumeName)\" \(mark(destination))   \(.muted("Device")) \"\(task.device.name)\" \(mark(device))"
        print(app.noora.format(status))
    }

    static func lastRunText(_ task: SyncTask) -> String {
        guard let lastRun = task.lastRun else { return "(never run)" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "(last run \(formatter.localizedString(for: lastRun, relativeTo: Date())))"
    }
}
