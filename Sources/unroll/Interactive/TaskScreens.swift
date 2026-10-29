import Foundation
import Noora
import UnrollCore
import UnrollStore

/// The new-task wizard: device, destination, folder structure, versions, Photos, notification, name.
struct NewTaskScreen: Screen {
    var isFirstTask = false

    func run(_ app: AppContext) async -> Next {
        if isFirstTask {
            app.noora.info(.alert("Welcome to unroll. Let's set up your first sync task.", takeaways: [
                "A task copies new photos and videos from one iPhone or iPad to one folder.",
                "Connect the iPhone by cable and unlock it, and connect the drive you want to copy to.",
            ]))
        }
        guard let device = await Wizard.pickDevice(app) else { return .mainMenu }
        guard let (destination, folder) = Wizard.pickDestination(app) else { return .mainMenu }
        let settings = app.store.loadSettings()
        let template = Wizard.pickFolderTemplate(app, current: settings.defaultFolderTemplate)
        let versions = Wizard.pickVersions(app, current: settings.defaultVersions)
        let photos = Wizard.askAddToPhotos(app, current: false)
        let photosChecksDuplicates = photos ? Wizard.askPhotosDuplicateCheck(app, current: true) : true
        let notify = Wizard.askNotify(app, current: settings.defaultNotify)
        let name = Wizard.askName(app, suggested: "\(device.name) → \(destination.volumeName)", excluding: nil)

        let task = SyncTask(
            name: name, device: .init(id: device.id, name: device.name), destination: destination,
            folderTemplate: template, versions: versions, addToPhotos: photos,
            photosChecksDuplicates: photosChecksDuplicates, notify: notify
        )
        app.noora.info(.alert("New task \"\(name)\"", takeaways: Wizard.describe(task, folder: folder)))
        guard app.noora.yesOrNoChoicePrompt(question: "Save this task?", defaultAnswer: true) else {
            app.noora.info("The task wasn't saved.")
            return .mainMenu
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try app.save(task)
            try? app.store.saveLastUsedTask(task.id)
        } catch {
            app.showError("The task couldn't be saved.", takeaways: [String(describing: error)])
            return .mainMenu
        }
        app.noora.success(.alert("Saved \"\(name)\"", takeaways: [
            "It's now preselected in the menu: press Enter to run it.",
            "The first run shows what will be copied and asks once.",
        ]))
        return .mainMenu
    }
}

/// Edits one task's settings. Back returns to the task's More… menu.
struct EditTaskScreen: Screen {
    enum Action: Equatable {
        case name, device, destination, template, versions, photos, photosDuplicates, notify, back
    }

    let taskID: UUID

    func run(_ app: AppContext) async -> Next {
        while var task = app.task(taskID) {
            var choices: [Choice<Action>] = [
                Choice("Name: \(task.name)", .name),
                Choice("Device: \(task.device.name)", .device),
                Choice("Destination: \(Format.destination(task.destination, resolver: app.resolver))", .destination),
                Choice("Folder structure: \(task.folderTemplate)", .template),
                Choice("Original vs. edited: \(Wizard.label(task.versions))", .versions),
                Choice("Add to Apple Photos: \(task.addToPhotos ? "yes" : "no")\(task.addToPhotos && !app.store.loadSettings().photosEnabled ? " (paused for all tasks in Settings)" : "")", .photos),
                Choice("Notification when done: \(task.notify ? "yes" : "no")", .notify),
                Choice("Back", .back),
            ]
            if task.addToPhotos {
                choices.insert(Choice("Let Photos check for duplicates: \(task.photosChecksDuplicates ? "yes" : "no")", .photosDuplicates), at: 6)
            }
            switch app.noora.menu("Edit \"\(task.name)\"", choices) {
            case .name:
                task.name = Wizard.askName(app, suggested: task.name, excluding: task.id)
            case .device:
                guard let device = await Wizard.pickDevice(app) else { continue }
                task.device = .init(id: device.id, name: device.name)
            case .destination:
                guard let (destination, folder) = Wizard.pickDestination(app) else { continue }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                task.destination = destination
            case .template:
                task.folderTemplate = Wizard.pickFolderTemplate(app, current: task.folderTemplate)
            case .versions:
                task.versions = Wizard.pickVersions(app, current: task.versions)
            // On/off options flip right away; the menu then shows the new value.
            case .photos:
                task.addToPhotos.toggle()
                if task.addToPhotos {
                    app.noora.info(.alert("Add to Apple Photos is now on for \"\(task.name)\".", takeaways: [
                        "Turn off \"Copy items to the Photos library\" in Photos → Settings → General.",
                        "Files go into the library Photos has open. macOS asks once whether your terminal may control Photos.",
                    ]))
                }
            case .photosDuplicates:
                task.photosChecksDuplicates.toggle()
                if task.photosChecksDuplicates {
                    app.noora.info("Photos will skip photos it already has. When it finds some, it asks and waits for your answer.")
                } else {
                    app.noora.warning(.alert("Photos won't check for duplicates.", takeaway: "Photos already in the library are added again."))
                }
            case .notify:
                task.notify.toggle()
            case .back:
                return .screen(TaskMoreScreen(taskID: task.id))
            }
            do {
                try app.save(task)
            } catch {
                app.showError("The change couldn't be saved.", takeaways: [String(describing: error)])
            }
        }
        return .mainMenu
    }
}

/// The steps shared by the wizard and editing.
@MainActor
enum Wizard {
    // MARK: Device

    private enum DeviceAction: Equatable {
        case device(DeviceInfo), wait, cancel
    }

    /// Picks a connected device. Waits with a spinner while none is connected and continues as
    /// soon as one appears. Opens the device once, so it asks to be trusted during setup.
    static func pickDevice(_ app: AppContext) async -> DeviceInfo? {
        while true {
            var devices = await app.browser.connectedDevices()
            if devices.isEmpty {
                guard let found = try? await waitForDevices(app, otherThan: []) else { return nil }
                devices = found
            }
            let choices = devices.map { Choice("\($0.name) (\($0.productKind ?? "device"))", DeviceAction.device($0)) }
                + [Choice("Wait for another device…", .wait), Choice("Cancel", .cancel)]
            switch app.noora.menu("Which device should this task copy from?", choices) {
            case .device(let device):
                if await verifyAccess(device, app: app) { return device }
            case .wait:
                _ = try? await waitForDevices(app, otherThan: Set(devices.map(\.id)))
            case .cancel:
                return nil
            }
        }
    }

    private static func waitForDevices(_ app: AppContext, otherThan known: Set<DeviceID>) async throws -> [DeviceInfo] {
        let browser = app.browser
        return try await app.noora.progressStep(
            message: known.isEmpty
                ? "No iPhone or iPad detected. Connect one with a cable and unlock it…"
                : "Waiting for another device…",
            successMessage: "Device detected",
            errorMessage: nil,
            showSpinner: true
        ) { @Sendable _ in
            while true {
                let devices = await browser.connectedDevices()
                if devices.contains(where: { !known.contains($0.id) }) { return devices }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func verifyAccess(_ device: DeviceInfo, app: AppContext) async -> Bool {
        let browser = app.browser
        let id = device.id
        do {
            try await app.noora.progressStep(
                message: "Checking access to \"\(device.name)\"", successMessage: "\"\(device.name)\" is ready",
                errorMessage: "\"\(device.name)\" is locked or doesn't trust this Mac yet", showSpinner: true
            ) { @Sendable _ in try await browser.open(id, unlockTimeout: .seconds(2)).close() }
            return true
        } catch {}
        do {
            try await app.noora.progressStep(
                message: "Unlock \"\(device.name)\" and tap Trust if asked…", successMessage: "\"\(device.name)\" is ready",
                errorMessage: "\"\(device.name)\" is still locked", showSpinner: true
            ) { @Sendable _ in try await browser.open(id, unlockTimeout: .seconds(60)).close() }
            return true
        } catch {
            app.showError("\"\(device.name)\" couldn't be opened.", takeaways: [
                "Unlock it, tap Trust This Computer and enter your passcode, then try again.",
            ])
            return false
        }
    }

    // MARK: Destination

    private enum VolumeAction: Equatable {
        case volume(Volume), finder, refresh, cancel
    }

    /// Picks a folder on any mounted volume, labeled by kind. Returns the destination and the folder.
    static func pickDestination(_ app: AppContext) -> (Destination, URL)? {
        while true {
            let volumes = app.resolver.mountedVolumes()
            let choices = volumes.map { Choice(label($0), VolumeAction.volume($0)) }
                + [Choice("Choose in Finder…", .finder), Choice("Refresh list", .refresh), Choice("Cancel", .cancel)]
            switch app.noora.menu("Where should the photos and videos go?", choices) {
            case .volume(let volume):
                if volume.isReadOnly {
                    app.showError("\"\(volume.name)\" is read-only, so unroll can't copy to it.")
                    continue
                }
                guard let folder = browseFolders(app, volume: volume) else { continue }
                if let result = confirm(folder, app: app) { return result }
            case .finder:
                guard let folder = chooseInFinder() else { continue }
                if let result = confirm(folder, app: app) { return result }
            case .refresh:
                continue
            case .cancel:
                return nil
            }
        }
    }

    static func label(_ volume: Volume) -> String {
        let kind = switch volume.kind {
        case .external: "External"
        case .internal: "Internal (this Mac)"
        case .network: "Network" + (volume.remountURL.flatMap { URL(string: $0)?.host() }.map { " (\($0))" } ?? "")
        }
        var parts = ["\(volume.name) — \(kind)"]
        if let format = volume.format { parts.append(format) }
        if let free = volume.availableBytes { parts.append("\(Format.bytes(free)) free") }
        return parts.joined(separator: " · ") + (volume.isReadOnly ? " (read-only)" : "")
    }

    private enum FolderAction: Equatable {
        case use, newFolder, up, open(URL), back
    }

    /// An arrow-key folder browser that stays on one volume. New folders are created when the task is saved.
    private static func browseFolders(_ app: AppContext, volume: Volume) -> URL? {
        // On the internal disk, start in the home folder and stay within /Users.
        let boundary = volume.kind == .internal ? URL(filePath: "/Users", directoryHint: .isDirectory) : volume.url
        var current = volume.kind == .internal ? FileManager.default.homeDirectoryForCurrentUser : volume.url
        while true {
            let subfolders = (try? FileManager.default.contentsOfDirectory(
                at: current, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]
            ))?.filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []

            var choices = [Choice("✓ Use this folder", FolderAction.use), Choice("+ New folder…", .newFolder)]
            if current.standardizedFileURL.path != boundary.standardizedFileURL.path {
                choices.append(Choice(".. (up)", .up))
            }
            choices += subfolders.map { Choice("\($0.lastPathComponent)/", .open($0)) }
            choices.append(Choice("Back", .back))

            switch app.noora.menu(
                "Choose the destination folder", choices, title: "\(Format.destination(current, volumeName: volume.name))",
                filterable: subfolders.count > 10
            ) {
            case .use: return current
            case .newFolder:
                let name = app.noora.textPrompt(prompt: "Folder name", defaultValue: "Photos")
                guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
                    app.showError("\"\(name)\" can't be used as a folder name.")
                    continue
                }
                current = current.appending(path: name, directoryHint: .isDirectory)
            case .up: current = current.deletingLastPathComponent()
            case .open(let url): current = url
            case .back: return nil
            }
        }
    }

    /// The standard macOS folder dialog, via AppleScript.
    private static func chooseInFinder() -> URL? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", "POSIX path of (choose folder with prompt \"Choose the folder unroll copies to\")"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Resolves the folder to a destination, warns about internal and network volumes, and
    /// mentions an existing index.
    private static func confirm(_ folder: URL, app: AppContext) -> (Destination, URL)? {
        let destination: Destination
        do {
            destination = try app.resolver.destination(forFolder: folder)
        } catch {
            app.showError("\(error)")
            return nil
        }
        guard let resolved = app.resolver.resolve(destination) else {
            app.showError("The volume of \(folder.path) can't be recognized again later.")
            return nil
        }
        switch resolved.kind {
        case .internal:
            app.noora.warning(.alert("This folder is on this Mac's internal disk.", takeaway: "The originals will use space on this Mac."))
        case .network:
            app.noora.warning(.alert(
                "This folder is on a network share.",
                takeaway: "Keep the connection up during a sync; unroll doesn't mount the share for you."
            ))
        case .external:
            break
        }
        if let index = try? SQLiteIndex.openExisting(destinationRoot: folder, readOnly: true), let meta = try? index.meta() {
            app.noora.info(.alert(
                "This folder already has an unroll index with \(meta.itemCount) files.",
                takeaways: ["Files listed there won't be copied again."]
            ))
        } else if case let count = IndexRebuilder.mediaFiles(in: folder).count, count > 0 {
            app.noora.info(.alert(
                "This folder already has \(count) files.",
                takeaways: [
                    "unroll recognizes photos and videos that are already there by name, size and capture time, and doesn't copy them again.",
                    "The first run records them in its index before copying.",
                ]
            ))
        }
        return (destination, folder)
    }

    // MARK: Options

    static func pickFolderTemplate(_ app: AppContext, current: FolderTemplate) -> FolderTemplate {
        let example = LocalTimestamp(secondsSince1970: 1_780_393_586) // 2026-06-02
        let presets = ["YYYY/YYYY-MM", "YYYY/MM", "YYYY/YYYY-MM-DD", "YYYY"].compactMap { try? FolderTemplate($0) }
        var options = presets.map { Choice("\($0)  (e.g. \($0.folder(for: example)))", Optional($0)) }
        if !presets.contains(current) {
            options.insert(Choice("\(current)  (current)", Optional(current)), at: 0)
        } else if let index = presets.firstIndex(of: current) {
            options.insert(options.remove(at: index), at: 0)
        }
        options.append(Choice("Custom…", nil))
        guard let picked = app.noora.menu("Folder structure inside the destination", options) else {
            while true {
                let text = app.noora.textPrompt(
                    prompt: "Folder structure", description: "Use YYYY, MM and DD, separated by /.", defaultValue: current.pattern
                )
                if let template = try? FolderTemplate(text) { return template }
                app.showError("\"\(text)\" isn't a valid folder structure.", takeaways: ["Example: YYYY/YYYY-MM"])
            }
        }
        return picked
    }

    static func pickVersions(_ app: AppContext, current: VersionPolicy) -> VersionPolicy {
        let options = ([current] + VersionPolicy.allCases.filter { $0 != current }).map { Choice(label($0), $0) }
        return app.noora.menu("Edited photos: which versions should be copied?", options)
    }

    static func label(_ versions: VersionPolicy) -> String {
        switch versions {
        case .original: "Originals only (with their Live Photo videos)"
        case .edited: "Edited version where one exists, otherwise the original"
        case .both: "Both, plus the edit data (AAE)"
        }
    }

    static func askAddToPhotos(_ app: AppContext, current: Bool) -> Bool {
        app.noora.yesOrNoChoicePrompt(
            question: "Add new files to Apple Photos as referenced files?", defaultAnswer: current,
            description: "After each sync, new files are added to Photos without copying them into its library. Turn off \"Copy items to the Photos library\" in Photos → Settings → General first. macOS asks once whether your terminal app may control Photos."
        )
    }

    static func askPhotosDuplicateCheck(_ app: AppContext, current: Bool) -> Bool {
        app.noora.yesOrNoChoicePrompt(
            question: "Let Photos check for photos it already has?", defaultAnswer: current,
            description: "Recommended if your library already has photos from this iPhone. When Photos finds duplicates, it asks what to do and waits for your answer, also in runs from Shortcuts. Without the check, those photos are added again."
        )
    }

    static func askNotify(_ app: AppContext, current: Bool) -> Bool {
        app.noora.yesOrNoChoicePrompt(
            question: "Show a notification when a sync finishes?", defaultAnswer: current,
            description: "macOS may ask to allow notifications from Script Editor, which shows them for unroll."
        )
    }

    static func askName(_ app: AppContext, suggested: String, excluding id: UUID?) -> String {
        while true {
            let name = app.noora.textPrompt(prompt: "Name of the task", defaultValue: suggested)
                .trimmingCharacters(in: .whitespaces)
            let others = app.loadTasks().filter { $0.id != id }
            if name.isEmpty {
                app.showError("The name can't be empty.")
            } else if SyncTask.find(name, in: others)?.name.caseInsensitiveCompare(name) == .orderedSame {
                app.showError("A task named \"\(name)\" already exists.")
            } else {
                return name
            }
        }
    }

    static func describe(_ task: SyncTask, folder: URL) -> [TerminalText] {
        [
            "Device: \(task.device.name)",
            "Destination: \(Format.destination(folder, volumeName: task.destination.volumeName))",
            "Folder structure: \(task.folderTemplate)",
            "Versions: \(label(task.versions))",
            "Add to Apple Photos: \(task.addToPhotos ? (task.photosChecksDuplicates ? "yes, Photos checks for duplicates" : "yes, without duplicate check") : "no")",
            "Notification: \(task.notify ? "yes" : "no")",
        ]
    }
}
