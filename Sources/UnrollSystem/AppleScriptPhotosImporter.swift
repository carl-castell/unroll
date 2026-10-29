import Foundation
import UnrollCore

/// Adds files to Apple Photos with AppleScript. Photos keeps them as referenced files only when
/// "Copy items to the Photos library" is off in Photos settings; that setting can't be read from
/// outside Photos, so it isn't checked here.
///
/// The first time, macOS asks whether the terminal app may control Photos (Automation).
public struct AppleScriptPhotosImporter: PhotosImporting {
    /// With the check, Photos skips items it already has, asking first in its own dialog; that
    /// dialog waits for an answer, also in unattended runs. Without it, such items are added again.
    let checksDuplicates: Bool

    public init(checksDuplicates: Bool) {
        self.checksDuplicates = checksDuplicates
    }

    /// argv: "check" or "skip", then the file paths.
    static let script = [
        "on run argv",
        "  set skipCheck to (item 1 of argv) is \"skip\"",
        "  set theFiles to {}",
        "  repeat with p in (rest of argv)",
        "    set end of theFiles to (POSIX file (p as text)) as alias",
        "  end repeat",
        "  tell application \"Photos\"",
        "    with timeout of 14400 seconds",
        "      import theFiles skip check duplicates skipCheck",
        "    end timeout",
        "  end tell",
        "  return count of theFiles",
        "end run",
    ]

    public func importFiles(_ files: [URL]) async throws(PhotosImportError) {
        guard !files.isEmpty else { return }
        let result = await OSAScript.run(Self.script, arguments: [checksDuplicates ? "check" : "skip"] + files.map(\.path))
        guard result.status != 0 else { return }
        // -1743: not authorized to send Apple events; -1744: user consent would be required.
        if result.error.contains("-1743") || result.error.contains("-1744") {
            throw .notAuthorized
        }
        throw .failed(result.error.isEmpty ? "osascript exited with status \(result.status)" : result.error)
    }
}

/// Shows a notification through Notification Center. A command-line tool has no app bundle of its
/// own, so the notification comes from "Script Editor"; macOS may ask to allow its notifications.
public enum Notifier {
    public static func post(title: String, subtitle: String, message: String) async {
        _ = await OSAScript.run(
            ["on run argv", "display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)", "end run"],
            arguments: [title, subtitle, message]
        )
    }
}

enum OSAScript {
    struct Result {
        let status: Int32
        let output: String
        let error: String
    }

    /// Runs AppleScript with arguments passed as `argv`, so no value is ever spliced into the script.
    static func run(_ lines: [String], arguments: [String]) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/osascript")
            process.arguments = lines.flatMap { ["-e", $0] } + arguments
            let output = Pipe(), error = Pipe()
            process.standardOutput = output
            process.standardError = error
            process.terminationHandler = { process in
                let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    output: out.trimmingCharacters(in: .whitespacesAndNewlines),
                    error: err.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: Result(status: -1, output: "", error: String(describing: error)))
            }
        }
    }
}
