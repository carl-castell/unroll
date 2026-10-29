import Foundation
import Noora
import UnrollCore
import UnrollStore

/// One task: whether its device and destination are connected, and its recent runs.
struct HistoryScreen: Screen {
    let taskID: UUID

    func run(_ app: AppContext) async -> Next {
        guard let task = app.task(taskID) else { return .mainMenu }
        let deviceConnected = await app.browser.connectedDevices().contains { $0.id == task.device.id }
        let resolved = app.resolver.resolve(task.destination)
        func mark(_ ok: Bool) -> TerminalText.Component { ok ? .success("✓ connected") : .danger("✗ not connected") }
        print("")
        print(app.noora.format("\(.primary(task.name))"))
        print(app.noora.format("  \(.muted("Device"))       \(task.device.name)  \(mark(deviceConnected))"))
        print(app.noora.format("  \(.muted("Destination"))  \(Format.destination(task.destination, resolver: app.resolver))  \(mark(resolved != nil))"))
        print(app.noora.format("  \(.muted("Last run"))     \(task.lastRun?.formatted(date: .abbreviated, time: .shortened) ?? "never")"))

        if let destination = resolved,
           let index = try? SQLiteIndex.openExisting(destinationRoot: destination.root, readOnly: true),
           let runs = try? index.runs(limit: 10), !runs.isEmpty {
            let total = (try? index.meta().itemCount) ?? 0
            print(app.noora.format("\n\(.muted("\(total) files in the destination. Recent runs:"))"))
            app.noora.table(
                headers: ["Run", "Imported", "Size", "Result"],
                rows: runs.map { run in
                    [
                        run.startedAt.formatted(date: .abbreviated, time: .shortened),
                        "\(run.imported)" + (run.duplicates > 0 ? " (+\(run.duplicates) duplicates)" : ""),
                        Format.bytes(run.bytes),
                        Self.label(run),
                    ]
                }
            )
        } else if resolved != nil {
            print(app.noora.format("\n\(.muted("No runs into this destination yet."))"))
        }
        app.noora.waitForBack()
        return .screen(TaskMoreScreen(taskID: task.id))
    }

    static func label(_ run: RunRecord) -> String {
        switch run.status {
        case "ok": "✓ done"
        case "partial": "\(run.failed) failed"
        case "cancelled": "stopped by you"
        case "aborted": "stopped (device disconnected)"
        case "interrupted": "interrupted"
        case "running": "running"
        default: run.status
        }
    }
}

struct RebuildScreen: Screen {
    let taskID: UUID

    func run(_ app: AppContext) async -> Next {
        guard let task = app.task(taskID) else { return .mainMenu }
        guard let destination = app.resolver.resolve(task.destination) else {
            app.showError(SyncError.destinationNotConnected(volumeName: task.destination.volumeName).message)
            return .screen(MainMenuScreen(taskID: task.id))
        }
        let path = Format.destination(destination.root, volumeName: destination.volumeName)
        let confirmed = app.noora.yesOrNoChoicePrompt(
            question: "Rebuild the index of \"\(task.name)\" from the files in \(path)?", defaultAnswer: false,
            description: "Files are only read, never changed. The run history is reset and the next run asks once."
        )
        guard confirmed else { return .screen(TaskMoreScreen(taskID: task.id)) }

        do {
            let result = try await app.noora.progressStep(
                message: "Scanning \(path)", successMessage: "Scanned \(path)", errorMessage: "Rebuilding failed", showSpinner: true
            ) { @Sendable update in
                try await IndexRebuilder().rebuild(destination: destination) { done, total in update("Indexed \(done) of \(total) files") }
            }
            var details: [TerminalText] = ["\(result.fromAttributes) with the exact capture time and name recorded by unroll"]
            if result.fromMetadata > 0 { details.append("\(result.fromMetadata) with the capture time from the photo or video itself") }
            if result.fromFileDate > 0 { details.append("\(result.fromFileDate) with only the file date") }
            if result.duplicateKeys > 0 { details.append("\(result.duplicateKeys) skipped: same capture time, size and name as another file") }
            app.noora.success(.alert("Indexed \(result.files - result.duplicateKeys) files.", takeaways: details))
        } catch {
            app.show(error)
        }
        return .screen(MainMenuScreen(taskID: task.id))
    }
}

/// The help topics from docs/topics, the same as `unroll help <topic>`.
struct HelpScreen: Screen {
    var returnTo: UUID?

    func run(_ app: AppContext) async -> Next {
        while true {
            let choices = HelpTopics.names.map { Choice(HelpTopics.title($0), Optional($0)) } + [Choice("Back", nil)]
            guard let name = app.noora.menu("Help", choices), let markdown = HelpTopics.markdown(name) else {
                return .screen(HelpAndSettingsScreen(returnTo: returnTo))
            }
            print("")
            print(MarkdownText.render(markdown))
            print(app.noora.format("\n\(.muted("Also available as: unroll help \(name)"))"))
        }
    }
}

/// "(on for: iPhone → SSD)" or "(no task has it on)".
@MainActor
private func photosTasksText(_ app: AppContext) -> String {
    let names = app.loadTasks().filter(\.addToPhotos).map(\.name)
    return names.isEmpty ? "(no task has it on yet)" : "(on for: \(names.joined(separator: ", ")))"
}

struct SettingsScreen: Screen {
    enum Action: Equatable {
        case photos, template, versions, notify, openConfig, back
    }

    var returnTo: UUID?

    func run(_ app: AppContext) async -> Next {
        while true {
            var settings = app.store.loadSettings()
            let choices: [Choice<Action>] = [
                Choice("Adding to Apple Photos: \(settings.photosEnabled ? "allowed" : "paused for all tasks")  \(photosTasksText(app))", .photos),
                Choice("Default folder structure: \(settings.defaultFolderTemplate)", .template),
                Choice("Default for edited photos: \(Wizard.label(settings.defaultVersions))", .versions),
                Choice("Notify by default: \(settings.defaultNotify ? "yes" : "no")", .notify),
                Choice("Show the settings folder in Finder", .openConfig),
                Choice("Back", .back),
            ]
            switch app.noora.menu("Settings", choices) {
            // On/off options flip right away; the menu then shows the new value.
            case .photos:
                settings.photosEnabled.toggle()
                if settings.photosEnabled {
                    app.noora.info(.alert("Adding to Apple Photos is allowed again.", takeaways: [
                        "Tasks with \"Add to Apple Photos\" on add their files, including those copied while it was paused.",
                        "To turn it on for a task: More for \"…\" → Edit task → Add to Apple Photos.",
                    ]))
                } else {
                    app.noora.info("Adding to Apple Photos is paused for all tasks. Files copied meanwhile are added once you allow it again.")
                }
            case .template: settings.defaultFolderTemplate = Wizard.pickFolderTemplate(app, current: settings.defaultFolderTemplate)
            case .versions: settings.defaultVersions = Wizard.pickVersions(app, current: settings.defaultVersions)
            case .notify: settings.defaultNotify.toggle()
            case .openConfig:
                try? FileManager.default.createDirectory(at: app.store.directory, withIntermediateDirectories: true)
                _ = try? Process.run(URL(filePath: "/usr/bin/open"), arguments: [app.store.directory.path])
                continue
            case .back: return .screen(HelpAndSettingsScreen(returnTo: returnTo))
            }
            do {
                try app.store.saveSettings(settings)
            } catch {
                app.showError("The settings couldn't be saved.", takeaways: [String(describing: error)])
            }
        }
    }
}
