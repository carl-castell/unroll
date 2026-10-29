import ArgumentParser

let unrollVersion = "0.1.0-dev"

struct Unroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unroll",
        abstract: "Copy only the new photos and videos from your iPhone to an external drive.",
        version: unrollVersion,
        subcommands: [Run.self, Tasks.self, RebuildIndex.self, Scan.self]
    )
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
}
