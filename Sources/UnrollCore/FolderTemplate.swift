import Foundation

/// The date-based folder structure inside the destination, e.g. `YYYY/YYYY-MM`.
/// Tokens: `YYYY` (year), `MM` (month), `DD` (day). `none` puts every file directly in the destination.
public struct FolderTemplate: Codable, Sendable, Equatable, CustomStringConvertible {
    public static let `default` = FolderTemplate(validated: "YYYY/YYYY-MM")
    /// No folders: all files directly in the destination folder. Stored as an empty pattern.
    public static let none = FolderTemplate(validated: "")

    public var isNone: Bool { pattern.isEmpty }

    public let pattern: String

    public enum Invalid: Error, Equatable {
        case empty, absolute, parentReference, emptyComponent
    }

    public init(_ pattern: String) throws(Invalid) {
        try Self.validate(pattern)
        self.pattern = pattern
    }

    private init(validated pattern: String) {
        self.pattern = pattern
    }

    public var description: String { isNone ? "none (all files in one folder)" : pattern }

    /// The folder for an item, relative to the destination root.
    public func folder(for date: LocalTimestamp) -> String {
        let c = date.components
        return pattern
            .replacingOccurrences(of: "YYYY", with: String(format: "%04d", c.year ?? 0))
            .replacingOccurrences(of: "MM", with: String(format: "%02d", c.month ?? 0))
            .replacingOccurrences(of: "DD", with: String(format: "%02d", c.day ?? 0))
    }

    private static func validate(_ pattern: String) throws(Invalid) {
        guard !pattern.isEmpty else { throw .empty }
        guard !pattern.hasPrefix("/") else { throw .absolute }
        let components = pattern.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: \.isEmpty) else { throw .emptyComponent }
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { throw .parentReference }
    }

    public init(from decoder: any Decoder) throws {
        let pattern = try decoder.singleValueContainer().decode(String.self)
        if pattern.isEmpty {
            self = .none
            return
        }
        do {
            try self.init(pattern)
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid folder template \"\(pattern)\""
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(pattern)
    }
}
