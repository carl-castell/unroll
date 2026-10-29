import Foundation
import Noora
import UnrollCore
import UnrollStore

/// The home screen of one task: the last used one, or the one picked under Other tasks….
/// Its name is the heading; More… holds its other options.
struct MainMenuScreen: Screen {
    enum Action: Equatable {
        case run(UUID), more(UUID), otherTasks, newTask, helpAndSettings, quit
    }

    /// The task to show; nil shows the last used one.
    var taskID: UUID?

    func run(_ app: AppContext) async -> Next {
        let tasks = app.loadTasks()
        let selectedID = taskID ?? app.store.loadSettings().lastUsedTaskID
        let task = tasks.first { $0.id == selectedID } ?? tasks.first
        let devices = await app.browser.connectedDevices()
        print("")
        print(app.noora.format("\(.primary("unroll"))"))
        let connected: TerminalText = devices.isEmpty
            ? "\(.muted("No iPhone or iPad connected"))"
            : "\(.muted("Connected:")) \(devices.map { "\($0.name) (\($0.productKind ?? "device"))" }.joined(separator: ", "))"
        print(app.noora.format(connected))

        guard let task else {
            let choices = [
                Choice("New sync task", Action.newTask), Choice("Help & settings…", .helpAndSettings), Choice("Quit", .quit),
            ]
            return next(for: app.noora.menu("No sync tasks yet", choices))
        }

        // Run comes first, so Enter runs the task.
        var choices = [Choice("Run", Action.run(task.id)), Choice("More…", .more(task.id))]
        choices.append(Choice(tasks.count > 1 ? "Other tasks…" : "New sync task", tasks.count > 1 ? .otherTasks : .newTask))
        choices += [Choice("Help & settings…", .helpAndSettings), Choice("Quit", .quit)]
        let heading = "\(Self.readiness(task, devices: devices, app: app)) \(task.name)  \(Self.lastRunText(task))"
        return next(for: app.noora.menu("\(heading)", choices))
    }

    private func next(for action: Action) -> Next {
        switch action {
        case .run(let id): .screen(SyncScreen(taskID: id, mode: .run))
        case .more(let id): .screen(TaskMoreScreen(taskID: id))
        case .otherTasks: .screen(TaskPickerScreen(currentID: taskID))
        case .newTask: .screen(NewTaskScreen())
        case .helpAndSettings: .screen(HelpAndSettingsScreen(returnTo: taskID))
        case .quit: .quit
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

/// One task's other options. Back returns to that task's home.
struct TaskMoreScreen: Screen {
    enum Action: Equatable {
        case preview, edit, delete, rebuild, history, back
    }

    let taskID: UUID

    func run(_ app: AppContext) async -> Next {
        guard let task = app.task(taskID) else { return .mainMenu }
        let choices = [
            Choice("Preview (dry run)", Action.preview),
            Choice("Edit task", .edit),
            Choice("Delete task", .delete),
            Choice("Rebuild index", .rebuild),
            Choice("History", .history),
            Choice("Back", .back),
        ]
        switch app.noora.menu("More for \"\(task.name)\"", choices) {
        case .preview: return .screen(SyncScreen(taskID: task.id, mode: .preview))
        case .edit: return .screen(EditTaskScreen(taskID: task.id))
        case .delete: return deleteTask(task, app: app)
        case .rebuild: return .screen(RebuildScreen(taskID: task.id))
        case .history: return .screen(HistoryScreen(taskID: task.id))
        case .back: return .screen(MainMenuScreen(taskID: task.id))
        }
    }

    private func deleteTask(_ task: SyncTask, app: AppContext) -> Next {
        let confirmed = app.noora.yesOrNoChoicePrompt(
            question: "Delete \"\(task.name)\"?", defaultAnswer: false,
            description: "Only the task is removed. Files and the index on the destination are kept."
        )
        guard confirmed else { return .screen(TaskMoreScreen(taskID: task.id)) }
        do {
            try app.delete(task.id)
            app.noora.success("Deleted \"\(task.name)\".")
        } catch {
            app.showError("The task couldn't be deleted.", takeaways: [String(describing: error)])
        }
        return .mainMenu
    }
}

/// All other tasks, each with its readiness dot, plus New sync task. Picking one opens its home.
struct TaskPickerScreen: Screen {
    var currentID: UUID?

    func run(_ app: AppContext) async -> Next {
        let tasks = app.loadTasks()
        let current = currentID ?? app.store.loadSettings().lastUsedTaskID ?? tasks.first?.id
        let devices = await app.browser.connectedDevices()
        enum Pick: Equatable { case task(UUID), newTask, back }
        let others = tasks.filter { $0.id != current }
        let choices = others.map { task in
            Choice("\(MainMenuScreen.readiness(task, devices: devices, app: app)) \(task.name)  \(MainMenuScreen.lastRunText(task))", Pick.task(task.id))
        } + [Choice("  + New sync task", .newTask), Choice("  Back", .back)]
        switch app.noora.menu("Other tasks", choices, filterable: others.count > 10) {
        case .task(let id): return .screen(MainMenuScreen(taskID: id))
        case .newTask: return .screen(NewTaskScreen())
        case .back: return .screen(MainMenuScreen(taskID: currentID))
        }
    }
}

struct HelpAndSettingsScreen: Screen {
    /// The task whose home to return to.
    var returnTo: UUID?

    func run(_ app: AppContext) async -> Next {
        enum Action: Equatable { case help, settings, back }
        let choices = [Choice("Help", Action.help), Choice("Settings", .settings), Choice("Back", .back)]
        switch app.noora.menu("Help & settings", choices) {
        case .help: return .screen(HelpScreen(returnTo: returnTo))
        case .settings: return .screen(SettingsScreen(returnTo: returnTo))
        case .back: return .screen(MainMenuScreen(taskID: returnTo))
        }
    }
}
