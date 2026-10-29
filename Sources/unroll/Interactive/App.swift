import Foundation
import Noora
import UnrollCore
import UnrollDevice
import UnrollStore

/// One screen of the interactive interface. It does one thing and says where to go next.
@MainActor
protocol Screen {
    func run(_ app: AppContext) async -> Next
}

enum Next {
    case mainMenu
    case screen(any Screen)
    case quit
}

/// Shared services for all screens.
@MainActor
final class AppContext {
    let noora = Noora(content: .unroll)
    let store = TaskStore()
    let resolver = VolumeResolver()
    let browser = ICCDeviceBrowser()
    let engine: SyncEngine

    init() {
        engine = SyncEngine(
            devices: browser, destinations: resolver, indexes: SQLiteIndexProvider(), writers: DestinationStoreOpener(),
            existing: ExistingFilesScanner()
        )
    }

    func loadTasks() -> [SyncTask] {
        do {
            return try store.loadTasks()
        } catch {
            showError("Your sync tasks couldn't be read.", takeaways: [String(describing: error)])
            return []
        }
    }

    func task(_ id: UUID) -> SyncTask? {
        loadTasks().first { $0.id == id }
    }

    /// Adds or replaces a task.
    func save(_ task: SyncTask) throws {
        var tasks = try store.loadTasks()
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        try store.saveTasks(tasks)
    }

    func delete(_ id: UUID) throws {
        try store.saveTasks(try store.loadTasks().filter { $0.id != id })
    }

    func showError(_ message: String, takeaways: [String] = []) {
        noora.error(.alert("\(message)", takeaways: takeaways.map { "\($0)" }))
    }

    func show(_ error: any Error) {
        if let error = error as? SyncError {
            showError(error.message)
        } else {
            showError("Something went wrong.", takeaways: [String(describing: error)])
        }
    }

    /// A line in the style of Noora's finished steps.
    func printStepLine(_ text: TerminalText, success: Bool = true) {
        print(noora.format("  \(success ? .success("✔") : .danger("⨯")) \(text)"))
    }

    func printMuted(_ text: String) {
        print(noora.format("    \(.muted(text))"))
    }
}

/// Runs screens until the user quits. Errors return to the main menu; they never end the program.
enum InteractiveApp {
    @MainActor
    static func run() async {
        let app = AppContext()
        var next: Next = app.loadTasks().isEmpty ? .screen(NewTaskScreen(isFirstTask: true)) : .mainMenu
        while true {
            switch next {
            case .quit: return
            case .mainMenu: next = await MainMenuScreen().run(app)
            case .screen(let screen): next = await screen.run(app)
            }
        }
    }
}

/// A menu option with a label and what it does.
struct Choice<Action: Equatable>: CustomStringConvertible, Equatable {
    let description: String
    let action: Action

    init(_ description: String, _ action: Action) {
        self.description = description
        self.action = action
    }
}

extension Content {
    /// Noora's texts, with one plain heading above an alert's detail lines instead of
    /// "Takeaways" or "Sorry this didn't work. Here's what to try next".
    static let unroll: Content = {
        let base = Content.default
        return Content(
            errorAlertTitle: base.errorAlertTitle,
            errorAlertRecommendedTitle: "Details",
            warningAlertTitle: base.warningAlertTitle,
            warningAlertRecommendedTitle: "Details",
            successAlertTitle: base.successAlertTitle,
            successAlertRecommendedTitle: "Details",
            infoAlertTitle: base.infoAlertTitle,
            infoAlertRecommendedTitle: "Details",
            choicePromptFilterTitle: base.choicePromptFilterTitle,
            choicePromptInstructionWithoutFilter: base.choicePromptInstructionWithoutFilter,
            choicePromptInstructionWithFilter: base.choicePromptInstructionWithFilter,
            choicePromptInstructionIsFiltering: base.choicePromptInstructionIsFiltering,
            multipleChoicePromptFilterTitle: base.multipleChoicePromptFilterTitle,
            multipleChoicePromptErrorTitle: base.multipleChoicePromptErrorTitle,
            multipleChoicePromptInstructionWithoutFilter: base.multipleChoicePromptInstructionWithoutFilter,
            multipleChoicePromptInstructionWithFilter: base.multipleChoicePromptInstructionWithFilter,
            multipleChoicePromptInstructionIsFiltering: base.multipleChoicePromptInstructionIsFiltering,
            textPromptValidationErrorsTitle: base.textPromptValidationErrorsTitle,
            yesOrNoChoicePromptInstruction: base.yesOrNoChoicePromptInstruction,
            yesOrNoChoicePromptPositiveText: base.yesOrNoChoicePromptPositiveText,
            yesOrNoChoicePromptNegativeText: base.yesOrNoChoicePromptNegativeText
        )
    }()
}

extension Noorable {
    /// A single-choice menu that never picks an option on its own.
    func menu<Action: Equatable>(
        _ question: TerminalText, _ choices: [Choice<Action>], title: TerminalText? = nil, filterable: Bool = false
    ) -> Action {
        singleChoicePrompt(
            title: title, question: question, options: choices,
            filterMode: filterable ? .toggleable : .disabled, autoselectSingleChoice: false
        ).action
    }

    /// A yes/no question. Text is wrapped to the terminal width first: Noora redraws the prompt by
    /// erasing one row per line, so a line the terminal wraps on its own would leave rows behind.
    func confirm(_ question: String, default answer: Bool, details: String? = nil) -> Bool {
        let width = Format.terminalWidth()
        // The question line also holds " Yes (y)  /  No (n) " and a two-space indent.
        return yesOrNoChoicePrompt(
            question: "\(Format.wrapped(question, width: width - 24, indent: 2))",
            defaultAnswer: answer,
            description: details.map { "\(Format.wrapped($0, width: width - 2, indent: 2))" }
        )
    }

    /// Waits for Enter, so a screen's output stays visible until the user is done reading.
    func waitForBack() {
        _ = menu("", [Choice("Back to the menu", 0)])
    }
}
