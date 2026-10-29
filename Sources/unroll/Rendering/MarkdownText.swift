import Foundation

/// Renders the Markdown subset of docs/topics for the terminal: wrapped paragraphs, bullets with
/// hanging indents, bold headings. Without a terminal, no escape codes are written.
enum MarkdownText {
    static func render(_ markdown: String, width: Int = terminalWidth(), styled: Bool = isatty(STDOUT_FILENO) != 0) -> String {
        let bold = styled ? "\u{1B}[1m" : ""
        let reset = styled ? "\u{1B}[0m" : ""
        func inline(_ text: String) -> String {
            text.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "\(bold)$1\(reset)", options: .regularExpression)
                .replacingOccurrences(of: #"`(.+?)`"#, with: "\(bold)$1\(reset)", options: .regularExpression)
        }

        var out: [String] = []
        var inCode = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") {
                inCode.toggle()
            } else if inCode {
                out.append("    " + line)
            } else if line.hasPrefix("## ") {
                out.append("\(bold)\(line.dropFirst(3))\(reset)")
            } else if line.hasPrefix("# ") {
                out.append("\(bold)\(line.dropFirst(2).uppercased())\(reset)")
            } else if line.hasPrefix("- ") {
                out += wrap(inline(String(line.dropFirst(2))), width: width, first: "  • ", rest: "    ")
            } else if line.isEmpty {
                out.append("")
            } else {
                out += wrap(inline(line), width: width, first: "", rest: "")
            }
        }
        // Collapse runs of blank lines.
        return out.reduce(into: [String]()) { lines, line in
            if !(line.isEmpty && lines.last?.isEmpty == true) { lines.append(line) }
        }.joined(separator: "\n")
    }

    static func terminalWidth() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 20 {
            return min(Int(size.ws_col), 100)
        }
        return 80
    }

    /// Wraps on spaces; escape codes don't count toward the width.
    private static func wrap(_ text: String, width: Int, first: String, rest: String) -> [String] {
        var lines: [String] = []
        var current = first
        var visible = first.count
        for word in text.split(separator: " ") {
            let length = word.replacingOccurrences(of: #"\x{1B}\[[0-9;]*m"#, with: "", options: .regularExpression).count
            if visible > rest.count, visible + 1 + length > width {
                lines.append(current)
                current = rest
                visible = rest.count
            }
            if visible > (lines.isEmpty ? first.count : rest.count) {
                current += " "
                visible += 1
            }
            current += word
            visible += length
        }
        lines.append(current)
        return lines
    }
}

/// `unroll help <topic>`. Command help (`unroll help run`) stays with the argument parser.
enum HelpTopics {
    static var names: [String] { GeneratedHelp.topics.map(\.name) }

    static func markdown(_ name: String) -> String? {
        GeneratedHelp.topics.first { $0.name == name }?.markdown
    }

    /// The topic's first heading, e.g. "Setting up your iPhone and Mac".
    static func title(_ name: String) -> String {
        markdown(name)?.split(separator: "\n").first.map { String($0.dropFirst(2)) } ?? name
    }

    /// Handles `unroll help` and `unroll help <topic>`. Returns false for anything else.
    static func handle(_ arguments: [String]) -> Bool {
        guard arguments.first == "help" else { return false }
        if arguments.count == 1 {
            print(Unroll.helpMessage())
            print("\nHELP TOPICS:")
            for name in names {
                print("  \(name.padding(toLength: 20, withPad: " ", startingAt: 0))\(title(name))")
            }
            print("\n  See 'unroll help <topic>', or 'man unroll' for everything.")
            return true
        }
        guard arguments.count == 2 else { return false }
        if let text = markdown(arguments[1]) {
            print(MarkdownText.render(text))
            return true
        }
        let commands = Unroll.configuration.subcommands.map { $0._commandName }
        guard !commands.contains(arguments[1]) else { return false }
        printError("There's no help topic or command \"\(arguments[1])\".")
        printError("Topics: \(names.joined(separator: ", ")). Commands: \(commands.joined(separator: ", ")).")
        exit(UnrollExit.invalidTask.rawValue)
    }
}
