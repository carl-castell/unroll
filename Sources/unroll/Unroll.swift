import ArgumentParser

let unrollVersion = "0.3.0-dev"

struct Unroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unroll",
        abstract: "Copy only the new photos and videos from your iPhone to a folder on a drive.",
        discussion: """
            Run without arguments in a terminal to open the menu. Outside a terminal, unroll \
            never shows menus or prompts.

            Help topics: setup, tasks, photos-referenced, troubleshooting, exit-codes, keys.
            Show one with 'unroll help <topic>'; 'man unroll' has everything.
            """,
        version: unrollVersion,
        subcommands: [Run.self, Status.self, Tasks.self, Arrange.self, RebuildIndex.self, Scan.self]
    )

    /// Without a command: the interactive menu in a terminal, help everywhere else.
    @MainActor
    func run() async throws {
        guard Terminal.isInteractive else {
            print(Unroll.helpMessage())
            return
        }
        await InteractiveApp.run()
    }
}

/// Exit codes shared by all commands. See `unroll help exit-codes`.
enum UnrollExit {
    static let success = ExitCode(0)
    static let itemsFailed = ExitCode(1)
    static let destinationMissing = ExitCode(2)
    static let deviceUnavailable = ExitCode(3)
    static let invalidTask = ExitCode(4)
    /// A confirmation is needed but there is no terminal to ask in. Pass --yes.
    static let confirmationRequired = ExitCode(5)
    /// Stopped with Ctrl-C after finishing the current file (the shell's usual code for an interrupt).
    static let cancelled = ExitCode(130)
}
