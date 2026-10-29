import Foundation
import Noora
import UnrollCore
import UnrollStore

/// The main menu: run or preview the last used task, pick another task, or open More… for the rest.
struct MainMenuScreen: Screen {
    enum Action: Equatable {
        case run(UUID), preview(UUID), otherTasks, newTask, more, quit
    }

    func run(_ app: AppContext) async -> Next {
        let tasks = app.loadTasks()
        let lastUsedID = app.store.loadSettings().lastUsedTaskID
        let last = tasks.first { $0.id == lastUsedID } ?? tasks.first
        let devices = await app.browser.connectedDevices()
        print("")
        print(app.noora.format("\(.primary("unroll"))"))
        let connected: TerminalText = devices.isEmpty
            ? "\(.muted("No iPhone or iPad connected"))"
            : "\(.muted("Connected:")) \(devices.map { "\($0.name) (\($0.productKind ?? "device"))" }.joined(separator: ", "))"
        print(app.noora.format(connected))

        // The last used task comes first, so Enter runs it. The first column holds its readiness dot.
        var choices: [Choice<Action>] = []
        if let last {
            let ready = Self.readiness(last, devices: devices, app: app)
            choices.append(Choice("\(ready) Run \"\(last.name)\"  \(Self.lastRunText(last))", .run(last.id)))
            choices.append(Choice("\(ready) Preview \"\(last.name)\"  (dry run)", .preview(last.id)))
        }
        var rest: [Choice<Action>] = []
        if tasks.count > 1 {
            rest.append(Choice("Other tasks…", .otherTasks))
        }
        if tasks.isEmpty {
            rest.append(Choice("New sync task", .newTask))
        }
        rest += [Choice("More…", .more), Choice("Quit", .quit)]
        let indent = last == nil ? "" : "  "
        choices += rest.map { Choice(indent + $0.description, $0.action) }

        switch app.noora.menu("What do you want to do?", choices) {
        case .run(let id): return .screen(SyncScreen(taskID: id, mode: .run))
        case .preview(let id): return .screen(SyncScreen(taskID: id, mode: .preview))
        case .otherTasks: return .screen(TaskPickerScreen())
        case .newTask: return .screen(NewTaskScreen())
        case .more: return .screen(MoreScreen())
        case .quit: return .quit
        }
    }

    /// A green dot when the task's device and destination are both available right now, else a grey one.
    static func readiness(_ task: SyncTask, devices: [DeviceInfo], app: AppContext) -> String {
        let ready = devices.contains { $0.id == task.device.id } && app.resolver.resolve(task.destination) != nil
        return app.noora.format(ready ? "\(.success("●"))" : "\(.muted("○"))")
    }

    static func lastRunText(_ task: SyncTask) -> String {
        guard let lastRun = task.lastRun else { return "(never run)" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "(last run \(formatter.localizedString(for: lastRun, relativeTo: Date())))"
    }
}

/// Everything besides running: tasks, status, index, help and settings.
struct MoreScreen: Screen {
    enum Action: Equatable {
        case newTask, manage, status, rebuild, help, settings, back
    }

    func run(_ app: AppContext) async -> Next {
        let hasTasks = !app.loadTasks().isEmpty
        var choices = [Choice("New sync task", Action.newTask)]
        if hasTasks {
            choices.append(Choice("Edit / delete task", .manage))
        }
        choices.append(Choice("Status & history", .status))
        if hasTasks {
            choices.append(Choice("Rebuild index", .rebuild))
        }
        choices += [Choice("Help", .help), Choice("Settings", .settings), Choice("Back", .back)]

        switch app.noora.menu("More", choices) {
        case .newTask: return .screen(NewTaskScreen())
        case .manage: return .screen(ManageTasksScreen())
        case .status: return .screen(StatusScreen())
        case .rebuild: return .screen(RebuildScreen())
        case .help: return .screen(HelpScreen())
        case .settings: return .screen(SettingsScreen())
        case .back: return .mainMenu
        }
    }
}

/// All tasks; choosing one offers Run or Preview. Whichever runs becomes the last used task.
struct TaskPickerScreen: Screen {
    enum Action: Equatable {
        case run, preview, back
    }

    func run(_ app: AppContext) async -> Next {
        let tasks = app.loadTasks()
        let devices = await app.browser.connectedDevices()
        let picked = app.noora.menu(
            "Which task?",
            tasks.map { task in
                let ready = MainMenuScreen.readiness(task, devices: devices, app: app)
                return Choice("\(ready) \(task.name)  \(MainMenuScreen.lastRunText(task))", Optional(task.id))
            } + [Choice("  Back", nil)],
            filterable: tasks.count > 10
        )
        guard let id = picked, let task = tasks.first(where: { $0.id == id }) else { return .mainMenu }
        let ready = MainMenuScreen.readiness(task, devices: devices, app: app)

        let choices = [
            Choice("\(ready) Run \"\(task.name)\"", Action.run),
            Choice("\(ready) Preview \"\(task.name)\"  (dry run)", .preview),
            Choice("  Back", .back),
        ]
        switch app.noora.menu("What do you want to do with \"\(task.name)\"?", choices) {
        case .run: return .screen(SyncScreen(taskID: task.id, mode: .run))
        case .preview: return .screen(SyncScreen(taskID: task.id, mode: .preview))
        case .back: return .screen(TaskPickerScreen())
        }
    }
}
