import Foundation
import Noora
import UnrollCore
import UnrollStore

struct MainMenuScreen: Screen {
    enum Action: Equatable {
        case run(UUID), preview(UUID), otherTasks, newTask, manage, status, rebuild, help, settings, quit
    }

    func run(_ app: AppContext) async -> Next {
        let tasks = app.loadTasks()
        let lastUsedID = app.store.loadSettings().lastUsedTaskID
        let last = tasks.first { $0.id == lastUsedID } ?? tasks.first
        print("")
        print(app.noora.format("\(.primary("unroll"))"))

        // The last used task comes first, so Enter runs it. Whether its destination and device are
        // connected shows in the checks once Run or Preview is chosen.
        var choices: [Choice<Action>] = []
        if let last {
            choices.append(Choice("Run \"\(last.name)\"  \(Self.lastRunText(last))", .run(last.id)))
            choices.append(Choice("Preview \"\(last.name)\"  (dry run)", .preview(last.id)))
        }
        if tasks.count > 1 {
            choices.append(Choice("Other tasks…", .otherTasks))
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
        case .otherTasks: return .screen(TaskPickerScreen())
        case .newTask: return .screen(NewTaskScreen())
        case .manage: return .screen(ManageTasksScreen())
        case .status: return .screen(StatusScreen())
        case .rebuild: return .screen(RebuildScreen())
        case .help: return .screen(HelpScreen())
        case .settings: return .screen(SettingsScreen())
        case .quit: return .quit
        }
    }

    static func lastRunText(_ task: SyncTask) -> String {
        guard let lastRun = task.lastRun else { return "(never run)" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "(last run \(formatter.localizedString(for: lastRun, relativeTo: Date())))"
    }
}

/// All tasks; choosing one offers Run or Preview. Whichever runs becomes the last used task.
struct TaskPickerScreen: Screen {
    enum Action: Equatable {
        case run, preview, back
    }

    func run(_ app: AppContext) async -> Next {
        let tasks = app.loadTasks()
        let picked = app.noora.menu(
            "Which task?",
            tasks.map { Choice("\($0.name)  \(MainMenuScreen.lastRunText($0))", Optional($0.id)) } + [Choice("Back", nil)],
            filterable: tasks.count > 10
        )
        guard let id = picked, let task = tasks.first(where: { $0.id == id }) else { return .mainMenu }

        let choices = [
            Choice("Run \"\(task.name)\"", Action.run),
            Choice("Preview \"\(task.name)\"  (dry run)", .preview),
            Choice("Back", .back),
        ]
        switch app.noora.menu("What do you want to do with \"\(task.name)\"?", choices) {
        case .run: return .screen(SyncScreen(taskID: task.id, mode: .run))
        case .preview: return .screen(SyncScreen(taskID: task.id, mode: .preview))
        case .back: return .screen(TaskPickerScreen())
        }
    }
}
