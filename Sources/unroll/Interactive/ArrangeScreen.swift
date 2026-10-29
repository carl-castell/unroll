import Foundation
import Noora
import UnrollCore
import UnrollStore

/// "Arrange existing files…" in a task's More menu.
struct ArrangeScreen: Screen {
    let taskID: UUID

    func run(_ app: AppContext) async -> Next {
        if let task = app.task(taskID) {
            await ArrangeFlow.offer(task, app: app, automatic: false)
        }
        return .screen(TaskMoreScreen(taskID: taskID))
    }
}

/// Moves files already in a task's destination into its folder structure, after showing what
/// would move and asking. Offered on its own after creating a task and after changing the
/// structure; then it says nothing when everything is in place already.
@MainActor
enum ArrangeFlow {
    static func offer(_ task: SyncTask, app: AppContext, automatic: Bool) async {
        guard let destination = app.resolver.resolve(task.destination) else {
            if !automatic { app.showError(SyncError.destinationNotConnected(volumeName: task.destination.volumeName).message) }
            return
        }
        let label = Format.destination(destination.root, volumeName: destination.volumeName)
        let arranger = DestinationArranger()
        let root = destination.root
        let template = task.folderTemplate
        let rule = task.otherFolderRule
        let plan: ArrangePlan
        do {
            plan = try await app.noora.progressStep(
                message: "Checking the files in \(label)",
                successMessage: "Checked the files in \(label)",
                errorMessage: "Couldn't check the files in \(label)",
                showSpinner: true
            ) { @Sendable update in
                await arranger.plan(root: root, template: template, rule: rule) { done, total in
                    update("Checking the files in \(label)… \(done) of \(total)")
                }
            }
        } catch {
            app.show(error)
            return
        }

        guard !plan.moves.isEmpty else {
            if !automatic { app.noora.success("All photos and videos in \(label) are already in the folder structure.") }
            return
        }

        let count = plan.moves.count
        var details: [TerminalText] = plan.moves.prefix(3).map { "\($0.from) → \($0.to)" }
        if count > 3 { details.append("… and \(count - 3) more") }
        if plan.undated > 0 { details.append("\(plan.undated) without a capture time stay where they are") }
        if plan.otherFiles > 0 { details.append("\(plan.otherFiles) other files (not photos or videos) stay where they are") }
        if plan.inPhotos > 0 { details.append("\(plan.inPhotos) added to Apple Photos stay where they are, so Photos still finds them") }
        let structure = template.isNone ? "one folder" : "the \(template) structure"
        app.noora.info(.alert("\(count) \(count == 1 ? "file" : "files") in this folder \(count == 1 ? "isn't" : "aren't") in \(structure).", takeaways: details))
        guard app.noora.confirm(
            "Move them into \(structure)?", default: true,
            details: "Files are only moved within \(label), never replaced or deleted. A list of every move is kept in the .unroll folder."
        ) else {
            app.noora.info("Nothing was moved. You can do it later under More for \"\(task.name)\" → Arrange existing files.")
            return
        }

        let result: ArrangeResult
        do {
            result = try await app.noora.progressStep(
                message: "Moving \(count) files",
                successMessage: "Moved the files",
                errorMessage: "Moving stopped",
                showSpinner: true
            ) { @Sendable update in
                let work = Task {
                    try await arranger.apply(
                        plan, destination: destination,
                        indexing: { done, total in update("Indexing the files first… \(done) of \(total)") },
                        progress: { done, total in update("Moving files… \(done) of \(total)") }
                    )
                }
                // Ctrl-C finishes the current move, then stops.
                let interrupt = CtrlCHandler { work.cancel() }
                defer { interrupt.stop() }
                return try await work.value
            }
        } catch {
            app.show(error)
            return
        }

        var summary: [TerminalText] = []
        if result.removedFolders > 0 { summary.append("Removed \(result.removedFolders) folders that were left empty") }
        for failure in result.failed.prefix(5) { summary.append("\(failure)") }
        if result.failed.count > 5 { summary.append("… and \(result.failed.count - 5) more that couldn't be moved") }
        if let journal = result.journal { summary.append("List of moves: \(Format.path(journal))") }
        if !result.failed.isEmpty {
            app.noora.error(.alert("Moved \(result.moved) files; \(result.failed.count) couldn't be moved.", takeaways: summary))
        } else if result.cancelled {
            app.noora.warning(.alert("Moved \(result.moved) of \(count) files. Stopped at your request.", takeaway: "Arrange again to move the rest."))
        } else {
            app.noora.success(.alert("Moved \(result.moved) files into \(structure).", takeaways: summary))
        }
    }
}
